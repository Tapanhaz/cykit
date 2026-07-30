
"""
Interprocess throughput benchmark for IPC pairs.
Producer/ Producers and Consumer / Consumers run in separate processes.

Pairs tested:
  - push / pop
  - push / pop_borrow + commit
  - push_var / pop_var
  - try_push / try_pop
  - try_prush_var / try_pop_var 

For SPMC, MPSC and MPMC modes.
"""

import sys
import random
from libc.string cimport memset, memcpy
from libc.stddef cimport size_t
from libc.stdlib cimport malloc, free
from libc.stdint cimport uint8_t, uint32_t, uint64_t
from libc.stdio cimport printf, fflush, stdout

from cykit.common cimport (
    cpu_pause,
    memory_order,
)

from cykit.ipc cimport (
    Context, SharedMemSystem, 
    RunningMode, ProcessRole,
    IPC_OK, IPC_EMPTY, IPC_FULL, IPC_ERR, IPC_CLOSING, IPC_NO_CONSUMER,
    F_IPC_CLOSING, F_IPC_BLOCK_ON_FULL, F_IPC_WAIT_CONSUMERS, F_IPC_ABORT,
    
    init_producer_system,
    init_consumer_system,
    
    ipc_spmc_push, ipc_spmc_push_var,
    ipc_spmc_pop, ipc_spmc_pop_borrow, ipc_spmc_pop_commit,
    ipc_spmc_pop_var,
    
    ipc_mpsc_push, ipc_mpsc_push_var,
    ipc_mpsc_pop, ipc_mpsc_pop_borrow, ipc_mpsc_pop_commit,
    ipc_mpsc_pop_var,
    
    ipc_mpmc_push, ipc_mpmc_push_var,
    ipc_mpmc_pop, ipc_mpmc_pop_borrow, ipc_mpmc_pop_commit,
    ipc_mpmc_pop_var,

    ipc_spmc_try_push, ipc_spmc_try_push_var,
    ipc_spmc_try_pop,  ipc_spmc_try_pop_var,

    ipc_mpsc_try_push, ipc_mpsc_try_push_var,
    ipc_mpsc_try_pop,  ipc_mpsc_try_pop_var,

    ipc_mpmc_try_push, ipc_mpmc_try_push_var,
    ipc_mpmc_try_pop,  ipc_mpmc_try_pop_var,

    detach_producer,
    detach_consumer,
    shutdown_pipeline,
    placement_new
)

from cykit.utils.compat cimport now_ns


cdef extern from *:
    """
    #include <cstdint>
    #include <cstddef>
    static inline uint32_t bench_crc32c(const char* data, size_t len, uint32_t seed) {
        const unsigned char* p = (const unsigned char*)data;
        uint64_t h = 1469598103934665603ULL ^ (uint64_t)seed;
        for (size_t i = 0; i < len; ++i) {
            h ^= (uint64_t)p[i];
            h *= 1099511628211ULL;
        }
        return (uint32_t)(h ^ (h >> 32));
    }
    """
    uint32_t bench_crc32c(const char* data, size_t length, uint32_t crc) noexcept nogil



cdef enum:
    BENCH_BLOCK_COUNT  = 16384     
    BENCH_BLOCK_SIZE   = 256       
    FIXED_PAYLOAD_SZ   = 64        
    VAR_PAYLOAD_LARGE  = 600  
    HDR_SZ = 8     

cdef enum BenchPair:
    PAIR_PUSH_POP          = 0
    PAIR_PUSH_BORROW_COMMIT = 1
    PAIR_PUSH_VAR_POP_VAR  = 2
    PAIR_TRY_PUSH_POP        = 3
    PAIR_TRY_PUSH_VAR_POP_VAR = 4

cdef packed struct BenchMsgHeader:
    uint32_t magic
    uint32_t producer_id
    uint64_t local_seq
    uint32_t payload_size
    uint32_t crc32

cdef uint32_t BENCH_MAGIC = 0xB00FCAFE


def _gen_var_payload_sizes(int min_sz, int max_sz, int count=32):
    if max_sz <= min_sz:
        return [min_sz] * count

    min_diff = max(1, (max_sz - min_sz) // 4)
    sizes = [random.randint(min_sz, max_sz)]

    for _ in range(count - 1):
        #prev = sizes[-1]
        prev = sizes[len(sizes) - 1]
        low_range  = (min_sz, max(min_sz, prev - min_diff))
        high_range = (min(max_sz, prev + min_diff), max_sz)

        choices = []
        if low_range[0] < low_range[1]:
            choices.append(low_range)
        if high_range[0] < high_range[1]:
            choices.append(high_range)

        if choices:
            lo, hi = random.choice(choices)
        else:
            lo, hi = min_sz, max_sz
        sizes.append(random.randint(lo, hi))

    return sizes



cdef void _producer_bench(
    const char* shm_name,
    const char* sem_name,
    RunningMode mode,
    BenchPair pair,
    uint64_t num_messages,
    uint32_t payload_size,
    uint32_t producer_id,
    uint32_t* size_table,
    int table_len,
    uint64_t* out_pushed,
    double*   out_mps,
    double*   out_gbps,
    uint64_t* out_bytes,
) noexcept nogil:

    cdef:
        SharedMemSystem shmsys
        Context*        ctx
        int             rc
        uint64_t        pushed = 0
        uint64_t        total_bytes = 0
        uint64_t        start=0, end=0
        uint64_t        elapsed
        double          mps
        double          gbps
        char*           payload
        size_t          pay_sz = payload_size
        size_t          cur_sz
        uint32_t        max_payload = BENCH_BLOCK_SIZE - HDR_SZ
        bint            is_var = (pair == PAIR_PUSH_VAR_POP_VAR or pair == PAIR_TRY_PUSH_VAR_POP_VAR)

    if pair != PAIR_PUSH_VAR_POP_VAR and pair != PAIR_TRY_PUSH_VAR_POP_VAR:
        if pay_sz > max_payload:
            pay_sz = max_payload  

    if out_pushed != NULL:
        out_pushed[0] = 0

    payload = <char*>malloc(pay_sz)

    if payload == NULL:
        printf(b"[PRODUCER] OOM for payload\n")
        return

    memset(payload, 0xAA, pay_sz)

    memset(&shmsys, 0, sizeof(SharedMemSystem))
    shmsys.shm_name    = shm_name
    shmsys.sem_name    = sem_name
    shmsys.block_count = BENCH_BLOCK_COUNT
    shmsys.block_size  = BENCH_BLOCK_SIZE
    shmsys.mode        = mode
    shmsys.ctx         = <Context*>malloc(sizeof(Context))

    if shmsys.ctx == NULL:
        printf(b"[PRODUCER] OOM for Context\n")
        free(payload)
        return
        
    placement_new[Context](shmsys.ctx)
    shmsys.ctx.role = ProcessRole.Producer

    
    
    cdef int ret = init_producer_system(&shmsys)
    
    if ret != 0:
        printf(b"[PRODUCER] init_producer_system failed:: code :: %d\n", ret)
        free(payload)
        free(shmsys.ctx)
        return

    ctx = shmsys.ctx
    ctx.running = 1 
    ctx.local_flags = F_IPC_BLOCK_ON_FULL | F_IPC_WAIT_CONSUMERS 
    
    printf(b"READY\n")
    fflush(stdout)
    with gil:
        sys.stdin.readline()

    printf(b"[PRODUCER] Starting: mode=%d  pair=%d  messages=%llu  payload=%zu\n",
           <int>mode, <int>pair, <unsigned long long>num_messages,
           <size_t>(size_table[0] if is_var and size_table != NULL else pay_sz))
    fflush(stdout)
           

    while pushed < num_messages:
        if is_var and size_table != NULL and table_len > 0:
            cur_sz = size_table[pushed % <uint64_t>table_len]
        else:
            cur_sz = pay_sz

        (<BenchMsgHeader*>payload)[0].magic        = BENCH_MAGIC
        (<BenchMsgHeader*>payload)[0].producer_id  = producer_id
        (<BenchMsgHeader*>payload)[0].local_seq    = pushed
        (<BenchMsgHeader*>payload)[0].payload_size = <uint32_t>cur_sz
        (<BenchMsgHeader*>payload)[0].crc32        = 0
        (<BenchMsgHeader*>payload)[0].crc32 = bench_crc32c(
            payload, cur_sz, 0xFFFFFFFF
        )

        
        if pair == PAIR_PUSH_POP:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_push(ctx, payload, pay_sz)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_push(ctx, payload, pay_sz)
            else:
                rc = ipc_mpmc_push(ctx, payload, pay_sz)
        elif pair == PAIR_PUSH_BORROW_COMMIT:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_push(ctx, payload, pay_sz)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_push(ctx, payload, pay_sz)
            else:
                rc = ipc_mpmc_push(ctx, payload, pay_sz)
        elif pair == PAIR_PUSH_VAR_POP_VAR:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_push_var(ctx, payload, cur_sz)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_push_var(ctx, payload, cur_sz)
            else:
                rc = ipc_mpmc_push_var(ctx, payload, cur_sz)
        elif pair == PAIR_TRY_PUSH_POP:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_try_push(ctx, payload, pay_sz)                
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_try_push(ctx, payload, pay_sz)
            else:
                rc = ipc_mpmc_try_push(ctx, payload, pay_sz)

        elif pair == PAIR_TRY_PUSH_VAR_POP_VAR:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_try_push_var(ctx, payload, cur_sz)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_try_push_var(ctx, payload, cur_sz)
            else:
                rc = ipc_mpmc_try_push_var(ctx, payload, cur_sz)
        else:
            rc = IPC_ERR

        if rc == IPC_OK:
            if pushed == 0:
                start = now_ns()
            pushed += 1
            total_bytes += cur_sz
        elif rc == IPC_FULL or rc == IPC_NO_CONSUMER:
            cpu_pause()
        elif rc == IPC_CLOSING:
            break
        else:
            printf(b"[PRODUCER] push error: %d\n", rc)
            break

    end = now_ns()
    elapsed = end - start
    if elapsed == 0:
        elapsed = 1
    mps  = (<double>pushed * 1e9) / <double>elapsed
    gbps = (<double>total_bytes / <double>elapsed)

    if out_mps != NULL:
        out_mps[0] = mps
    if out_gbps != NULL:
        out_gbps[0] = gbps
    if out_bytes != NULL:
        out_bytes[0] = total_bytes

    free(payload)
    if out_pushed != NULL:
        out_pushed[0] = pushed

    cdef int remaining = detach_producer(&shmsys)
    if remaining <= 0:
        shutdown_pipeline(&shmsys, -1)

    with gil:
        if ctx.shm_obj != NULL:
            del ctx.shm_obj
            ctx.shm_obj = NULL
        if ctx.sem_obj != NULL:
            del ctx.sem_obj
            ctx.sem_obj = NULL
    if ctx.assemble_buf != NULL:
        free(ctx.assemble_buf)
    free(ctx)


cdef void _consumer_bench(
    const char* shm_name,
    const char* sem_name,
    RunningMode mode,
    BenchPair pair,
    uint64_t num_messages,
    uint64_t* out_consumed,
    double*   out_mps,
    double*   out_gbps,
    uint64_t* out_bytes,
    uint64_t* out_corrupt,
) noexcept nogil:

    cdef:
        SharedMemSystem shmsys
        Context*        ctx
        int             rc
        uint64_t        consumed = 0
        uint64_t        total_bytes = 0
        uint64_t        start=0, end=0
        uint64_t        elapsed
        double          mps
        double          gbps
        char*           out_buf
        size_t          out_size
        size_t          pay_sz = 0
        uint64_t        mask
        char*           verify_buf = NULL
        BenchMsgHeader  hdr
        uint32_t        got_crc, want_crc
        uint64_t        corrupt_count = 0

    if out_consumed != NULL:
        out_consumed[0] = 0

    memset(&shmsys, 0, sizeof(SharedMemSystem))
    shmsys.shm_name    = shm_name
    shmsys.sem_name    = sem_name
    shmsys.block_count = BENCH_BLOCK_COUNT
    shmsys.block_size  = BENCH_BLOCK_SIZE
    shmsys.mode        = mode

    shmsys.ctx         = <Context*>malloc(sizeof(Context))

    if shmsys.ctx == NULL:
        printf(b"[CONSUMER] OOM for Context\n")
        return
    
    placement_new[Context](shmsys.ctx)
    shmsys.ctx.role = ProcessRole.Consumer
    
    cdef int ret = init_consumer_system(&shmsys) 
    
    if ret != 0:
        printf(b"[CONSUMER] init_consumer_system failed :: code :: %d\n", ret)
        free(shmsys.ctx)
        return

    ctx = shmsys.ctx
    ctx.running = 1
    ctx.local_flags = 0

    if pair == PAIR_PUSH_POP or pair == PAIR_TRY_PUSH_POP or pair == PAIR_PUSH_BORROW_COMMIT:
        verify_buf = <char*>malloc(BENCH_BLOCK_SIZE)
        if verify_buf == NULL:
            printf(b"[CONSUMER] OOM for verify_buf\n")
            return


    printf(b"READY\n")
    fflush(stdout)

    while True:
        out_buf = NULL
        out_size = 0

        if pair == PAIR_PUSH_POP:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_pop(ctx, &out_buf, &out_size)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_pop(ctx, &out_buf, &out_size)
            else:
                rc = ipc_mpmc_pop(ctx, &out_buf, &out_size)
        elif pair == PAIR_PUSH_BORROW_COMMIT:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_pop_borrow(ctx, &out_buf, &out_size)
                #if rc == IPC_OK:
                #    ipc_spmc_pop_commit(ctx)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_pop_borrow(ctx, &out_buf, &out_size)
                #if rc == IPC_OK:
                #    ipc_mpsc_pop_commit(ctx)
            else:
                rc = ipc_mpmc_pop_borrow(ctx, &out_buf, &out_size)
                #if rc == IPC_OK:
                #    ipc_mpmc_pop_commit(ctx)
            if rc == IPC_OK:
                if out_size < sizeof(BenchMsgHeader) or out_size > BENCH_BLOCK_SIZE:
                    corrupt_count += 1
                else:
                    memcpy(verify_buf, out_buf, out_size)
                    hdr = (<BenchMsgHeader*>verify_buf)[0]
                    got_crc = hdr.crc32
                    (<BenchMsgHeader*>verify_buf)[0].crc32 = 0
                    want_crc = bench_crc32c(verify_buf, out_size, 0xFFFFFFFF)
                    if hdr.magic != BENCH_MAGIC or hdr.payload_size != out_size or got_crc != want_crc:
                        corrupt_count += 1
                if mode == RunningMode.SPMC:
                    ipc_spmc_pop_commit(ctx)
                elif mode == RunningMode.MPSC:
                    ipc_mpsc_pop_commit(ctx)
                else:
                    ipc_mpmc_pop_commit(ctx)
        elif pair == PAIR_PUSH_VAR_POP_VAR:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_pop_var(ctx, &out_buf, &out_size)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_pop_var(ctx, &out_buf, &out_size)
            else:
                rc = ipc_mpmc_pop_var(ctx, &out_buf, &out_size)
        elif pair == PAIR_TRY_PUSH_POP:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_try_pop(ctx, &out_buf, &out_size)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_try_pop(ctx, &out_buf, &out_size)
            else:
                rc = ipc_mpmc_try_pop(ctx, &out_buf, &out_size)
        elif pair == PAIR_TRY_PUSH_VAR_POP_VAR:
            if mode == RunningMode.SPMC:
                rc = ipc_spmc_try_pop_var(ctx, &out_buf, &out_size)
            elif mode == RunningMode.MPSC:
                rc = ipc_mpsc_try_pop_var(ctx, &out_buf, &out_size)
            else:
                rc = ipc_mpmc_try_pop_var(ctx, &out_buf, &out_size)
        else:
            rc = IPC_ERR

        if rc == IPC_OK:
            if consumed == 0:
                start = now_ns()
            consumed += 1
            total_bytes += out_size

            if pair == PAIR_PUSH_POP or pair == PAIR_TRY_PUSH_POP:
                if out_size <= BENCH_BLOCK_SIZE:
                    memcpy(verify_buf, out_buf, out_size)
                if out_size < sizeof(BenchMsgHeader) or out_size > BENCH_BLOCK_SIZE:
                    corrupt_count += 1
                else:
                    hdr = (<BenchMsgHeader*>verify_buf)[0]
                    got_crc = hdr.crc32
                    (<BenchMsgHeader*>verify_buf)[0].crc32 = 0
                    want_crc = bench_crc32c(verify_buf, out_size, 0xFFFFFFFF)
                    (<BenchMsgHeader*>verify_buf)[0].crc32 = got_crc
                    if hdr.magic != BENCH_MAGIC or hdr.payload_size != out_size or got_crc != want_crc:
                        corrupt_count += 1
            elif pair == PAIR_PUSH_VAR_POP_VAR or pair == PAIR_TRY_PUSH_VAR_POP_VAR:
                if out_size < sizeof(BenchMsgHeader):
                    corrupt_count += 1
                else:
                    hdr = (<BenchMsgHeader*>out_buf)[0]
                    got_crc = hdr.crc32
                    (<BenchMsgHeader*>out_buf)[0].crc32 = 0
                    want_crc = bench_crc32c(out_buf, out_size, 0xFFFFFFFF)
                    (<BenchMsgHeader*>out_buf)[0].crc32 = got_crc
                    if hdr.magic != BENCH_MAGIC or hdr.payload_size != out_size or got_crc != want_crc:
                        corrupt_count += 1
        elif rc == IPC_EMPTY:
            if (pair == PAIR_TRY_PUSH_POP or pair == PAIR_TRY_PUSH_VAR_POP_VAR) and \
               (ctx.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                break
            cpu_pause()

        #elif rc == IPC_FULL:
        #    cpu_pause()

        elif rc == IPC_CLOSING:
            break
        else:
            printf(b"[CONSUMER] pop error: %d\n", rc)
            break

    end = now_ns()
    elapsed = end - start
    if elapsed == 0:
        elapsed = 1

    mps  = (<double>consumed * 1e9) / <double>elapsed
    gbps = (<double>total_bytes / <double>elapsed)

    if out_mps != NULL:
        out_mps[0] = mps
    if out_gbps != NULL:
        out_gbps[0] = gbps
    if out_bytes != NULL:
        out_bytes[0] = total_bytes
    
    if out_consumed != NULL:
        out_consumed[0] = consumed
    if out_corrupt != NULL:
        out_corrupt[0] = corrupt_count
    if verify_buf != NULL:
        free(verify_buf)
    detach_consumer(&shmsys, -1, -1)

    with gil:
        if ctx.shm_obj != NULL:
            del ctx.shm_obj
            ctx.shm_obj = NULL
        if ctx.sem_obj != NULL:
            del ctx.sem_obj
            ctx.sem_obj = NULL
    if ctx.assemble_buf != NULL:
        free(ctx.assemble_buf)
    free(ctx)



def run_producer(
    bytes shm_name,
    bytes sem_name,
    int mode,
    int pair,
    uint64_t num_messages = 4000000,
    uint32_t payload_size = FIXED_PAYLOAD_SZ,
    uint32_t producer_id = 0
):
    cdef:
        const char* shm = shm_name
        const char* sem = sem_name
        RunningMode m = <RunningMode>mode
        BenchPair p = <BenchPair>pair
        uint64_t pushed = 0
        double mps = 0.0, gbps = 0.0
        uint64_t nbytes = 0
        uint32_t* size_table = NULL
        int       table_len  = 0
        uint32_t  min_sz     = BENCH_BLOCK_SIZE - HDR_SZ
        uint32_t  max_sz     = payload_size
        int       i
    
    if p == PAIR_PUSH_VAR_POP_VAR or p == PAIR_TRY_PUSH_VAR_POP_VAR:
        if max_sz < min_sz:
            max_sz = min_sz
        py_sizes  = _gen_var_payload_sizes(min_sz, max_sz)

        table_len = len(py_sizes)
        size_table = <uint32_t*>malloc(table_len * sizeof(uint32_t))
        if size_table == NULL:
            table_len = 0
        else:
            for i in range(table_len):
                size_table[i] = <uint32_t>py_sizes[i]

    _producer_bench(shm, sem, m, p, num_messages, max_sz, producer_id,
                     size_table, table_len, &pushed, &mps, &gbps, &nbytes)

    if size_table != NULL:
        free(size_table)

    return {"sent": pushed, "mps": mps, "gbps": gbps, "bytes": nbytes}


def run_consumer(
    bytes shm_name,
    bytes sem_name,
    int mode,
    int pair,
    uint64_t num_messages = 4000000
):
    cdef:
        const char* shm = shm_name
        const char* sem = sem_name
        RunningMode m = <RunningMode>mode
        BenchPair p = <BenchPair>pair
        uint64_t consumed = 0
        double mps = 0.0, gbps = 0.0
        uint64_t nbytes = 0
        uint64_t ncorrupt = 0

    _consumer_bench(shm, sem, m, p, num_messages, &consumed, &mps, &gbps, &nbytes, &ncorrupt)
    return {"received": consumed, "mps": mps, "gbps": gbps, "bytes": nbytes, "corrupt": ncorrupt}