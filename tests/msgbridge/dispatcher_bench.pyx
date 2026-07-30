"""
Functional integrity harness for msgbridge SyncDispatcher and AsyncDispatcher.

"""

cimport cython
import struct
import time
import asyncio
import threading

from libc.string  cimport memset
from libc.stdlib  cimport malloc, free
from libc.stdint  cimport uint32_t, uint64_t
from cykit.common cimport (
    make_thread, 
    thread, 
    atomic_bool, 
    memory_order_acquire, 
    memory_order_release, 
    cpu_pause,
    placement_new,
    placement_destroy
)
from cykit.utils.compat cimport now_ns, usleep_
from cykit.queue  cimport Q_OK, Q_EMPTY, Q_FULL, Q_CLOSING, Q_NO_CONSUMER, Q_ORPHANED, Q_ERR
from cykit.utils.msgbridge cimport SyncDispatcher, AsyncDispatcher

cdef extern from *:
    """
    #include <cstdint>
    #include <cstddef>
    static inline uint32_t db_crc32c(const char* data, size_t len, uint32_t seed) {
        const unsigned char* p = (const unsigned char*)data;
        uint64_t h = 14695981039346656037ULL ^ (uint64_t)seed;
        for (size_t i = 0; i < len; ++i) {
            h ^= (uint64_t)p[i];
            h *= 1099511628211ULL;
        }
        return (uint32_t)(h ^ (h >> 32));
    }
    """
    uint32_t db_crc32c(const char* data, size_t length, uint32_t crc) noexcept nogil


cdef packed struct DispatchMsgHeader:
    uint32_t magic
    uint64_t seq
    uint32_t payload_size
    uint32_t crc32

cdef uint32_t DISPATCH_MAGIC = 0x0D15CAFE


_HDR_FMT          = "<IQII"
_HDR_SIZE         = struct.calcsize(_HDR_FMT)
DISPATCH_MAGIC_PY = 0x0D15CAFE


def _fnv_crc32c(data, seed=0xFFFFFFFF):
    h = 0xcbf29ce484222325 ^ (seed & 0xFFFFFFFFFFFFFFFF)
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return (h ^ (h >> 32)) & 0xFFFFFFFF


class _Recorder:
    def __init__(self):
        self.received   = 0
        self.corrupt     = 0
        self.total_bytes = 0
        self.seqs_seen   = set()
        self._lock   = threading.Lock()

    def _verify(self, data):
        with self._lock:
            self.received += 1
            self.total_bytes += len(data)
            if len(data) < _HDR_SIZE:
                self.corrupt += 1
                return
            magic, seq, payload_size, crc = struct.unpack_from(_HDR_FMT, data, 0)
            if magic != DISPATCH_MAGIC_PY or payload_size != len(data):
                self.corrupt += 1
                return
            zeroed = data[:16] + b"\x00\x00\x00\x00" + data[20:]
            if _fnv_crc32c(zeroed) != crc:
                self.corrupt += 1
                return
            self.seqs_seen.add(seq)
    
    def received_count(self):
        with self._lock:
            return self.received

    def __call__(self, data):
        self._verify(data)


class _AsyncRecorder(_Recorder):
    async def __call__(self, data):
        self._verify(data)


# For bench throughput::
class _RawRecorder:
    def __init__(self):
        self.received    = 0
        self.total_bytes = 0
        self.corrupt      = 0
        self.seqs_seen    = ()
    def __call__(self, data):
        self.received    += 1
        self.total_bytes += len(data)
    
    def received_count(self):
        return self.received


class _AsyncRawRecorder(_RawRecorder):
    async def __call__(self, data):
        self.received    += 1
        self.total_bytes += len(data)


# ============================ Sync producer ==================================

cdef struct SyncProdArgs:
    void*        dispatcher
    uint64_t     num_messages
    uint64_t     pushed
    size_t       payload_size
    bint         nonblocking    
    int          fail_rc        
    double       elapsed_ns


cdef void _sync_producer_thread(SyncProdArgs* a) noexcept nogil:
    cdef:
        char*    payload = <char*>malloc(a.payload_size)
        uint64_t start, end
        int      rc

    if payload == NULL:
        return

    memset(payload, 0xAB, a.payload_size)
    start = now_ns()

    while a.pushed < a.num_messages:
        (<DispatchMsgHeader*>payload)[0].magic        = DISPATCH_MAGIC
        (<DispatchMsgHeader*>payload)[0].seq          = a.pushed
        (<DispatchMsgHeader*>payload)[0].payload_size = <uint32_t>a.payload_size
        (<DispatchMsgHeader*>payload)[0].crc32        = 0
        (<DispatchMsgHeader*>payload)[0].crc32 = db_crc32c(payload, a.payload_size, 0xFFFFFFFF)

        rc = (<SyncDispatcher>a.dispatcher).push(<SyncDispatcher>a.dispatcher, payload, a.payload_size)

        if rc == Q_OK:
            a.pushed += 1
        elif a.nonblocking and (rc == Q_FULL or rc == Q_EMPTY):
            cpu_pause()
        else:
            a.fail_rc = rc
            break

    end = now_ns()
    a.elapsed_ns = <double>(end - start)
    free(payload)


cpdef dict run_sync_dispatcher_bench(
    uint64_t num_messages  = 200_000,
    size_t   payload_size  = 64,
    bint     variable_size = False,
    bint     nonblocking   = True,
    bint     block_on_full = False,
    size_t   capacity      = 16384,
    size_t   slot_size     = 256,
    double   timeout_sec   = 30.0,
    bint     raw           = False,
):
    cdef:
        SyncDispatcher dispatcher
        SyncProdArgs   args
        thread         prod_thread

    if payload_size < _HDR_SIZE:
        raise ValueError(f"payload_size must be >= header size ({_HDR_SIZE})")

    if not nonblocking and not block_on_full:
        block_on_full = True

    if raw:
        recorder = _RawRecorder()
    else:
        recorder = _Recorder()

    dispatcher = SyncDispatcher(
        recorder,
        capacity=capacity, slot_size=slot_size,
        variable_size=variable_size, nonblocking=nonblocking,
        block_on_full=block_on_full,
        detach=False,
    )
    dispatcher.setup()

    memset(&args, 0, sizeof(SyncProdArgs))
    args.dispatcher   = <void*>dispatcher
    args.num_messages = num_messages
    args.payload_size = payload_size
    args.nonblocking  = nonblocking

    with nogil:
        prod_thread = make_thread(_sync_producer_thread, &args)
        prod_thread.join()

    if args.fail_rc != 0 and args.fail_rc != Q_CLOSING:
        raise RuntimeError(
            f"producer aborted after {args.pushed}/{num_messages} pushes, "
            f"rc={args.fail_rc}"
        )

    deadline = time.monotonic() + timeout_sec
    while recorder.received_count() < num_messages and time.monotonic() < deadline:
        time.sleep(0.005)

    dispatcher.close()

    return {
        "sent":        args.pushed,
        "received":    recorder.received,
        "corrupt":     recorder.corrupt,
        "unique_seqs": len(recorder.seqs_seen),
        "bytes":       recorder.total_bytes,
        "timed_out":   recorder.received < num_messages,
        "elapsed_ns":  args.elapsed_ns,
        "fail_rc":     args.fail_rc,
    }


# ============================ Async producer =================================

cdef struct AsyncProdArgs:
    void*        dispatcher
    uint64_t     num_messages
    uint64_t     pushed
    size_t       payload_size
    bint         nonblocking
    int          fail_rc
    double       elapsed_ns
    atomic_bool  done 


cdef void _async_producer_thread(AsyncProdArgs* a) noexcept nogil:
    cdef:
        char*    payload = <char*>malloc(a.payload_size)
        uint64_t start, end
        int      rc

    if payload == NULL:
        return

    memset(payload, 0xAB, a.payload_size)
    start = now_ns()

    while a.pushed < a.num_messages:
        (<DispatchMsgHeader*>payload)[0].magic        = DISPATCH_MAGIC
        (<DispatchMsgHeader*>payload)[0].seq          = a.pushed
        (<DispatchMsgHeader*>payload)[0].payload_size = <uint32_t>a.payload_size
        (<DispatchMsgHeader*>payload)[0].crc32        = 0
        (<DispatchMsgHeader*>payload)[0].crc32 = db_crc32c(payload, a.payload_size, 0xFFFFFFFF)

        rc = (<AsyncDispatcher>a.dispatcher).push(<AsyncDispatcher>a.dispatcher, payload, a.payload_size)

        if rc == Q_OK:
            a.pushed += 1
        elif a.nonblocking and (rc == Q_FULL or rc == Q_EMPTY):
            cpu_pause()
        else:
            a.fail_rc = rc
            break

    end = now_ns()
    a.elapsed_ns = <double>(end - start)
    free(payload)


cdef void _async_supervisor_thread(AsyncProdArgs* a) noexcept nogil:
    cdef thread prod_thread = make_thread(_async_producer_thread, a)
    prod_thread.join()
    a.done.store(1, memory_order_release)


async def _run_async_bench(num_messages, payload_size, variable_size,
                            nonblocking, capacity, slot_size, timeout_sec, raw):
    cdef:
        AsyncDispatcher dispatcher
        AsyncProdArgs*  args
        thread          sup_thread

    if payload_size < _HDR_SIZE:
        raise ValueError(f"payload_size must be >= header size ({_HDR_SIZE})")

    if raw:
        recorder = _AsyncRawRecorder()
    else:
        recorder = _AsyncRecorder()
        
    dispatcher = AsyncDispatcher(
        recorder, capacity=capacity, slot_size=slot_size, variable_size=variable_size
    )
    dispatcher.setup()

    args = <AsyncProdArgs*>malloc(sizeof(AsyncProdArgs))
    if args == NULL:
        raise MemoryError("failed to allocate AsyncProdArgs")
    #memset(args, 0, sizeof(AsyncProdArgs))
    placement_new[AsyncProdArgs](args)
    args.dispatcher   = <void*>dispatcher
    args.num_messages = num_messages
    args.payload_size = payload_size
    args.nonblocking  = nonblocking

    with nogil:
        sup_thread = make_thread(_async_supervisor_thread, args)
        sup_thread.detach()

    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout_sec

    while not args.done.load(memory_order_acquire) and loop.time() < deadline:
        await asyncio.sleep(0.005)
    while recorder.received < num_messages and loop.time() < deadline:
        await asyncio.sleep(0.005)

    pushed      = args.pushed
    elapsed_ns  = args.elapsed_ns
    fail_rc     = args.fail_rc
    placement_destroy[AsyncProdArgs](args)
    free(args)

    if fail_rc != 0 and fail_rc != Q_CLOSING:
        dispatcher.close()
        raise RuntimeError(
            f"producer aborted after {pushed}/{num_messages} pushes, rc={fail_rc}"
        )

    dispatcher.close()
    await asyncio.sleep(0)

    return {
        "sent":       pushed,
        "received":   recorder.received,
        "corrupt":    recorder.corrupt,
        "bytes":      recorder.total_bytes,
        "timed_out":  recorder.received < num_messages,
        "elapsed_ns": elapsed_ns,
        "fail_rc":    fail_rc,
    }


cpdef dict run_async_dispatcher_bench(
    uint64_t num_messages  = 50_000,
    size_t   payload_size  = 64,
    bint     variable_size = False,
    bint     nonblocking   = True,
    size_t   capacity      = 16384,
    size_t   slot_size     = 256,
    double   timeout_sec   = 30.0,
    bint     raw           = False,
):
    return asyncio.run(_run_async_bench(
        num_messages, payload_size, variable_size, nonblocking,
        capacity, slot_size, timeout_sec, raw
    ))