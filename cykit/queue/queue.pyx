"""
@file queue.pyx
@brief Lock-free ring buffer queue supporting SPSC, SPMC, MPSC, and MPMC modes.
@date 2026-06-18
@copyright Part of the https://github.com/Tapanhaz/cykit library.

@note All cython push/pop variants are noexcept nogil and safe to call from C threads.
      SPMC/MPMC consumers must call register_consumer before popping and
      unregister_consumer on exit. All SPMC/MPSC/MPMC must call register_producer before pushing 
      and unregister_producer on exit.
"""

from libc.stdint  cimport uint64_t, uint32_t, uint16_t, int64_t
from libc.stddef  cimport size_t
from libc.string  cimport memcpy, memset
from libc.stdlib  cimport free, realloc, malloc

from cykit.common cimport (
    atomic_thread_fence,
    memory_order_acquire,
    memory_order_release,
    memory_order_relaxed,
    aligned_alloc_,
    aligned_free_,
    cpu_pause,
    builtin_ctzll,
    placement_new,
    placement_destroy,
    is_power_of_two
)

from cykit.utils.atomic cimport (
    atomic_wait, 
    atomic_notify_one, 
    atomic_notify_all, 
    CACHELINE
)

from cykit.utils.compat cimport (
    clock_gettime_,
    CLOCK_MONOTONIC_,
    usleep_,
    timespec_,
)

from cykit.utils.signal_handler cimport (
    init_signal_handler,
    context_notify_fn,
    register_context_notify,
    unregister_context_notify,
    cleanup_signal_handler,
)
#from libc.stdio cimport printf

cdef extern from * nogil:
    """
    #include <atomic>
    #include <cstdint>

    static inline int _cas_u64(void* obj, uint64_t* expected, uint64_t desired) {
        return reinterpret_cast<std::atomic<uint64_t>*>(obj)
            ->compare_exchange_weak(*expected, desired,
                std::memory_order_acq_rel,
                std::memory_order_relaxed);
    }

    struct _tls_consumer_state {
    uint32_t rid;
    uint64_t borrow_pos;
    uint64_t borrow_idx;
};
static thread_local _tls_consumer_state _tls_cs = { 0xFFFFFFFFu, 0, 0 };
static inline void     _tls_set_rid(uint32_t rid)       noexcept { _tls_cs.rid = rid; }
static inline uint32_t _tls_get_rid()                   noexcept { return _tls_cs.rid; }
static inline void     _tls_set_borrow(uint64_t pos, uint64_t idx) noexcept { _tls_cs.borrow_pos = pos; _tls_cs.borrow_idx = idx; }
static inline uint64_t _tls_get_borrow_pos()            noexcept { return _tls_cs.borrow_pos; }
static inline uint64_t _tls_get_borrow_idx()            noexcept { return _tls_cs.borrow_idx; }

struct _tls_producer_state {
    uint32_t pid;
};
static thread_local _tls_producer_state _tls_ps = { 0xFFFFFFFFu };
static inline void     _tls_set_pid(uint32_t pid) noexcept { _tls_ps.pid = pid; }
static inline uint32_t _tls_get_pid()             noexcept { return _tls_ps.pid; }
    """
    int      _cas_u64(void* obj, uint64_t* expected, uint64_t desired) noexcept nogil
    void     _tls_set_rid(uint32_t rid) noexcept nogil
    uint32_t _tls_get_rid() noexcept nogil
    void     _tls_set_borrow(uint64_t pos, uint64_t idx) noexcept nogil
    uint64_t _tls_get_borrow_pos() noexcept nogil
    uint64_t _tls_get_borrow_idx() noexcept nogil

    void     _tls_set_pid(uint32_t pid) noexcept nogil
    uint32_t _tls_get_pid() noexcept nogil


# =========================================================================
# ======================    HELPER FUNCTIONS    ===========================
# =========================================================================


cdef void queue_notify(void* ctx) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    #printf(b"Shutting Down .. please wait\n")
    q.running.store(0, memory_order_release)
    q.tail.fetch_add(1, memory_order_relaxed)
    q.head.fetch_add(1, memory_order_relaxed)
    atomic_notify_all(&q.tail, &q.tail_wm)
    atomic_notify_all(&q.head, &q.head_wm)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

cdef void py_queue_notify(void* ctx) noexcept nogil:
    cdef PyQueueImpl* q = <PyQueueImpl*>ctx
    #printf(b"Shutting Down .. please wait\n")
    q.running.store(0, memory_order_release)
    q.tail.fetch_add(1, memory_order_relaxed)
    q.head.fetch_add(1, memory_order_relaxed)
    atomic_notify_all(&q.tail, &q.tail_wm)
    atomic_notify_all(&q.head, &q.head_wm)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)


cdef inline bint _is_empty(QueueImpl* q) noexcept nogil:
    if q.mode == SPMC or q.mode == MPMC:
        return consumer_min_pos(q) == q.tail.load(memory_order_acquire)
    return q.head.load(memory_order_acquire) == q.tail.load(memory_order_acquire)

cdef inline uint64_t _slowest_consumer_pos(QueueImpl* q) noexcept nogil:
    if q.mode == SPMC or q.mode == MPMC:
        return consumer_min_pos(q)
    return q.head.load(memory_order_acquire)

cdef inline uint64_t _slowest_consumer_pos_py(PyQueueImpl* q) noexcept nogil:
    if q.mode == SPMC or q.mode == MPMC:
        return consumer_min_pos_py(q)
    return q.head.load(memory_order_acquire)

cdef inline int64_t elapsed_ms(timespec_* start, timespec_* now) noexcept nogil:
    return (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) // 1000000


cdef inline bint _claimed_slot_orphaned(
    QueueImpl* q, timespec_* slot_start, cbool* timer_started
) noexcept nogil:
    cdef timespec_ now
    if not timer_started[0]:
        clock_gettime_(CLOCK_MONOTONIC_, slot_start)
        timer_started[0] = True
        return False
    if q.producer_active_mask.value.load(memory_order_acquire) == 0:
        return True
    clock_gettime_(CLOCK_MONOTONIC_, &now)
    return elapsed_ms(slot_start, &now) >= <int64_t>POP_ORPHAN_STALL_MS


cdef inline bint _claimed_slot_orphaned_py(
    PyQueueImpl* q, timespec_* slot_start, cbool* timer_started
) noexcept nogil:
    cdef timespec_ now
    if not timer_started[0]:
        clock_gettime_(CLOCK_MONOTONIC_, slot_start)
        timer_started[0] = True
        return False
    if q.producer_active_mask.value.load(memory_order_acquire) == 0:
        return True
    clock_gettime_(CLOCK_MONOTONIC_, &now)
    return elapsed_ms(slot_start, &now) >= <int64_t>POP_ORPHAN_STALL_MS


cdef inline bint _all_readers_at(
    QueueImpl* q, uint64_t mask, uint64_t target
) noexcept nogil:
    cdef:
        uint64_t m = mask
        int i

    while m:
        i = builtin_ctzll(m)
        if q.reader_pos[i].value.load(memory_order_acquire) < target:
            return False
        m &= m - 1
    return True


cdef inline uint64_t consumer_min_pos(QueueImpl* q) noexcept nogil:
    cdef:
        uint64_t mask = q.reader_active_mask.value.load(memory_order_acquire)
        uint64_t tail = q.tail.load(memory_order_acquire)
        uint64_t pos
        int i
        cbool lag_evict = (q.flags.load(memory_order_relaxed) & F_LAG_EVICT) != 0

    if not lag_evict:
        while mask:
            i = builtin_ctzll(mask)
            pos = q.reader_pos[i].value.load(memory_order_acquire)
            if pos < tail:
                tail = pos
            mask &= mask - 1
        return tail
    
    cdef:        
        uint64_t min1 = tail
        uint64_t min2 = 0xFFFFFFFFFFFFFFFFULL
        uint64_t min1_bit = 0
        uint64_t min1_idx = 0
        uint64_t bit, cur, flagged
        uint64_t threshold = (q.capacity_mask + 1) // LAG_EVICT_DIVISOR

    while mask:
        i = builtin_ctzll(mask)
        bit = (<uint64_t>1) << i
        pos = q.reader_pos[i].value.load(memory_order_acquire)
        if pos < min1:
            min2 = min1
            min1 = pos
            min1_bit = bit
            min1_idx = i
        elif pos < min2:
            min2 = pos
        mask &= mask - 1

    if min1_bit == 0 or min2 == 0xFFFFFFFFFFFFFFFFULL or (min2 - min1) < threshold:
        return min1

    flagged = q.consumer_ctx[min1_idx].value.lag_flag_pos.load(memory_order_relaxed)

    if flagged != min1:
        q.consumer_ctx[min1_idx].value.lag_flag_pos.store(min1, memory_order_relaxed)
        return min1

    if (min2 - min1) < 2 * threshold:
        return min1

    cur = q.reader_active_mask.value.load(memory_order_acquire)
    while True:
        if _cas_u64(&q.reader_active_mask.value, &cur, cur & ~min1_bit):
            atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
            break
        cpu_pause()
    return min2


cdef inline uint64_t consumer_min_pos_py(PyQueueImpl* q) noexcept nogil:
    cdef:
        uint64_t mask = q.reader_active_mask.value.load(memory_order_acquire)
        uint64_t tail = q.tail.load(memory_order_acquire)
        uint64_t pos
        int i
        cbool lag_evict = (q.flags.load(memory_order_relaxed) & F_LAG_EVICT) != 0

    if not lag_evict:
        while mask:
            i = builtin_ctzll(mask)
            pos = q.reader_pos[i].value.load(memory_order_acquire)
            if pos < tail:
                tail = pos
            mask &= mask - 1
        return tail
    
    cdef:        
        uint64_t min1 = tail
        uint64_t min2 = 0xFFFFFFFFFFFFFFFFULL
        uint64_t min1_bit = 0
        uint64_t min1_idx = 0
        uint64_t bit, cur, flagged
        uint64_t threshold = (q.capacity_mask + 1) // LAG_EVICT_DIVISOR

    while mask:
        i = builtin_ctzll(mask)
        bit = (<uint64_t>1) << i
        pos = q.reader_pos[i].value.load(memory_order_acquire)
        if pos < min1:
            min2 = min1
            min1 = pos
            min1_bit = bit
            min1_idx = i
        elif pos < min2:
            min2 = pos
        mask &= mask - 1

    if min1_bit == 0 or min2 == 0xFFFFFFFFFFFFFFFFULL or (min2 - min1) < threshold:
        return min1

    flagged = q.lag_flag_pos[min1_idx].value.load(memory_order_relaxed)

    if flagged != min1:
        q.lag_flag_pos[min1_idx].value.store(min1, memory_order_relaxed)
        return min1

    if (min2 - min1) < 2 * threshold:
        return min1

    cur = q.reader_active_mask.value.load(memory_order_acquire)
    while True:
        if _cas_u64(&q.reader_active_mask.value, &cur, cur & ~min1_bit):
            atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
            break
        cpu_pause()
    return min2

cdef inline void consumer_update_min(QueueImpl* q) noexcept nogil:
    cdef:
        uint64_t new_min = consumer_min_pos(q)
        uint64_t old_min = q.reader_min_pos.load(memory_order_relaxed)
    
    while new_min > old_min:
        if _cas_u64(&q.reader_min_pos, &old_min, new_min):
            break
        cpu_pause()


cdef inline void consumer_update_min_py(PyQueueImpl* q) noexcept nogil:
    cdef:
        uint64_t new_min = consumer_min_pos_py(q)
        uint64_t old_min = q.reader_min_pos.load(memory_order_relaxed)

    while new_min > old_min:
        if _cas_u64(&q.reader_min_pos, &old_min, new_min):
            break
        cpu_pause()


cdef inline int _stage_slot(ConsumerCtx* cctx, char* src, size_t size) noexcept nogil:
    memcpy(cctx.scratch_buf, src, size)


cdef int queue_init(void* ctx, size_t slot_size, size_t capacity,
            bint needs_publish, uint8_t init_flags) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        size_t i

    if not is_power_of_two(<uint32_t>capacity) or not is_power_of_two(<uint32_t>slot_size):
        return Q_ERR

    placement_new[QueueImpl](ctx)

    q.running.store(1, memory_order_relaxed)
    q.flags.store(init_flags, memory_order_relaxed)
    q.capacity_mask = capacity - 1
    q.slot_size     = slot_size

    q.slots     = <QueueSlot*>aligned_alloc_(CACHELINE, capacity * sizeof(QueueSlot))
    q.slot_bufs = <char*>aligned_alloc_(CACHELINE, capacity * slot_size)
    if q.slots == NULL or q.slot_bufs == NULL:
        return Q_ERR

    memset(q.slot_bufs, 0, capacity * slot_size)
    for i in range(capacity):
        q.slots[i].buf          = q.slot_bufs + i * slot_size
        q.slots[i].size         = 0
        q.slots[i].seq_id       = 0
        q.slots[i].chunk_idx    = 0
        q.slots[i].total_chunks = 0

    q.consumer_ctx[0].value.scratch_buf = <char*>malloc(slot_size)
    if q.consumer_ctx[0].value.scratch_buf == NULL:
        return Q_ERR
    q.consumer_ctx[0].value.scratch_cap = slot_size

    if needs_publish:
        q.publish = <PublishEntry*>aligned_alloc_(CACHELINE, capacity * sizeof(PublishEntry))
        if q.publish == NULL:
            return Q_ERR
        memset(<void*>q.publish, 0, capacity * sizeof(PublishEntry))

        for i in range(capacity):
            q.publish[i].seq.store(i, memory_order_relaxed)

    return Q_OK


cdef int py_queue_init(void* ctx, size_t capacity, bint needs_publish, uint8_t init_flags) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        size_t i

    if not is_power_of_two(<uint32_t>capacity):
        return Q_ERR

    placement_new[PyQueueImpl](ctx)

    q.running.store(1, memory_order_relaxed)
    q.flags.store(init_flags, memory_order_relaxed)
    q.capacity_mask = capacity - 1

    q.slots = <PyQueueSlot*>aligned_alloc_(CACHELINE, capacity * sizeof(PyQueueSlot))
    if q.slots == NULL:
        return Q_ERR
    memset(<void*>q.slots, 0, capacity * sizeof(PyQueueSlot)) 

    if needs_publish:
        q.publish = <PublishEntry*>aligned_alloc_(CACHELINE, capacity * sizeof(PublishEntry))
        if q.publish == NULL:
            return Q_ERR
        memset(<void*>q.publish, 0, capacity * sizeof(PublishEntry))
        for i in range(capacity):
            q.publish[i].seq.store(i, memory_order_relaxed)

    return Q_OK

cdef int queue_close(void* ctx, long timeout_ms = 0) noexcept nogil:
    cdef:
        QueueImpl*  q        = <QueueImpl*>ctx
        timespec_   start, now
        int64_t      elapsed  = 0


    if not q.running.load(memory_order_acquire):
        return 0
        
    q.flags.fetch_or(F_CLOSING, memory_order_release)
    
    if timeout_ms != 0:
        if timeout_ms > 0:
            clock_gettime_(CLOCK_MONOTONIC_, &start)
        while _slowest_consumer_pos(q) < q.tail.load(memory_order_acquire):
            if timeout_ms > 0:
                clock_gettime_(CLOCK_MONOTONIC_, &now)
                elapsed = elapsed_ms(&start, &now)
                if elapsed >= <int64_t>timeout_ms:
                    break
            usleep_(200)

    q.running.store(0, memory_order_release)
    q.tail.fetch_add(1, memory_order_release)
    q.head.fetch_add(1, memory_order_release)

    atomic_notify_all(&q.tail, &q.tail_wm)
    atomic_notify_all(&q.head, &q.head_wm)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

    if q.mode == MPMC:
        atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)


cdef int py_queue_close(void* ctx, long timeout_ms = 0) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        timespec_   start, now
        int64_t     elapsed = 0

    if not q.running.load(memory_order_acquire):
        return 0

    q.flags.fetch_or(F_CLOSING, memory_order_release)

    if timeout_ms != 0:
        if timeout_ms > 0:
            clock_gettime_(CLOCK_MONOTONIC_, &start)
        while _slowest_consumer_pos_py(q) < q.tail.load(memory_order_acquire):
            if timeout_ms > 0:
                clock_gettime_(CLOCK_MONOTONIC_, &now)
                elapsed = elapsed_ms(&start, &now)
                if elapsed >= <int64_t>timeout_ms:
                    break
            usleep_(200)

    q.running.store(0, memory_order_release)
    q.tail.fetch_add(1, memory_order_release)
    q.head.fetch_add(1, memory_order_release)

    atomic_notify_all(&q.tail, &q.tail_wm)
    atomic_notify_all(&q.head, &q.head_wm)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

    if q.mode == MPMC:
        atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm) 


cdef void queue_destroy(void* ctx) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        int i

    for i in range(64):
        if q.consumer_ctx[i].value.assemble_buf != NULL:
            free(q.consumer_ctx[i].value.assemble_buf)
            q.consumer_ctx[i].value.assemble_buf = NULL
        if q.consumer_ctx[i].value.scratch_buf != NULL:
            free(q.consumer_ctx[i].value.scratch_buf)
            q.consumer_ctx[i].value.scratch_buf = NULL

    if q.slots     != NULL: 
        aligned_free_(q.slots)
    if q.slot_bufs != NULL: 
        aligned_free_(q.slot_bufs)
    if q.publish   != NULL: 
        aligned_free_(q.publish)

    placement_destroy[QueueImpl](ctx)


cdef void py_queue_destroy(void* ctx):
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        size_t i, capacity = q.capacity_mask + 1

    for i in range(capacity):
        if q.slots[i].obj != NULL:
            Py_XDECREF(q.slots[i].obj)
            q.slots[i].obj = NULL

    if q.slots   != NULL:
        aligned_free_(q.slots)
    if q.publish != NULL:
        aligned_free_(q.publish)

    placement_destroy[PyQueueImpl](ctx)

# =========================================================================
# ===============    SPMC - MPMC REGISTER PRODUCER CONSUMER    ============
# =========================================================================

cdef int register_producer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t mask, bit
        uint32_t i
        int ret= Q_OK

    while True:
        mask = q.producer_active_mask.value.load(memory_order_acquire)
        if mask == 0xFFFFFFFFFFFFFFFFULL:
            ret=  Q_ERR
            break
        i   = builtin_ctzll(~mask)
        bit = (<uint64_t>1) << i
        if _cas_u64(&q.producer_active_mask.value, &mask, mask | bit):
            out_id[0] = i
            _tls_set_pid(i)
            break
    return ret

cdef void unregister_producer(void* ctx, uint32_t pid) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t mask, bit = (<uint64_t>1) << pid

    while True:
        mask = q.producer_active_mask.value.load(memory_order_acquire)
        if _cas_u64(&q.producer_active_mask.value, &mask, mask & ~bit):
            _tls_set_pid(0xFFFFFFFFu)
            return

cdef int py_register_producer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t mask, bit
        uint32_t i
        int ret = Q_OK

    while True:
        mask = q.producer_active_mask.value.load(memory_order_acquire)
        if mask == 0xFFFFFFFFFFFFFFFFULL:
            ret= Q_ERR
            break
        i   = builtin_ctzll(~mask)
        bit = (<uint64_t>1) << i
        if _cas_u64(&q.producer_active_mask.value, &mask, mask | bit):
            out_id[0] = i
            _tls_set_pid(i)
            break
    return ret

cdef void py_unregister_producer(void* ctx, uint32_t pid) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t mask, bit = (<uint64_t>1) << pid

    while True:
        mask = q.producer_active_mask.value.load(memory_order_acquire)
        if _cas_u64(&q.producer_active_mask.value, &mask, mask & ~bit):
            _tls_set_pid(0xFFFFFFFFu)
            return




cdef int register_consumer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t mask, bit
        uint32_t i
        char* sbuf
        int ret = Q_OK

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if mask == 0xFFFFFFFFFFFFFFFFULL:
            ret= Q_ERR
            break
        i    = builtin_ctzll(~mask)
        bit  = (<uint64_t>1) << i
        if _cas_u64(&q.reader_active_mask.value, &mask, mask | bit):
            if q.consumer_ctx[i].value.scratch_buf == NULL:
                sbuf = <char*>malloc(q.slot_size)
                if sbuf == NULL:
                    mask = q.reader_active_mask.value.load(memory_order_acquire)
                    while True:
                        if _cas_u64(&q.reader_active_mask.value, &mask, mask & ~bit):
                            break
                        cpu_pause()
                    ret= Q_ERR
                    break
                q.consumer_ctx[i].value.scratch_buf = sbuf
                q.consumer_ctx[i].value.scratch_cap = q.slot_size

            q.reader_pos[i].value.store(
                q.tail.load(memory_order_acquire), memory_order_release
            )

            q.consumer_ctx[i].value.expected_seq = 0
            q.consumer_ctx[i].value.expected_chunk = 0
            q.consumer_ctx[i].value.assemble_buf = NULL
            q.consumer_ctx[i].value.assemble_used = 0
            q.consumer_ctx[i].value.assemble_cap = 0

            q.consumer_ctx[i].value.discard_count = 0
            q.consumer_ctx[i].value.resync_count = 0
            q.consumer_ctx[i].value.lag_flag_pos.store(0xFFFFFFFFFFFFFFFFULL, memory_order_relaxed)

            out_id[0] = i
            _tls_set_rid(i)
            consumer_update_min(q)
            atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
            atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
            break
    return ret


cdef int py_register_consumer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t mask, bit
        uint32_t i
        int ret = Q_OK

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if mask == 0xFFFFFFFFFFFFFFFFULL:
            ret= Q_ERR
            break
        i   = builtin_ctzll(~mask)
        bit = (<uint64_t>1) << i
        if _cas_u64(&q.reader_active_mask.value, &mask, mask | bit):
            q.reader_pos[i].value.store(
                q.tail.load(memory_order_acquire), memory_order_release
            )
            out_id[0] = i
            _tls_set_rid(i)
            consumer_update_min_py(q)
            atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
            atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
            break
    return ret



cdef void unregister_consumer(void* ctx, uint32_t reader_id) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t mask, bit

    bit = (<uint64_t>1) << reader_id

    if q.consumer_ctx[reader_id].value.assemble_buf != NULL:
        free(q.consumer_ctx[reader_id].value.assemble_buf)
        q.consumer_ctx[reader_id].value.assemble_buf = NULL
        q.consumer_ctx[reader_id].value.assemble_cap = 0
    
    if q.consumer_ctx[reader_id].value.scratch_buf != NULL:
        free(q.consumer_ctx[reader_id].value.scratch_buf)
        q.consumer_ctx[reader_id].value.scratch_buf = NULL
        q.consumer_ctx[reader_id].value.scratch_cap = 0

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if _cas_u64(&q.reader_active_mask.value, &mask, mask & ~bit):
            _tls_set_rid(0XFFFFFFFF)
            consumer_update_min(q)
            atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
            atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)            
            return

cdef void py_unregister_consumer(void* ctx, uint32_t reader_id) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t mask, bit = (<uint64_t>1) << reader_id

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if _cas_u64(&q.reader_active_mask.value, &mask, mask & ~bit):
            _tls_set_rid(0xFFFFFFFFu)
            consumer_update_min_py(q)
            atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
            atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
            return

cdef int mpsc_register_consumer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t mask, tail

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if mask & 1:
            return Q_ERR 
        if _cas_u64(&q.reader_active_mask.value, &mask, mask | 1):
            break
        cpu_pause()

    tail = q.tail.load(memory_order_acquire)
    q.head.store(tail, memory_order_release)

    out_id[0] = 0
    _tls_set_rid(0)
    atomic_notify_all(&q.head, &q.head_wm)
    atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
    return Q_OK


cdef int py_mpsc_register_consumer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t mask, tail

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if mask & 1:
            return Q_ERR 
        if _cas_u64(&q.reader_active_mask.value, &mask, mask | 1):
            break
        cpu_pause()

    tail = q.tail.load(memory_order_acquire)
    q.head.store(tail, memory_order_release)

    out_id[0] = 0
    _tls_set_rid(0)
    atomic_notify_all(&q.head, &q.head_wm)
    atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)
    return Q_OK


cdef void mpsc_unregister_consumer(void* ctx, uint32_t reader_id) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t mask

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if _cas_u64(&q.reader_active_mask.value, &mask, mask & ~<uint64_t>1):
            break
        cpu_pause()

    _tls_set_rid(0xFFFFFFFFu)
    atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)

cdef void py_mpsc_unregister_consumer(void* ctx, uint32_t reader_id) noexcept nogil:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t mask

    while True:
        mask = q.reader_active_mask.value.load(memory_order_acquire)
        if _cas_u64(&q.reader_active_mask.value, &mask, mask & ~<uint64_t>1):
            break
        cpu_pause()

    _tls_set_rid(0xFFFFFFFFu)
    atomic_notify_all(&q.reader_active_mask.value, &q.reader_active_mask_wm)

# =========================================================================
# ===============================   SPSC   ================================
# =========================================================================

# SPSC PUSH ===============================================================

cdef int spsc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_OVERWRITE:
                q.head.store(head + 1, memory_order_release)
                
                atomic_notify_one(&q.head, &q.head_wm)
                continue
            elif q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING

                atomic_notify_one(&q.tail, &q.tail_wm)
                atomic_wait(&q.head, head, &q.head_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        if q.flags.load(memory_order_acquire) & F_ZEROCOPY:
            slot.buf  = <char*>data
            slot.size = size
        else:
            if size > q.slot_size:
                size = q.slot_size
            memcpy(slot.buf, data, size)
            slot.size = size

        atomic_thread_fence(memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        
        atomic_notify_one(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING


cdef inline int spsc_py_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_OVERWRITE:
                idx  = head & q.capacity_mask
                slot = &q.slots[idx]
                if slot.obj != NULL:
                    Py_XDECREF(slot.obj) 
                    slot.obj = NULL
                q.head.store(head + 1, memory_order_release)
                
                atomic_notify_one(&q.head, &q.head_wm)
                continue
            elif q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING

                atomic_notify_one(&q.tail, &q.tail_wm)
                
                with nogil:
                    atomic_wait(&q.head, head, &q.head_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        Py_INCREF(data)
        slot.obj = <PyObject*>data   

        #atomic_thread_fence(memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        
        atomic_notify_one(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING


cdef int spsc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING

    head = q.head.load(memory_order_acquire)
    tail = q.tail.load(memory_order_relaxed)

    if tail - head >= q.capacity_mask + 1:
        if q.flags.load(memory_order_acquire) & F_OVERWRITE:
            q.head.store(head + 1, memory_order_release)
            
            atomic_notify_one(&q.head, &q.head_wm)
            head = head + 1
            if tail - head >= q.capacity_mask + 1:
                return Q_FULL
        else:
            return Q_FULL

    idx  = tail & q.capacity_mask
    slot = &q.slots[idx]

    if q.flags.load(memory_order_acquire) & F_ZEROCOPY:
        slot.buf  = <char*>data
        slot.size = size
    else:
        if size > q.slot_size:
            size = q.slot_size
        memcpy(slot.buf, data, size)
        slot.size = size

    atomic_thread_fence(memory_order_release)
    q.tail.store(tail + 1, memory_order_release)
    
    atomic_notify_one(&q.tail, &q.tail_wm)
    return Q_OK


cdef int spsc_py_try_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING

    head = q.head.load(memory_order_acquire)
    tail = q.tail.load(memory_order_relaxed)

    if tail - head >= q.capacity_mask + 1:
        if q.flags.load(memory_order_acquire) & F_OVERWRITE:
            idx  = head & q.capacity_mask
            slot = &q.slots[idx]
            if slot.obj != NULL:
                Py_XDECREF(slot.obj)
                slot.obj = NULL
            q.head.store(head + 1, memory_order_release)
            
            atomic_notify_one(&q.head, &q.head_wm)
            head = head + 1
            if tail - head >= q.capacity_mask + 1:
                return Q_FULL
        else:
            return Q_FULL

    idx  = tail & q.capacity_mask
    slot = &q.slots[idx]

    Py_INCREF(data)
    slot.obj = <PyObject*>data

    atomic_thread_fence(memory_order_release)
    q.tail.store(tail + 1, memory_order_release)
    
    atomic_notify_one(&q.tail, &q.tail_wm)
    return Q_OK


cdef int spsc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot
        QueueSlot* victim
        size_t offset, chunk_bytes
        uint16_t total_chunks, chunk_idx, chunks_left
        uint32_t seq_id

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    
    seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
    offset       = 0

    for chunk_idx in range(total_chunks):
        while q.running.load(memory_order_acquire):
            head = q.head.load(memory_order_acquire)
            tail = q.tail.load(memory_order_relaxed)

            if tail - head >= q.capacity_mask + 1:
                if q.flags.load(memory_order_acquire) & F_OVERWRITE:
                    victim      = &q.slots[head & q.capacity_mask]
                    chunks_left = victim.total_chunks - victim.chunk_idx
                    if chunks_left == 0:
                        chunks_left = 1
                    q.head.store(head + chunks_left, memory_order_release)
                    
                    atomic_notify_one(&q.head, &q.head_wm)
                    continue
                elif q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                    if not q.running.load(memory_order_acquire):
                        return Q_CLOSING
                        
                    atomic_notify_one(&q.tail, &q.tail_wm)
                    atomic_wait(&q.head, head, &q.head_wm)
                    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                        return Q_CLOSING
                    continue
                else:
                    return Q_FULL

            idx  = tail & q.capacity_mask
            slot = &q.slots[idx]

            chunk_bytes = size - offset
            if chunk_bytes > q.slot_size:
                chunk_bytes = q.slot_size

            memcpy(slot.buf, data + offset, chunk_bytes)
            slot.size         = chunk_bytes
            slot.seq_id       = seq_id
            slot.chunk_idx    = chunk_idx
            slot.total_chunks = total_chunks
            offset           += chunk_bytes

            atomic_thread_fence(memory_order_release)
            q.tail.store(tail + 1, memory_order_release)
            
            atomic_notify_one(&q.tail, &q.tail_wm)
            break

        if not q.running.load(memory_order_acquire):
            return Q_CLOSING

    return Q_OK


cdef int spsc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot
        QueueSlot* victim
        size_t offset, chunk_bytes
        uint16_t total_chunks, chunk_idx, chunks_left
        uint32_t seq_id

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    
    seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
    offset       = 0

    for chunk_idx in range(total_chunks):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_OVERWRITE:
                victim      = &q.slots[head & q.capacity_mask]
                chunks_left = victim.total_chunks - victim.chunk_idx
                if chunks_left == 0:
                    chunks_left = 1
                q.head.store(head + chunks_left, memory_order_release)
                
                atomic_notify_one(&q.head, &q.head_wm)
                head = q.head.load(memory_order_acquire)
                tail = q.tail.load(memory_order_relaxed)
                if tail - head >= q.capacity_mask + 1:
                    return Q_FULL
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        chunk_bytes = size - offset
        if chunk_bytes > q.slot_size:
            chunk_bytes = q.slot_size

        memcpy(slot.buf, data + offset, chunk_bytes)
        slot.size         = chunk_bytes
        slot.seq_id       = seq_id
        slot.chunk_idx    = chunk_idx
        slot.total_chunks = total_chunks
        offset           += chunk_bytes

        atomic_thread_fence(memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        
        atomic_notify_one(&q.tail, &q.tail_wm)

    return Q_OK


# SPSC POP  ===============================================================


cdef int spsc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)

        _stage_slot(st, slot.buf, slot.size)

        out_buf[0]  = st.scratch_buf
        out_size[0] = slot.size

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)
        return Q_OK

    return Q_CLOSING


cdef inline int spsc_py_pop(void* ctx, PyObject** out) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            with nogil:
                atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        #atomic_thread_fence(memory_order_acquire)

        out[0]   = slot.obj
        slot.obj = NULL

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)
        return Q_OK

    return Q_CLOSING


cdef int spsc_pop_py_dispatch(void* ctx, char** out_buf, size_t* out_size):
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            with nogil:
                atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)

        _stage_slot(st, slot.buf, slot.size)

        out_buf[0]  = st.scratch_buf
        out_size[0] = slot.size

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)
        return Q_OK

    return Q_CLOSING


cdef int spsc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx  = head & q.capacity_mask
    slot = &q.slots[idx]

    out_buf[0]  = slot.buf
    out_size[0] = slot.size

    atomic_thread_fence(memory_order_acquire)

    _stage_slot(st, slot.buf, slot.size)

    out_buf[0]  = st.scratch_buf
    out_size[0] = slot.size

    q.head.store(head + 1, memory_order_release)
    
    atomic_notify_one(&q.head, &q.head_wm)
    return Q_OK


cdef int spsc_py_try_pop(void* ctx, PyObject** out) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx  = head & q.capacity_mask
    slot = &q.slots[idx]

    atomic_thread_fence(memory_order_acquire)

    out[0]   = slot.obj
    slot.obj = NULL

    q.head.store(head + 1, memory_order_release)
    
    atomic_notify_one(&q.head, &q.head_wm)
    return Q_OK


cdef int spsc_try_pop_py_dispatch(void* ctx, char** out_buf, size_t* out_size):
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx  = head & q.capacity_mask
    slot = &q.slots[idx]

    out_buf[0]  = slot.buf
    out_size[0] = slot.size

    atomic_thread_fence(memory_order_acquire)

    _stage_slot(st, slot.buf, slot.size)

    out_buf[0]  = st.scratch_buf
    out_size[0] = slot.size

    q.head.store(head + 1, memory_order_release)
    
    atomic_notify_one(&q.head, &q.head_wm)
    return Q_OK


cdef int spsc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
                
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)
        out_buf[0]  = slot.buf
        out_size[0] = slot.size
        return Q_OK

    return Q_CLOSING


cdef void spsc_pop_commit(void* ctx) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head = q.head.load(memory_order_relaxed)
    
    q.head.store(head + 1, memory_order_release)
    
    atomic_notify_one(&q.head, &q.head_wm)


cdef int spsc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp
        uint16_t total_chunks

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0
            else:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_one(&q.head, &q.head_wm)
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_CLOSING


cdef int spsc_pop_var_py_dispatch(void* ctx, char** out_buf, size_t* out_size):
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp
        uint16_t total_chunks

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            with nogil:
                atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0
            else:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_one(&q.head, &q.head_wm)
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_CLOSING


cdef int spsc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp
        uint16_t total_chunks

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    #while True:
    #    if not q.running.load(memory_order_acquire):
    #        return Q_CLOSING
    while q.running.load(memory_order_acquire):

        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            return Q_EMPTY

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0
            else:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_one(&q.head, &q.head_wm)
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK
    return Q_CLOSING


cdef int spsc_try_pop_var_py_dispatch(void* ctx, char** out_buf, size_t* out_size):
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp
        uint16_t total_chunks

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    #while True:
    #    if not q.running.load(memory_order_acquire):
    #        return Q_CLOSING
    while q.running.load(memory_order_acquire):

        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            return Q_EMPTY

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0
            else:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_one(&q.head, &q.head_wm)
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head, &q.head_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK
    return Q_CLOSING


# =========================================================================
# ===============================   MPSC   ================================
# =========================================================================

# MPSC PUSH ===============================================================

cdef int mpsc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING

    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                atomic_wait(&q.head, head, &q.head_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + 1):
            cpu_pause()
            continue

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        if size > q.slot_size:
            size = q.slot_size
        memcpy(slot.buf, data, size)
        slot.size         = size
        slot.chunk_idx    = 0
        slot.total_chunks = 1

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        #atomic_notify_all(&q.publish[idx].seq, &q.publish[idx].seq_wm)
        atomic_notify_all(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING

cdef int mpsc_py_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING

    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING                
                with nogil:
                    atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                with nogil:
                    atomic_wait(&q.head, head, &q.head_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + 1):
            cpu_pause()
            continue

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        Py_INCREF(data)
        slot.obj = <PyObject*>data

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING

cdef int mpsc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING

    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    tail = q.tail.load(memory_order_relaxed)

    while True:
        head = q.head.load(memory_order_acquire)
        if tail - head >= q.capacity_mask + 1:
            return Q_FULL
        if _cas_u64(&q.tail, &tail, tail + 1):
            break
        cpu_pause()

    idx  = tail & q.capacity_mask
    slot = &q.slots[idx]

    if size > q.slot_size:
        size = q.slot_size
    memcpy(slot.buf, data, size)
    slot.size         = size
    slot.chunk_idx    = 0
    slot.total_chunks = 1

    atomic_thread_fence(memory_order_release)
    q.publish[idx].seq.store(tail + 1, memory_order_release)
    #atomic_notify_all(&q.publish[idx].seq, &q.publish[idx].seq_wm)
    atomic_notify_all(&q.tail, &q.tail_wm)
    return Q_OK

cdef int mpsc_py_try_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    tail = q.tail.load(memory_order_relaxed)

    while True:
        head = q.head.load(memory_order_acquire)
        if tail - head >= q.capacity_mask + 1:
            return Q_FULL
        if _cas_u64(&q.tail, &tail, tail + 1):
            break
        cpu_pause()

    idx  = tail & q.capacity_mask
    slot = &q.slots[idx]

    Py_INCREF(data)
    slot.obj = <PyObject*>data

    atomic_thread_fence(memory_order_release)
    q.publish[idx].seq.store(tail + 1, memory_order_release)
    atomic_notify_all(&q.tail, &q.tail_wm)
    return Q_OK


cdef int mpsc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx, cap
        QueueSlot* slot
        size_t offset, chunk_bytes
        uint16_t total_chunks, chunk_idx
        uint32_t seq_id

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    cap          = q.capacity_mask + 1
    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if (tail + total_chunks) - head > cap:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                atomic_wait(&q.head, head, &q.head_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + total_chunks):
            cpu_pause()
            continue

        seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
        offset = 0

        for chunk_idx in range(total_chunks):
            idx  = (tail + chunk_idx) & q.capacity_mask
            slot = &q.slots[idx]

            chunk_bytes = size - offset
            if chunk_bytes > q.slot_size:
                chunk_bytes = q.slot_size

            memcpy(slot.buf, data + offset, chunk_bytes)
            slot.size         = chunk_bytes
            slot.seq_id       = seq_id
            slot.chunk_idx    = chunk_idx
            slot.total_chunks = total_chunks
            offset           += chunk_bytes

            atomic_thread_fence(memory_order_release)
            q.publish[idx].seq.store(tail + chunk_idx + 1, memory_order_release)
            
            #atomic_notify_all(&q.publish[idx].seq, &q.publish[idx].seq_wm)
            atomic_notify_all(&q.tail, &q.tail_wm)

        return Q_OK

    return Q_CLOSING


cdef int mpsc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx, cap
        QueueSlot* slot
        size_t offset, chunk_bytes
        uint16_t total_chunks, chunk_idx
        uint32_t seq_id

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    cap          = q.capacity_mask + 1
    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    tail         = q.tail.load(memory_order_relaxed)

    while True:
        head = q.head.load(memory_order_acquire)
        if (tail + total_chunks) - head > cap:
            return Q_FULL
        if _cas_u64(&q.tail, &tail, tail + total_chunks):
            break
        cpu_pause()

    seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
    offset = 0

    for chunk_idx in range(total_chunks):
        idx  = (tail + chunk_idx) & q.capacity_mask
        slot = &q.slots[idx]

        chunk_bytes = size - offset
        if chunk_bytes > q.slot_size:
            chunk_bytes = q.slot_size

        memcpy(slot.buf, data + offset, chunk_bytes)
        slot.size         = chunk_bytes
        slot.seq_id       = seq_id
        slot.chunk_idx    = chunk_idx
        slot.total_chunks = total_chunks
        offset           += chunk_bytes

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + chunk_idx + 1, memory_order_release)
        #atomic_notify_all(&q.publish[idx].seq, &q.publish[idx].seq_wm)
        atomic_notify_all(&q.tail, &q.tail_wm)

    return Q_OK


# MPSC POP  ===============================================================


cdef int mpsc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx, spins
        QueueSlot* slot
        timespec_       slot_start
        cbool           timer_started

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = head & q.capacity_mask
        spins = 0 
        timer_started = False

        while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(q, &slot_start, &timer_started):
                q.head.store(head + 1, memory_order_release)
                atomic_notify_all(&q.head, &q.head_wm)
                return Q_ORPHANED
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        _stage_slot(st, slot.buf, slot.size)

        out_buf[0]  = st.scratch_buf
        out_size[0] = slot.size

        q.head.store(head + 1, memory_order_release)
        atomic_notify_all(&q.head, &q.head_wm)
        return Q_OK

    return Q_CLOSING

cdef int mpsc_py_pop(void* ctx, PyObject** out) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx, spins
        PyQueueSlot* slot
        timespec_       slot_start
        cbool           timer_started

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            with nogil:
                atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = head & q.capacity_mask
        spins = 0
        timer_started = False

        with nogil:
            while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                spins += 1
                if spins & 0x3FF == 0 and _claimed_slot_orphaned_py(q, &slot_start, &timer_started):
                    q.head.store(head + 1, memory_order_release)
                    atomic_notify_all(&q.head, &q.head_wm)
                    return Q_ORPHANED
                cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out[0]   = slot.obj
        slot.obj = NULL

        q.head.store(head + 1, memory_order_release)
        atomic_notify_all(&q.head, &q.head_wm)
        return Q_OK

    return Q_CLOSING


cdef int mpsc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx = head & q.capacity_mask

    if q.publish[idx].seq.load(memory_order_acquire) != head + 1:
        return Q_EMPTY

    slot = &q.slots[idx]
    atomic_thread_fence(memory_order_acquire)

    _stage_slot(st, slot.buf, slot.size)

    out_buf[0]  = st.scratch_buf
    out_size[0] = slot.size

    q.head.store(head + 1, memory_order_release)
    atomic_notify_all(&q.head, &q.head_wm)
    return Q_OK

cdef int mpsc_py_try_pop(void* ctx, PyObject** out) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t head, tail, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx = head & q.capacity_mask

    if q.publish[idx].seq.load(memory_order_acquire) != head + 1:
        return Q_EMPTY

    slot = &q.slots[idx]
    atomic_thread_fence(memory_order_acquire)

    out[0]   = slot.obj
    slot.obj = NULL

    q.head.store(head + 1, memory_order_release)
    atomic_notify_all(&q.head, &q.head_wm)
    return Q_OK

cdef int mpsc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx, spins
        uint64_t seq_snap
        QueueSlot* slot
        timespec_       slot_start
        cbool           timer_started        

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = head & q.capacity_mask
        spins = 0
        timer_started = False

        while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(q, &slot_start, &timer_started):
                q.head.store(head + 1, memory_order_release)
                atomic_notify_all(&q.head, &q.head_wm)
                return Q_ORPHANED
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out_buf[0]  = slot.buf
        out_size[0] = slot.size
        _tls_set_borrow(head, idx)
        return Q_OK

    return Q_CLOSING


cdef void mpsc_pop_commit(void* ctx) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t bpos = _tls_get_borrow_pos()
        uint64_t bidx = _tls_get_borrow_idx()

    while q.publish[bidx].seq.load(memory_order_acquire) != bpos + 1:
        if not q.running.load(memory_order_acquire):
            return
        cpu_pause()
        
    q.head.store(bpos + 1, memory_order_release)
    atomic_notify_all(&q.head, &q.head_wm)


cdef int mpsc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx, spins
        QueueSlot* slot
        size_t needed
        char* tmp
        uint16_t total_chunks
        timespec_       slot_start
        cbool           timer_started

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = head & q.capacity_mask
        spins = 0
        timer_started = False

        while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(q, &slot_start, &timer_started):
                st.expected_chunk = 0
                st.assemble_used  = 0
                q.head.store(head + 1, memory_order_release)
                atomic_notify_all(&q.head, &q.head_wm)
                return Q_ORPHANED
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0

                st.resync_count  += 1
            else:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_all(&q.head, &q.head_wm)
                st.discard_count += 1
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.head.store(head + 1, memory_order_release)
        atomic_notify_all(&q.head, &q.head_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_CLOSING


cdef int mpsc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0].value
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp
        uint16_t total_chunks

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    #while True:
    #    if not q.running.load(memory_order_acquire):
    #        return Q_CLOSING
    while q.running.load(memory_order_acquire):

        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            return Q_EMPTY

        idx = head & q.capacity_mask

        if q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            return Q_EMPTY

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0

                st.resync_count  += 1
            else:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_all(&q.head, &q.head_wm)
                st.discard_count += 1
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.head.store(head + 1, memory_order_release)
        atomic_notify_all(&q.head, &q.head_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK
    return Q_CLOSING


# =========================================================================
# ====================   MULTI CONSUUMER POP IMPL    ======================
# =========================================================================

cdef inline int _mc_pop_impl(
    QueueImpl* q,
    char**     out_buf,
    size_t*    out_size,
    uint32_t   rid,
) noexcept nogil:
    cdef:
        ConsumerCtx* st = &q.consumer_ctx[rid].value
        uint64_t   pos, tail, idx, spins
        QueueSlot* slot
        timespec_  slot_start
        cbool      timer_started

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].value.load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = pos & q.capacity_mask
        spins = 0
        timer_started = False

        while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(q, &slot_start, &timer_started):
                q.reader_pos[rid].value.store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
                return Q_ORPHANED
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        _stage_slot(st, slot.buf, slot.size)

        out_buf[0]  = st.scratch_buf
        out_size[0] = slot.size

        q.reader_pos[rid].value.store(pos + 1, memory_order_release)
        consumer_update_min(q)
        atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

        return Q_OK

    return Q_CLOSING

cdef inline int _mc_pop_impl_py(
    PyQueueImpl* q,
    PyObject**   out,
    uint32_t   rid,
) except -1:
    cdef:
        uint64_t   pos, tail, idx, spins
        PyQueueSlot* slot
        timespec_  slot_start
        cbool      timer_started

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].value.load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            with nogil:
                atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = pos & q.capacity_mask
        spins = 0
        timer_started = False

        with nogil:
            while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                spins += 1
                if spins & 0x3FF == 0 and _claimed_slot_orphaned_py(q, &slot_start, &timer_started):
                    q.reader_pos[rid].value.store(pos + 1, memory_order_release)
                    consumer_update_min_py(q)
                    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
                    return Q_ORPHANED
                cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        Py_INCREF(<object>slot.obj) 
        out[0] = slot.obj

        q.reader_pos[rid].value.store(pos + 1, memory_order_release)
        consumer_update_min_py(q)
        atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

        return Q_OK

    return Q_CLOSING

cdef inline int _mc_try_pop_impl(
    QueueImpl* q,
    char**     out_buf,
    size_t*    out_size,
    uint32_t   rid,
) noexcept nogil:
    cdef:
        ConsumerCtx* st = &q.consumer_ctx[rid].value
        uint64_t   pos, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    pos  = q.reader_pos[rid].value.load(memory_order_acquire)
    tail = q.tail.load(memory_order_acquire)

    if pos == tail:
        return Q_EMPTY

    idx = pos & q.capacity_mask

    if q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
        return Q_EMPTY

    slot = &q.slots[idx]
    atomic_thread_fence(memory_order_acquire)

    _stage_slot(st, slot.buf, slot.size)

    out_buf[0]  = st.scratch_buf
    out_size[0] = slot.size

    q.reader_pos[rid].value.store(pos + 1, memory_order_release)
    consumer_update_min(q)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

    return Q_OK


cdef inline int _mc_try_pop_impl_py(
    PyQueueImpl* q,
    PyObject**   out,
    uint32_t   rid,
) except -1:
    cdef:
        uint64_t   pos, tail, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    pos  = q.reader_pos[rid].value.load(memory_order_acquire)
    tail = q.tail.load(memory_order_acquire)

    if pos == tail:
        return Q_EMPTY

    idx = pos & q.capacity_mask

    if q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
        return Q_EMPTY

    slot = &q.slots[idx]
    atomic_thread_fence(memory_order_acquire)

    Py_INCREF(<object>slot.obj)
    out[0] = slot.obj

    q.reader_pos[rid].value.store(pos + 1, memory_order_release)
    consumer_update_min_py(q)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

    return Q_OK

# =========================================================================
# ===============================   SPMC   ================================
# =========================================================================

# SPMC PUSH ===============================================================

cdef int spmc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                atomic_wait(&q.reader_min_pos, min_pos, &q.reader_min_pos_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask

        slot = &q.slots[idx]

        if q.flags.load(memory_order_acquire) & F_ZEROCOPY:
            slot.buf  = <char*>data
            slot.size = size
        else:
            if size > q.slot_size:
                size = q.slot_size
            memcpy(slot.buf, data, size)
            slot.size = size

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING

cdef int spmc_py_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        PyQueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                with nogil:
                    atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                with nogil:
                    atomic_wait(&q.reader_min_pos, min_pos, &q.reader_min_pos_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask

        slot = &q.slots[idx]

        if slot.obj != NULL:
            Py_XDECREF(slot.obj)
        Py_INCREF(data)
        slot.obj = <PyObject*>data

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING

cdef int spmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    tail    = q.tail.load(memory_order_relaxed)
    min_pos = q.reader_min_pos.load(memory_order_acquire)

    if tail - min_pos >= q.capacity_mask + 1:
        return Q_FULL

    idx  = tail & q.capacity_mask

    slot = &q.slots[idx]

    if q.flags.load(memory_order_acquire) & F_ZEROCOPY:
        slot.buf  = <char*>data
        slot.size = size
    else:
        if size > q.slot_size:
            size = q.slot_size
        memcpy(slot.buf, data, size)
        slot.size = size

    atomic_thread_fence(memory_order_release)
    q.publish[idx].seq.store(tail + 1, memory_order_release)
    q.tail.store(tail + 1, memory_order_release)
    atomic_notify_all(&q.tail, &q.tail_wm)
    return Q_OK

cdef int spmc_py_try_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    tail    = q.tail.load(memory_order_relaxed)
    min_pos = q.reader_min_pos.load(memory_order_acquire)

    if tail - min_pos >= q.capacity_mask + 1:
        return Q_FULL

    idx  = tail & q.capacity_mask

    slot = &q.slots[idx]

    if slot.obj != NULL:
        Py_XDECREF(slot.obj)
    Py_INCREF(data)
    slot.obj = <PyObject*>data

    atomic_thread_fence(memory_order_release)
    q.publish[idx].seq.store(tail + 1, memory_order_release)
    q.tail.store(tail + 1, memory_order_release)
    atomic_notify_all(&q.tail, &q.tail_wm)
    return Q_OK


cdef int spmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    
    seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
    offset       = 0

    for chunk_idx in range(total_chunks):
        while q.running.load(memory_order_acquire):
            if q.reader_active_mask.value.load(memory_order_acquire) == 0:
                if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                    if not q.running.load(memory_order_acquire):
                        return Q_CLOSING
                    atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                        return Q_CLOSING
                    continue
                else:
                    return Q_NO_CONSUMER

            tail    = q.tail.load(memory_order_relaxed)
            min_pos = q.reader_min_pos.load(memory_order_acquire)

            if tail - min_pos >= q.capacity_mask + 1:
                if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                    if not q.running.load(memory_order_acquire):
                        return Q_CLOSING
                        
                    atomic_wait(&q.reader_min_pos, min_pos, &q.reader_min_pos_wm)
                    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                        return Q_CLOSING
                    continue
                else:
                    return Q_FULL

            idx  = tail & q.capacity_mask

            slot = &q.slots[idx]

            chunk_bytes = size - offset
            if chunk_bytes > q.slot_size:
                chunk_bytes = q.slot_size

            memcpy(slot.buf, data + offset, chunk_bytes)
            slot.size         = chunk_bytes
            slot.seq_id       = seq_id
            slot.chunk_idx    = chunk_idx
            slot.total_chunks = total_chunks
            offset           += chunk_bytes

            atomic_thread_fence(memory_order_release)
            q.publish[idx].seq.store(tail + 1, memory_order_release)
            q.tail.store(tail + 1, memory_order_release)
            atomic_notify_all(&q.tail, &q.tail_wm)
            break

        if not q.running.load(memory_order_acquire):
            return Q_CLOSING

    return Q_OK


cdef int spmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
    offset       = 0

    for chunk_idx in range(total_chunks):
        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            return Q_FULL

        idx  = tail & q.capacity_mask

        slot = &q.slots[idx]

        chunk_bytes = size - offset
        if chunk_bytes > q.slot_size:
            chunk_bytes = q.slot_size

        memcpy(slot.buf, data + offset, chunk_bytes)
        slot.size         = chunk_bytes
        slot.seq_id       = seq_id
        slot.chunk_idx    = chunk_idx
        slot.total_chunks = total_chunks
        offset           += chunk_bytes

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)

    return Q_OK

# SPMC POP  ===============================================================

cdef int spmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_pop_impl(q, out_buf, out_size, _tls_get_rid())

cdef int spmc_py_pop(void* ctx, PyObject** out) except -1:
    cdef PyQueueImpl* q = <PyQueueImpl*>ctx
    return _mc_pop_impl_py(q, out, _tls_get_rid())


cdef int spmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_try_pop_impl(q, out_buf, out_size, _tls_get_rid())

cdef int spmc_py_try_pop(void* ctx, PyObject** out) except -1:
    cdef PyQueueImpl* q = <PyQueueImpl*>ctx
    return _mc_try_pop_impl_py(q, out, _tls_get_rid())

cdef int spmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        uint64_t   pos, tail, idx, spins
        QueueSlot* slot
        timespec_  slot_start
        cbool      timer_started

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].value.load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = pos & q.capacity_mask
        spins  = 0
        timer_started = False

        while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(q, &slot_start, &timer_started):
                q.reader_pos[rid].value.store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
                return Q_ORPHANED
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out_buf[0]  = slot.buf
        out_size[0] = slot.size
        _tls_set_borrow(pos, idx)
        return Q_OK

    return Q_CLOSING

cdef void spmc_pop_commit(void* ctx) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        uint64_t   pos = _tls_get_borrow_pos()

    q.reader_pos[rid].value.store(pos + 1, memory_order_release)
    consumer_update_min(q)
    atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)


cdef int spmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        ConsumerCtx* st = &q.consumer_ctx[rid].value
        uint64_t   pos, tail, idx, spins
        QueueSlot* slot
        size_t     needed
        char*      tmp
        uint16_t   total_chunks
        timespec_  slot_start
        cbool      timer_started

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].value.load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            atomic_wait(&q.tail, tail, &q.tail_wm)
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            continue

        idx = pos & q.capacity_mask
        spins = 0
        timer_started = False

        while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            if not q.running.load(memory_order_acquire):
                return Q_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(q, &slot_start, &timer_started):
                st.expected_chunk = 0
                st.assemble_used  = 0
                q.reader_pos[rid].value.store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)
                return Q_ORPHANED
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0

                st.resync_count  += 1
            else:
                q.reader_pos[rid].value.store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

                st.discard_count += 1
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks = slot.total_chunks

        q.reader_pos[rid].value.store(pos + 1, memory_order_release)
        consumer_update_min(q)
        atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_CLOSING


cdef int spmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        ConsumerCtx* st = &q.consumer_ctx[rid].value
        uint64_t   pos, tail, idx
        QueueSlot* slot
        size_t     needed
        char*      tmp
        uint16_t   total_chunks

    if not q.running.load(memory_order_acquire):
        return Q_CLOSING

    #while True:
    #    if not q.running.load(memory_order_acquire):
    #        return Q_CLOSING
    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].value.load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            return Q_EMPTY

        idx = pos & q.capacity_mask

        if q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            return Q_EMPTY

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0

                st.resync_count  += 1                
            else:
                q.reader_pos[rid].value.store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

                st.discard_count += 1                
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_CLOSING
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        total_chunks  = slot.total_chunks
        
        q.reader_pos[rid].value.store(pos + 1, memory_order_release)
        consumer_update_min(q)
        atomic_notify_all(&q.reader_min_pos, &q.reader_min_pos_wm)

        st.expected_chunk += 1

        if st.expected_chunk == total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK
    return Q_CLOSING


# =========================================================================
# ===============================   MPMC   ================================
# =========================================================================

# MPMC PUSH ===============================================================

cdef int mpmc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                atomic_wait(&q.reader_min_pos, min_pos, &q.reader_min_pos_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + 1):
            cpu_pause()
            continue

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        if size > q.slot_size:
            size = q.slot_size
        memcpy(slot.buf, data, size)
        slot.size         = size
        slot.chunk_idx    = 0
        slot.total_chunks = 1

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING

cdef int mpmc_py_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        PyQueueSlot* slot

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                with nogil:
                    atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                    
                with nogil:
                    atomic_wait(&q.reader_min_pos, min_pos, &q.reader_min_pos_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + 1):
            cpu_pause()
            continue

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        if slot.obj != NULL:
            Py_XDECREF(slot.obj)
        Py_INCREF(data)
        slot.obj = <PyObject*>data

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)
        return Q_OK

    return Q_CLOSING


cdef int mpmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    tail    = q.tail.load(memory_order_relaxed)
    min_pos = q.reader_min_pos.load(memory_order_acquire)

    while True:
        if tail - min_pos >= q.capacity_mask + 1:
            return Q_FULL
        idx = tail & q.capacity_mask
        
        if _cas_u64(&q.tail, &tail, tail + 1):
            break
        cpu_pause()
        min_pos = q.reader_min_pos.load(memory_order_acquire)

    slot = &q.slots[idx]

    if size > q.slot_size:
        size = q.slot_size
    memcpy(slot.buf, data, size)
    slot.size         = size
    slot.chunk_idx    = 0
    slot.total_chunks = 1

    atomic_thread_fence(memory_order_release)
    q.publish[idx].seq.store(tail + 1, memory_order_release)
    atomic_notify_all(&q.tail, &q.tail_wm)
    return Q_OK

cdef int mpmc_py_try_push(void* ctx, object data) except -1:
    cdef:
        PyQueueImpl* q = <PyQueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        PyQueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER

    tail    = q.tail.load(memory_order_relaxed)
    min_pos = q.reader_min_pos.load(memory_order_acquire)

    while True:
        if tail - min_pos >= q.capacity_mask + 1:
            return Q_FULL
        idx = tail & q.capacity_mask
        
        if _cas_u64(&q.tail, &tail, tail + 1):
            break
        cpu_pause()
        min_pos = q.reader_min_pos.load(memory_order_acquire)

    slot = &q.slots[idx]

    if slot.obj != NULL:
        Py_XDECREF(slot.obj)
    Py_INCREF(data)
    slot.obj = <PyObject*>data

    atomic_thread_fence(memory_order_release)
    q.publish[idx].seq.store(tail + 1, memory_order_release)
    atomic_notify_all(&q.tail, &q.tail_wm)
    return Q_OK

cdef int mpmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx, cap
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if q.flags.load(memory_order_acquire) & F_CLOSING:
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING

    cap          = q.capacity_mask + 1
    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.value.load(memory_order_acquire) == 0:
            if q.flags.load(memory_order_acquire) & F_WAIT_CONSUMERS:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                atomic_wait(&q.reader_active_mask.value, <uint64_t>0, &q.reader_active_mask_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if (tail + total_chunks) - min_pos > cap:
            if q.flags.load(memory_order_acquire) & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_CLOSING
                atomic_wait(&q.reader_min_pos, min_pos, &q.reader_min_pos_wm)
                if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
                    return Q_CLOSING
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + total_chunks):
            cpu_pause()
            continue

        for chunk_idx in range(total_chunks):
            idx = (tail + chunk_idx) & q.capacity_mask

        seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
        offset = 0

        for chunk_idx in range(total_chunks):
            idx  = (tail + chunk_idx) & q.capacity_mask
            slot = &q.slots[idx]

            chunk_bytes = size - offset
            if chunk_bytes > q.slot_size:
                chunk_bytes = q.slot_size

            memcpy(slot.buf, data + offset, chunk_bytes)
            slot.size         = chunk_bytes
            slot.seq_id       = seq_id
            slot.chunk_idx    = chunk_idx
            slot.total_chunks = total_chunks
            offset           += chunk_bytes

            atomic_thread_fence(memory_order_release)
            q.publish[idx].seq.store(tail + chunk_idx + 1, memory_order_release)
            atomic_notify_all(&q.tail, &q.tail_wm)

        return Q_OK

    return Q_CLOSING


cdef int mpmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx, cap
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if not q.running.load(memory_order_acquire) or (q.flags.load(memory_order_acquire) & F_CLOSING):
        return Q_CLOSING
    
    if _tls_get_pid() == 0xFFFFFFFFu:
        return Q_CLOSING
    
    if q.reader_active_mask.value.load(memory_order_acquire) == 0:
        return Q_NO_CONSUMER


    cap          = q.capacity_mask + 1
    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    tail         = q.tail.load(memory_order_relaxed)

    while True:
        min_pos = q.reader_min_pos.load(memory_order_acquire)
        if (tail + total_chunks) - min_pos > cap:
            return Q_FULL
        for chunk_idx in range(total_chunks):
            idx = (tail + chunk_idx) & q.capacity_mask
            
        if _cas_u64(&q.tail, &tail, tail + total_chunks):
            break
        cpu_pause()

    seq_id = q.seq_counter.fetch_add(1, memory_order_relaxed)
    offset = 0

    for chunk_idx in range(total_chunks):
        idx  = (tail + chunk_idx) & q.capacity_mask
        slot = &q.slots[idx]

        chunk_bytes = size - offset
        if chunk_bytes > q.slot_size:
            chunk_bytes = q.slot_size

        memcpy(slot.buf, data + offset, chunk_bytes)
        slot.size         = chunk_bytes
        slot.seq_id       = seq_id
        slot.chunk_idx    = chunk_idx
        slot.total_chunks = total_chunks
        offset           += chunk_bytes

        atomic_thread_fence(memory_order_release)
        q.publish[idx].seq.store(tail + chunk_idx + 1, memory_order_release)
        atomic_notify_all(&q.tail, &q.tail_wm)

    return Q_OK

# MPMC POP ===============================================================

cdef int mpmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_pop_impl(q, out_buf, out_size, _tls_get_rid())

cdef int mpmc_py_pop(void* ctx, PyObject** out) except -1:
    cdef PyQueueImpl* q = <PyQueueImpl*>ctx
    return _mc_pop_impl_py(q, out, _tls_get_rid())

cdef int mpmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_try_pop_impl(q, out_buf, out_size, _tls_get_rid())

cdef int mpmc_py_try_pop(void* ctx, PyObject** out) except -1:
    cdef PyQueueImpl* q = <PyQueueImpl*>ctx
    return _mc_try_pop_impl_py(q, out, _tls_get_rid())


cdef int mpmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return spmc_pop_borrow(ctx, out_buf, out_size)

cdef void mpmc_pop_commit(void* ctx) noexcept nogil:
    spmc_pop_commit(ctx)

cdef int mpmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return spmc_pop_var(ctx, out_buf, out_size)

cdef int mpmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return spmc_try_pop_var(ctx, out_buf, out_size)


# =========================================================================
# ==========================   QUEUE CLASS  ===============================
# =========================================================================

"""
Discarded because it cannot be declared in pxd properly.
Cython probably uses a default constructor in pxd definition overriding the given one.

cdef cppclass BroadcastQueue:
    QueueImpl _q
    cbool _signal_registered
    uint8_t _init_flags

    BroadcastQueue(
            size_t    slot_size,
            size_t    capacity,
            QueueMode mode= QueueMode.SPSC,
            cbool     overwrite= False,
            cbool     zerocopy=  False,
            cbool     block_on_full= False,
        ) nogil:

        this._signal_registered = False 
        
        this._init_flags = 0

        if overwrite:
            this._init_flags |= F_OVERWRITE
        if zerocopy:
            this._init_flags |= F_ZEROCOPY
        if block_on_full:
            this._init_flags |= F_BLOCK_ON_FULL

        if queue_init(<void*>&this._q, slot_size, capacity, mode != SPSC, this._init_flags) == Q_ERR:
            throw_invalid_argument(b"invalid capacity/slot_size, or allocation failed")

        this._q.mode = mode

        if mode == SPSC:
            this._q.fn_push         = spsc_push
            this._q.fn_try_push     = spsc_try_push
            this._q.fn_push_var     = spsc_push_var
            this._q.fn_try_push_var = spsc_try_push_var
            this._q.fn_pop          = spsc_pop
            this._q.fn_try_pop      = spsc_try_pop
            this._q.fn_pop_var      = spsc_pop_var
            this._q.fn_try_pop_var  = spsc_try_pop_var
            this._q.fn_pop_borrow   = spsc_pop_borrow
            this._q.fn_pop_commit   = spsc_pop_commit

        elif mode == SPMC:
            this._q.fn_push         = spmc_push
            this._q.fn_try_push     = spmc_try_push
            this._q.fn_push_var     = spmc_push_var
            this._q.fn_try_push_var = spmc_try_push_var
            this._q.fn_pop          = spmc_pop
            this._q.fn_try_pop      = spmc_try_pop
            this._q.fn_pop_var      = spmc_pop_var          
            this._q.fn_try_pop_var  = spmc_try_pop_var
            this._q.fn_pop_borrow   = spmc_pop_borrow     
            this._q.fn_pop_commit   = spmc_pop_commit            

        elif mode == MPSC:
            this._q.fn_push         = mpsc_push
            this._q.fn_try_push     = mpsc_try_push
            this._q.fn_push_var     = mpsc_push_var
            this._q.fn_try_push_var = mpsc_try_push_var
            this._q.fn_pop          = mpsc_pop
            this._q.fn_try_pop      = mpsc_try_pop
            this._q.fn_pop_var      = mpsc_pop_var
            this._q.fn_try_pop_var  = mpsc_try_pop_var
            this._q.fn_pop_borrow   = mpsc_pop_borrow
            this._q.fn_pop_commit   = mpsc_pop_commit

        elif mode == MPMC:
            this._q.fn_push         = mpmc_push
            this._q.fn_try_push     = mpmc_try_push
            this._q.fn_push_var     = mpmc_push_var
            this._q.fn_try_push_var = mpmc_try_push_var
            this._q.fn_pop          = mpmc_pop
            this._q.fn_try_pop      = mpmc_try_pop
            this._q.fn_pop_var      = mpmc_pop_var
            this._q.fn_try_pop_var  = mpmc_try_pop_var
            this._q.fn_pop_borrow   = mpmc_pop_borrow
            this._q.fn_pop_commit   = mpmc_pop_commit
        
        if mode == SPMC  or mode == MPMC:
            this._q.fn_register_consumer   = register_consumer
            this._q.fn_unregister_consumer = unregister_consumer

        init_signal_handler()
        register_context_notify(
            <void*>&this._q,
            NULL,
            <context_notify_fn>queue_notify,
        )
        this._signal_registered = True

    int push(const char* data, size_t size) noexcept nogil:
        return this._q.fn_push(<void*>&this._q, data, size)

    int try_push(const char* data, size_t size) noexcept nogil:
        return this._q.fn_try_push(<void*>&this._q, data, size)

    int push_var(const char* data, size_t size) noexcept nogil:
        return this._q.fn_push_var(<void*>&this._q, data, size)

    int try_push_var(const char* data, size_t size) noexcept nogil:
        return this._q.fn_try_push_var(<void*>&this._q, data, size)

    int pop(char** out_buf, size_t* out_size) noexcept nogil:
        return this._q.fn_pop(<void*>&this._q, out_buf, out_size)

    int try_pop(char** out_buf, size_t* out_size) noexcept nogil:
        return this._q.fn_try_pop(<void*>&this._q, out_buf, out_size)

    int pop_var(char** out_buf, size_t* out_size) noexcept nogil:
        return this._q.fn_pop_var(<void*>&this._q, out_buf, out_size)

    int try_pop_var(char** out_buf, size_t* out_size) noexcept nogil:
        return this._q.fn_try_pop_var(<void*>&this._q, out_buf, out_size)

    int pop_borrow(char** out_buf, size_t* out_size) noexcept nogil:
        return this._q.fn_pop_borrow(<void*>&this._q, out_buf, out_size)

    void pop_commit() noexcept nogil:
        this._q.fn_pop_commit(<void*>&this._q)

    int add_consumer(uint32_t* out_id) noexcept nogil:
        return this._q.fn_register_consumer(<void*>&this._q, out_id)

    void remove_consumer(uint32_t reader_id) noexcept nogil:
        this._q.fn_unregister_consumer(<void*>&this._q, reader_id)

    int close(long timeout_ms= 0) noexcept nogil:
        return queue_close(<void*>&this._q, timeout_ms)

    void __dealloc__():
        this.close()

        if this._signal_registered:
            unregister_context_notify(<void*>&this._q)
            cleanup_signal_handler()

        queue_destroy(<void*>&this._q)
"""


cdef class Queue:
    def __init__(
            self,
            size_t    slot_size,
            size_t    capacity,
            QueueMode mode          = QueueMode.SPSC,
            bint      overwrite     = False,
            bint      zerocopy      = False,
            bint      block_on_full = False,
            bint      wait_consumers = False,
            bint      lag_evict      = False
        ):

        self._signal_registered = False 
        
        cdef uint8_t init_flags = (
            (F_OVERWRITE     if overwrite     else 0) |
            (F_ZEROCOPY      if zerocopy      else 0) |
            (F_BLOCK_ON_FULL  if block_on_full  else 0) |
            (F_WAIT_CONSUMERS if wait_consumers else 0) |
            (F_LAG_EVICT      if lag_evict     else 0)
        )
        cdef int rc = queue_init(<void*>&self._q, slot_size, capacity,
                                  mode != SPSC, init_flags)
        if rc == Q_ERR:
            raise ValueError("invalid capacity/slot_size, or allocation failed")

        self._q.mode = mode

        if mode == SPSC:
            self._q.fn_push         = spsc_push
            self._q.fn_try_push     = spsc_try_push
            self._q.fn_push_var     = spsc_push_var
            self._q.fn_try_push_var = spsc_try_push_var
            self._q.fn_pop          = spsc_pop
            self._q.fn_try_pop      = spsc_try_pop
            self._q.fn_pop_var      = spsc_pop_var
            self._q.fn_try_pop_var  = spsc_try_pop_var
            self._q.fn_pop_borrow   = spsc_pop_borrow
            self._q.fn_pop_commit   = spsc_pop_commit

        elif mode == SPMC:
            self._q.fn_push         = spmc_push
            self._q.fn_try_push     = spmc_try_push
            self._q.fn_push_var     = spmc_push_var
            self._q.fn_try_push_var = spmc_try_push_var
            self._q.fn_pop          = spmc_pop
            self._q.fn_try_pop      = spmc_try_pop
            self._q.fn_pop_var      = spmc_pop_var          
            self._q.fn_try_pop_var  = spmc_try_pop_var
            self._q.fn_pop_borrow   = spmc_pop_borrow     
            self._q.fn_pop_commit   = spmc_pop_commit            

        elif mode == MPSC:
            self._q.fn_push         = mpsc_push
            self._q.fn_try_push     = mpsc_try_push
            self._q.fn_push_var     = mpsc_push_var
            self._q.fn_try_push_var = mpsc_try_push_var
            self._q.fn_pop          = mpsc_pop
            self._q.fn_try_pop      = mpsc_try_pop
            self._q.fn_pop_var      = mpsc_pop_var
            self._q.fn_try_pop_var  = mpsc_try_pop_var
            self._q.fn_pop_borrow   = mpsc_pop_borrow
            self._q.fn_pop_commit   = mpsc_pop_commit

        elif mode == MPMC:
            self._q.fn_push         = mpmc_push
            self._q.fn_try_push     = mpmc_try_push
            self._q.fn_push_var     = mpmc_push_var
            self._q.fn_try_push_var = mpmc_try_push_var
            self._q.fn_pop          = mpmc_pop
            self._q.fn_try_pop      = mpmc_try_pop
            self._q.fn_pop_var      = mpmc_pop_var
            self._q.fn_try_pop_var  = mpmc_try_pop_var
            self._q.fn_pop_borrow   = mpmc_pop_borrow
            self._q.fn_pop_commit   = mpmc_pop_commit
        
        if mode == SPMC  or mode == MPMC:
            self._q.fn_register_consumer   = register_consumer
            self._q.fn_unregister_consumer = unregister_consumer
        elif mode == QueueMode.MPSC:
            self._q.fn_register_consumer   = mpsc_register_consumer
            self._q.fn_unregister_consumer = mpsc_unregister_consumer
        
        if mode == SPMC or mode == MPSC or mode == MPMC:
            self._q.fn_register_producer   = register_producer
            self._q.fn_unregister_producer = unregister_producer

        init_signal_handler()
        register_context_notify(
            <void*>&self._q,
            NULL,
            <context_notify_fn>queue_notify,
        )
        self._signal_registered = True

    cdef int push(self, const char* data, size_t size) noexcept nogil:
        return self._q.fn_push(<void*>&self._q, data, size)

    cdef int try_push(self, const char* data, size_t size) noexcept nogil:
        return self._q.fn_try_push(<void*>&self._q, data, size)

    cdef int push_var(self, const char* data, size_t size) noexcept nogil:
        return self._q.fn_push_var(<void*>&self._q, data, size)

    cdef int try_push_var(self, const char* data, size_t size) noexcept nogil:
        return self._q.fn_try_push_var(<void*>&self._q, data, size)

    cdef int pop(self, char** out_buf, size_t* out_size) noexcept nogil:
        return self._q.fn_pop(<void*>&self._q, out_buf, out_size)

    cdef int try_pop(self, char** out_buf, size_t* out_size) noexcept nogil:
        return self._q.fn_try_pop(<void*>&self._q, out_buf, out_size)

    cdef int pop_var(self, char** out_buf, size_t* out_size) noexcept nogil:
        return self._q.fn_pop_var(<void*>&self._q, out_buf, out_size)

    cdef int try_pop_var(self, char** out_buf, size_t* out_size) noexcept nogil:
        return self._q.fn_try_pop_var(<void*>&self._q, out_buf, out_size)

    cdef int pop_borrow(self, char** out_buf, size_t* out_size) noexcept nogil:
        return self._q.fn_pop_borrow(<void*>&self._q, out_buf, out_size)

    cdef void pop_commit(self) noexcept nogil:
        self._q.fn_pop_commit(<void*>&self._q)

    cdef int register_consumer(self, uint32_t* out_id) noexcept nogil:
        return self._q.fn_register_consumer(<void*>&self._q, out_id)

    cdef void unregister_consumer(self, uint32_t reader_id) noexcept nogil:
        self._q.fn_unregister_consumer(<void*>&self._q, reader_id)

    cdef int register_producer(self, uint32_t* out_id) noexcept nogil:
        return self._q.fn_register_producer(<void*>&self._q, out_id)

    cdef void unregister_producer(self, uint32_t producer_id) noexcept nogil:
        self._q.fn_unregister_producer(<void*>&self._q, producer_id)

    cdef int close(self, long timeout_ms = 0) noexcept nogil:
        return queue_close(<void*>&self._q, timeout_ms)

    def __dealloc__(self):
        self.close()

        if self._signal_registered:
            unregister_context_notify(<void*>&self._q)
            cleanup_signal_handler()

        queue_destroy(<void*>&self._q)



cdef class BridgeQueue:  ## Dispatch helper
    
    def __init__(
            self,
            size_t    capacity = 16384,
            size_t    slot_size = 2048,
            bint      zerocopy  = False,
            bint      overwrite     = False,
            bint      block_on_full = False,
        ):
        self._signal_registered = False 
        
        cdef uint8_t init_flags = (
            (F_OVERWRITE     if overwrite     else 0) |
            (F_ZEROCOPY      if zerocopy      else 0) |
            (F_BLOCK_ON_FULL  if block_on_full  else 0) 
        )
        cdef int rc = queue_init(<void*>&self._q, slot_size, capacity,
                                  False, init_flags)
        if rc == Q_ERR:
            raise ValueError("invalid capacity/slot_size, or allocation failed")
        self._q.fn_push         = NULL
        self._q.fn_try_push     = NULL
        self._q.fn_push_var     = NULL
        self._q.fn_try_push_var = NULL
        self._q.fn_pop          = NULL
        self._q.fn_try_pop      = NULL
        self._q.fn_pop_var      = NULL
        self._q.fn_try_pop_var  = NULL
        self._q.fn_pop_borrow   = NULL
        self._q.fn_pop_commit   = NULL

        init_signal_handler()
        register_context_notify(
            <void*>&self._q,
            NULL,
            <context_notify_fn>queue_notify,
        )
        self._signal_registered = True

    cdef int push(self, const char* data, size_t size) noexcept nogil:
        return spsc_push(<void*>&self._q, data, size)

    cdef int try_push(self, const char* data, size_t size) noexcept nogil:
        return spsc_try_push(<void*>&self._q, data, size)

    cdef int push_var(self, const char* data, size_t size) noexcept nogil:
        return spsc_push_var(<void*>&self._q, data, size)

    cdef int try_push_var(self, const char* data, size_t size) noexcept nogil:
        return spsc_try_push_var(<void*>&self._q, data, size)

    cdef int pop(self, char** out_buf, size_t* out_size):
        return spsc_pop_py_dispatch(<void*>&self._q, out_buf, out_size)

    cdef int try_pop(self, char** out_buf, size_t* out_size):
        return spsc_try_pop_py_dispatch(<void*>&self._q, out_buf, out_size)

    cdef int pop_var(self, char** out_buf, size_t* out_size):
        return spsc_pop_var_py_dispatch(<void*>&self._q, out_buf, out_size)

    cdef int try_pop_var(self, char** out_buf, size_t* out_size):
        return spsc_try_pop_var_py_dispatch(<void*>&self._q, out_buf, out_size)

    cdef int close(self, long timeout_ms = 0) noexcept nogil:
        return queue_close(<void*>&self._q, timeout_ms)

    def __dealloc__(self):
        self.close()

        if self._signal_registered:
            unregister_context_notify(<void*>&self._q)
            cleanup_signal_handler()

        queue_destroy(<void*>&self._q)

# =========================================================================
# ========================   PYTHON WRAPPER   =============================
# =========================================================================

cpdef enum class BroadcastMode:
    SPSC = <int>QueueMode.SPSC
    SPMC = <int>QueueMode.SPMC
    MPSC = <int>QueueMode.MPSC
    MPMC = <int>QueueMode.MPMC


class QueueError(Exception):
    pass

class QueueClosed(QueueError):
    pass

class QueueOrphaned(QueueError):
    pass

class QueueUnknownStatus(QueueError):
    pass



cdef inline int _check_ret(int ret) except -1000:
    if ret == Q_OK or ret == Q_EMPTY or ret == Q_FULL or ret == Q_NO_CONSUMER:
        return ret
    elif ret == Q_CLOSING:
        raise QueueClosed(b"Queue is closing")
    elif ret == Q_ERR:
        raise QueueError(b"queue is in an invalid state")
    elif ret == Q_ORPHANED:
        raise QueueOrphaned(b"claimed slot was abandoned")
    else:
        raise QueueUnknownStatus(b"unrecognized queue status code: %d" % ret)



cdef class BroadcastQueue:
    cdef:
        PyQueueImpl _q   
        bint _signal_registered

    def __init__(
            self,
            size_t    capacity = 16384,
            BroadcastMode mode  = BroadcastMode.SPSC,
            bint      overwrite     = False,
            bint      block_on_full = False,
            bint      wait_consumers = False,
            bint      lag_evict      = False
        ):

        self._signal_registered = False 
        
        cdef uint8_t init_flags = <uint8_t>(
            (F_OVERWRITE     if overwrite     else 0) |
            (F_BLOCK_ON_FULL  if block_on_full  else 0) |
            (F_WAIT_CONSUMERS if wait_consumers else 0) |
            (F_LAG_EVICT      if lag_evict     else 0)
        )
        
        self._q.mode = <QueueMode>mode

        if py_queue_init(<void*>&self._q, capacity, <QueueMode>mode != SPSC, init_flags) == Q_ERR:
            raise ValueError("invalid capacity/slot_size, or allocation failed")        

        if mode == BroadcastMode.SPSC:
            self._q.fn_py_push         = spsc_py_push
            self._q.fn_py_try_push     = spsc_py_try_push
            self._q.fn_py_pop          = spsc_py_pop
            self._q.fn_py_try_pop      = spsc_py_try_pop

        elif mode == BroadcastMode.SPMC:
            self._q.fn_py_push         = spmc_py_push
            self._q.fn_py_try_push     = spmc_py_try_push
            self._q.fn_py_pop          = spmc_py_pop
            self._q.fn_py_try_pop      = spmc_py_try_pop       

        elif mode == BroadcastMode.MPSC:
            self._q.fn_py_push         = mpsc_py_push
            self._q.fn_py_try_push     = mpsc_py_try_push
            self._q.fn_py_pop          = mpsc_py_pop
            self._q.fn_py_try_pop      = mpsc_py_try_pop

        elif mode == BroadcastMode.MPMC:
            self._q.fn_py_push         = mpmc_py_push
            self._q.fn_py_try_push     = mpmc_py_try_push
            self._q.fn_py_pop          = mpmc_py_pop
            self._q.fn_py_try_pop      = mpmc_py_try_pop
        
        if mode == BroadcastMode.SPMC  or mode == BroadcastMode.MPMC:
            self._q.fn_register_consumer   = py_register_consumer
            self._q.fn_unregister_consumer = py_unregister_consumer
        elif mode == BroadcastMode.MPSC:
            self._q.fn_register_consumer   = py_mpsc_register_consumer
            self._q.fn_unregister_consumer = py_mpsc_unregister_consumer

        if mode != BroadcastMode.SPSC:
            self._q.fn_register_producer   = py_register_producer
            self._q.fn_unregister_producer = py_unregister_producer

        init_signal_handler()
        register_context_notify(
            <void*>&self._q,
            NULL,
            <context_notify_fn>py_queue_notify,
        )
        self._signal_registered = True

    cpdef int push(self, object msg):
        return _check_ret(self._q.fn_py_push(<void*>&self._q, msg))

    cpdef int try_push(self, object msg):
        return _check_ret(self._q.fn_py_try_push(<void*>&self._q, msg))

    cpdef object pop(self):
        cdef PyObject* out_ptr = NULL
        cdef object out
        cdef int ret = self._q.fn_py_pop(<void*>&self._q, &out_ptr)
        if ret == Q_OK:
            out = <object>out_ptr
            Py_XDECREF(out_ptr)
            return out
        _check_ret(ret)
        return None

    cpdef object try_pop(self):
        cdef PyObject* out_ptr = NULL
        cdef object out
        cdef int ret = self._q.fn_py_try_pop(<void*>&self._q, &out_ptr)
        if ret == Q_OK:
            out = <object>out_ptr
            Py_XDECREF(out_ptr) 
            return out
        _check_ret(ret)
        return None

    cpdef int register_consumer(self):
        if self._q.fn_register_consumer == NULL:
           raise RuntimeError(
               "register_consumer() is only valid for SPMC/MPMC BroadcastQueue mode"
           )
        cdef:
            uint32_t out_id
            int ret

        with nogil:
            ret= self._q.fn_register_consumer(<void*>&self._q, &out_id)
        return _check_ret(ret)

    cpdef void unregister_consumer(self):
        if self._q.fn_unregister_consumer == NULL:
            raise RuntimeError(
                "unregister_consumer() is only valid for SPMC/MPMC BroadcastQueue mode"
            )
        cdef uint32_t reader_id = _tls_get_rid()
        if reader_id == 0xFFFFFFFFu:
            return
        with nogil:
            self._q.fn_unregister_consumer(<void*>&self._q, reader_id)

    cpdef int register_producer(self):
        if self._q.fn_register_producer == NULL:
            raise RuntimeError(
                "register_producer() is not valid for SPSC BroadcastQueue mode"
            )
        cdef:
            uint32_t out_id
            int ret
        with nogil:
            ret= self._q.fn_register_producer(<void*>&self._q, &out_id)
        _check_ret(ret)

    cpdef void unregister_producer(self):
        if self._q.fn_unregister_producer == NULL:
            raise RuntimeError(
                "unregister_producer() is not valid for SPSC BroadcastQueue mode"
            )
        cdef uint32_t producer_id = _tls_get_pid()
        if producer_id == 0xFFFFFFFFu:
            return
        with nogil:
            self._q.fn_unregister_producer(<void*>&self._q, producer_id)

    cpdef int close(self, long timeout_ms = 0):
        with nogil:
            return py_queue_close(<void*>&self._q, timeout_ms)

    def __dealloc__(self):
        self.close()

        if self._signal_registered:
            unregister_context_notify(<void*>&self._q)
            cleanup_signal_handler()

        py_queue_destroy(<void*>&self._q)

