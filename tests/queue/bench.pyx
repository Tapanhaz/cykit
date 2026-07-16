
"""
Intra-process throughput benchmark for Queue.
Producer/ Producers and Consumer / Consumers run as threads.

Pairs tested:
  - push / pop
  - push / pop_borrow + commit
  - push_var / pop_var
  - try_push / try_pop
  - try_prush_var / try_pop_var 

For SPSC, SPMC, MPSC and MPMC modes.
"""


import random
cimport cython
from libcpp.atomic cimport atomic
from libc.string cimport memset, memcpy
from libc.stddef cimport size_t
from libc.stdlib cimport malloc, free
from libc.stdint cimport uint32_t, uint64_t, uint8_t
from libc.stdio cimport printf, fflush, stdout

from cykit.common cimport (
    cpu_pause,
    memory_order_acquire,
    memory_order_release,
    memory_order_relaxed,
    make_thread, thread,
    placement_new, placement_destroy,
    set_thread_affinity, hw_concurrency
)

from cykit.queue cimport (
    Queue, QueueImpl, QueueMode, spsc_push, spsc_pop,
    Q_OK, Q_EMPTY, Q_FULL, Q_ERR, Q_PARTIAL, Q_SKIP, Q_NO_CONSUMER,
    F_CLOSING, queue_close
)

from cykit.utils.compat cimport now_ns, usleep_

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
    BENCH_CAPACITY     = 16384    
    BENCH_SLOT_SIZE    = 256      
    FIXED_PAYLOAD_SZ   = 64
    VAR_PAYLOAD_LARGE  = 600   

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



cdef struct ProducerArgs:
    QueueImpl* q
    BenchPair  pair
    uint64_t   num_messages
    uint32_t   producer_id
    uint32_t*  size_table   
    int        table_len
    size_t     fixed_size   # fixed pairs only
    uint64_t   pushed
    uint64_t   total_bytes
    double     mps
    double     gbps
    uint8_t[120] _pad 

cdef struct ConsumerArgs:
    QueueImpl*       q
    BenchPair        pair
    bint             needs_register   
    uint32_t         reader_id   
    atomic[uint64_t] ready    
    uint64_t         received
    uint64_t         total_bytes
    double           mps
    double           gbps
    uint64_t         discard_count
    uint64_t         resync_count
    uint64_t         corrupt_count
    uint8_t[120] _pad 


cdef void _producer_thread(ProducerArgs* a) noexcept nogil:
    cdef:
        QueueImpl*      q = a.q
        int             rc
        uint64_t        pushed = 0
        uint64_t        total_bytes = 0
        uint64_t        start=0, end=0
        uint64_t        elapsed = 0
        double          mps
        double          gbps
        char*           payload
        size_t          pay_sz = a.fixed_size
        size_t          cur_sz
        bint            is_var = (a.pair == PAIR_PUSH_VAR_POP_VAR or a.pair == PAIR_TRY_PUSH_VAR_POP_VAR)
        BenchPair       pair   = a.pair
        

    payload = <char*>malloc(pay_sz)

    if payload == NULL:
        printf(b"[PRODUCER] OOM for payload\n")
        return

    memset(payload, 0xAA, pay_sz)

    printf(b"[PRODUCER] Starting: pair=%d  messages=%llu  payload=%zu\n",
           <int>pair, <unsigned long long>a.num_messages,
           <size_t>(a.size_table[0] if is_var and a.size_table != NULL else pay_sz))

    while a.pushed < a.num_messages:
        if is_var and a.size_table != NULL and a.table_len > 0:
            cur_sz = a.size_table[a.pushed % <uint64_t>a.table_len]
        else:
            cur_sz = pay_sz

        (<BenchMsgHeader*>payload)[0].magic        = BENCH_MAGIC
        (<BenchMsgHeader*>payload)[0].producer_id  = a.producer_id
        (<BenchMsgHeader*>payload)[0].local_seq    = a.pushed
        (<BenchMsgHeader*>payload)[0].payload_size = <uint32_t>cur_sz
        (<BenchMsgHeader*>payload)[0].crc32        = 0
        (<BenchMsgHeader*>payload)[0].crc32 = bench_crc32c(
            payload, cur_sz, 0xFFFFFFFF
        )

        
        if pair == PAIR_PUSH_POP or pair == PAIR_PUSH_BORROW_COMMIT:
            rc = q.fn_push(<void*>q, payload, pay_sz)
            #rc = spsc_push(<void*>q, payload, pay_sz)
        elif pair == PAIR_PUSH_VAR_POP_VAR:
            rc = q.fn_push_var(<void*>q, payload, cur_sz)
        elif pair == PAIR_TRY_PUSH_POP:
            rc = q.fn_try_push(<void*>q, payload, pay_sz)

        elif pair == PAIR_TRY_PUSH_VAR_POP_VAR:
            rc = q.fn_try_push_var(<void*>q, payload, cur_sz)
        else:
            rc = Q_ERR

        if rc == Q_OK:
            if a.pushed == 0:
                start = now_ns()
            a.pushed += 1
            a.total_bytes += cur_sz
        elif rc == Q_FULL or rc == Q_NO_CONSUMER:
            #cpu_pause()
            usleep_(100)
        elif not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
            break
        else:
            printf(b"[PRODUCER] push error: %d\n", rc)
            break

    end = now_ns()
    elapsed = end - start
    if elapsed == 0:
        elapsed = 1

    a.mps  = (<double>a.pushed * 1e9) / <double>elapsed
    a.gbps = (<double>a.total_bytes / <double>elapsed)
    free(payload)


cdef void _consumer_thread(ConsumerArgs* a) noexcept nogil:

    cdef:
        QueueImpl*      q = a.q
        BenchPair       pair = a.pair
        int             rc
        uint64_t        consumed = 0
        uint64_t        total_bytes = 0
        uint64_t        start=0, end=0
        uint64_t        elapsed=0
        double          mps
        double          gbps
        char*           out_buf
        size_t          out_size
        BenchMsgHeader  hdr
        uint32_t        got_crc, want_crc
        char*           verify_buf = NULL

    if a.needs_register:
        rc = q.fn_register_consumer(<void*>q, &a.reader_id)
        if rc != Q_OK:
            printf(b"[CONSUMER] register_consumer failed: %d\n", rc)
            return
    
    if pair == PAIR_PUSH_BORROW_COMMIT:
        verify_buf = <char*>malloc(q.slot_size)
        if verify_buf == NULL:
            printf(b"[CONSUMER] OOM for verify_buf\n")
            return
    
    a.ready.store(1, memory_order_release)

    while True:
        out_buf = NULL
        out_size = 0

        if pair == PAIR_PUSH_POP:
            rc = q.fn_pop(<void*>q, &out_buf, &out_size)
            #rc = spsc_pop(<void*>q, &out_buf, &out_size)
        elif pair == PAIR_PUSH_BORROW_COMMIT:
            rc = q.fn_pop_borrow(<void*>q, &out_buf, &out_size)
            if rc == Q_OK:
                if out_size < sizeof(BenchMsgHeader) or out_size > q.slot_size:
                    a.corrupt_count += 1
                else:
                    memcpy(verify_buf, out_buf, out_size)
                    hdr = (<BenchMsgHeader*>verify_buf)[0]
                    got_crc = hdr.crc32
                    (<BenchMsgHeader*>verify_buf)[0].crc32 = 0
                    want_crc = bench_crc32c(verify_buf, out_size, 0xFFFFFFFF)
                    if hdr.magic != BENCH_MAGIC or hdr.payload_size != out_size or got_crc != want_crc:
                        a.corrupt_count += 1
                q.fn_pop_commit(<void*>q)
        elif pair == PAIR_PUSH_VAR_POP_VAR:
            rc = q.fn_pop_var(<void*>q, &out_buf, &out_size)
        elif pair == PAIR_TRY_PUSH_POP:
            rc = q.fn_try_pop(<void*>q, &out_buf, &out_size)
        elif pair == PAIR_TRY_PUSH_VAR_POP_VAR:
            rc = q.fn_try_pop_var(<void*>q, &out_buf, &out_size)
        else:
            rc = Q_ERR

        if rc == Q_OK:
            if consumed == 0:
                start = now_ns()
            consumed += 1
            total_bytes += out_size

            if pair == PAIR_PUSH_POP or pair == PAIR_TRY_PUSH_POP:
                if out_size < sizeof(BenchMsgHeader) or out_size > q.slot_size:
                    a.corrupt_count += 1
                else:
                    hdr = (<BenchMsgHeader*>out_buf)[0]
                    got_crc = hdr.crc32
                    (<BenchMsgHeader*>out_buf)[0].crc32 = 0
                    want_crc = bench_crc32c(out_buf, out_size, 0xFFFFFFFF)
                    (<BenchMsgHeader*>out_buf)[0].crc32 = got_crc
                    if hdr.magic != BENCH_MAGIC or hdr.payload_size != out_size or got_crc != want_crc:
                        a.corrupt_count += 1
            elif pair == PAIR_PUSH_VAR_POP_VAR or pair == PAIR_TRY_PUSH_VAR_POP_VAR:
                if out_size < sizeof(BenchMsgHeader):
                    a.corrupt_count += 1
                else:
                    hdr = (<BenchMsgHeader*>out_buf)[0]
                    got_crc = hdr.crc32
                    (<BenchMsgHeader*>out_buf)[0].crc32 = 0
                    want_crc = bench_crc32c(out_buf, out_size, 0xFFFFFFFF)
                    (<BenchMsgHeader*>out_buf)[0].crc32 = got_crc
                    if hdr.magic != BENCH_MAGIC or hdr.payload_size != out_size or got_crc != want_crc:
                        a.corrupt_count += 1
        elif rc == Q_EMPTY:
            if (pair == PAIR_TRY_PUSH_POP or pair == PAIR_TRY_PUSH_VAR_POP_VAR) and \
               (not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING)):
                 break
            cpu_pause()

        elif rc == Q_FULL:
            #cpu_pause()
            usleep_(100)

        elif not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
            break
        else:
            printf(b"[CONSUMER] pop error: %d\n", rc)
            break

    end = now_ns()
    elapsed = end - start
    if elapsed == 0:
        elapsed = 1

    a.mps  = (<double>consumed * 1e9) / <double>elapsed
    a.gbps = (<double>total_bytes / <double>elapsed)
    a.received    = consumed
    a.total_bytes = total_bytes

    if verify_buf != NULL:
        free(verify_buf)

    if pair == PAIR_PUSH_VAR_POP_VAR or pair == PAIR_TRY_PUSH_VAR_POP_VAR:
        if a.needs_register:
            a.discard_count = q.consumer_ctx[a.reader_id].value.discard_count
            a.resync_count  = q.consumer_ctx[a.reader_id].value.resync_count
        else:
            a.discard_count = q.consumer_ctx[0].value.discard_count
            a.resync_count  = q.consumer_ctx[0].value.resync_count

    if a.needs_register:
        q.fn_unregister_consumer(<void*>q, a.reader_id)


cpdef run_queue_bench(
    int mode,
    int pair,
    int n_prod,
    int n_cons,
    uint64_t num_messages = 2_000_000,
    payload_size = None,
    size_t slot_size = BENCH_SLOT_SIZE,
    size_t capacity  = BENCH_CAPACITY,
):
    
    cdef:
        QueueMode qmode = <QueueMode>mode
        BenchPair p     = <BenchPair>pair
        bint is_var     = (p == PAIR_PUSH_VAR_POP_VAR or p == PAIR_TRY_PUSH_VAR_POP_VAR)
        bint needs_reg  = (qmode == QueueMode.SPMC or qmode == QueueMode.MPMC)
        uint32_t min_sz = <uint32_t>slot_size
        uint32_t max_sz
        int i, j

    if qmode == QueueMode.SPSC and (n_prod != 1 or n_cons != 1):
        raise ValueError("SPSC requires exactly 1 producer and 1 consumer")
    if qmode == QueueMode.SPMC and n_prod != 1:
        raise ValueError("SPMC requires exactly 1 producer")
    if qmode == QueueMode.MPSC and n_cons != 1:
        raise ValueError("MPSC requires exactly 1 consumer")

    if payload_size is None:
        payload_size = VAR_PAYLOAD_LARGE if is_var else FIXED_PAYLOAD_SZ
    max_sz = <uint32_t>payload_size

    cdef Queue queue = Queue(slot_size, capacity, qmode, False, False, True)
    cdef QueueImpl* qimpl = &queue._q

    # Producer ====
    cdef ProducerArgs* pargs = <ProducerArgs*>malloc(n_prod * sizeof(ProducerArgs))
    cdef uint32_t** tables   = <uint32_t**>malloc(n_prod * sizeof(uint32_t*))
    cdef thread* pthreads    = <thread*>malloc(n_prod * sizeof(thread))
    if pargs == NULL or tables == NULL or pthreads == NULL:
        raise MemoryError("failed to allocate producer bookkeeping")
    
    for i in range(n_prod):
        placement_new[thread](&pthreads[i])

    for i in range(n_prod):
        tables[i] = NULL
        memset(&pargs[i], 0, sizeof(ProducerArgs))
        pargs[i].q            = qimpl
        pargs[i].pair         = p
        pargs[i].num_messages = num_messages
        pargs[i].producer_id  = <uint32_t>i

        if is_var:
            if max_sz < min_sz:
                max_sz = min_sz
            py_sizes = _gen_var_payload_sizes(min_sz, max_sz)
            pargs[i].table_len = len(py_sizes)
            tables[i] = <uint32_t*>malloc(pargs[i].table_len * sizeof(uint32_t))
            if tables[i] == NULL:
                pargs[i].table_len = 0
            else:
                for j in range(pargs[i].table_len):
                    tables[i][j] = <uint32_t>py_sizes[j]
            pargs[i].size_table = tables[i]
            pargs[i].fixed_size = max_sz
        else:
            pargs[i].fixed_size = min(<size_t>max_sz, slot_size)

    # Consumer ===
    cdef ConsumerArgs* cargs = <ConsumerArgs*>malloc(n_cons * sizeof(ConsumerArgs))
    cdef thread* cthreads    = <thread*>malloc(n_cons * sizeof(thread))
    if cargs == NULL or cthreads == NULL:
        raise MemoryError("failed to allocate consumer bookkeeping")
    
    for i in range(n_cons):
        placement_new[thread](&cthreads[i])

    for i in range(n_cons):
        placement_new[ConsumerArgs](&cargs[i])
        cargs[i].q              = qimpl
        cargs[i].pair           = p
        cargs[i].needs_register = needs_reg
        cargs[i].reader_id      = 0
        cargs[i].ready.store(0, memory_order_relaxed)

    cdef unsigned int ncores = hw_concurrency()
    cdef int core_id

    with nogil:
        for i in range(n_cons):
            cthreads[i] = make_thread(_consumer_thread, &cargs[i])
            if ncores > 0:
                core_id = <int>(i % ncores)
                set_thread_affinity(cthreads[i], core_id)       

        for i in range(n_cons):
            while cargs[i].ready.load(memory_order_acquire) == 0:
                cpu_pause()

        for i in range(n_prod):
            pthreads[i] = make_thread(_producer_thread, &pargs[i])        
            if ncores > 0:
                core_id = <int>((n_cons + i) % ncores)
                set_thread_affinity(pthreads[i], core_id)

        for i in range(n_prod):
            pthreads[i].join()
        
        queue_close(<void*>qimpl, -1)

        for i in range(n_cons):
            if cthreads[i].joinable():
                cthreads[i].join()

        

        for i in range(n_prod):
            placement_destroy[thread](&pthreads[i])
        for i in range(n_cons):
            placement_destroy[thread](&cthreads[i])
        for i in range(n_cons):
            placement_destroy[ConsumerArgs](&cargs[i])

    prod_results = []
    for i in range(n_prod):
        prod_results.append({
            "sent": pargs[i].pushed, "mps": pargs[i].mps,
            "gbps": pargs[i].gbps, "bytes": pargs[i].total_bytes,
        })
    cons_results = []
    for i in range(n_cons):
        cons_results.append({
            "received": cargs[i].received, "mps": cargs[i].mps,
            "gbps": cargs[i].gbps, "bytes": cargs[i].total_bytes,
            "discards": cargs[i].discard_count, "resyncs": cargs[i].resync_count,
            "corrupt": cargs[i].corrupt_count,
        })

    for i in range(n_prod):
        if tables[i] != NULL:
            free(tables[i])
    free(tables)
    free(pargs)
    free(pthreads)
    free(cargs)
    free(cthreads)

    return prod_results, cons_results
