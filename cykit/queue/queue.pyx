"""
@file queue.pyx
@brief Lock-free ring buffer queue supporting SPSC, SPMC, MPSC, and MPMC modes.
@date 2026-06-18
@copyright Part of the https://github.com/Tapanhaz/cykit library.

@note All push/pop variants are noexcept nogil and safe to call from C threads.
      SPMC/MPMC consumers must call register_consumer before popping and
      unregister_consumer on exit.
"""

from libc.stdint  cimport uint64_t, uint32_t, uint16_t
from libc.stddef  cimport size_t
from libc.string  cimport memcpy, memset
from libc.stdlib  cimport free, realloc

from cykit.common cimport (
    atomic_notify_one,
    atomic_notify_all,
    atomic_thread_fence,
    atomic_wait,
    memory_order_acquire,
    memory_order_release,
    memory_order_relaxed,
    aligned_alloc_,
    aligned_free_,
    cpu_pause,
    builtin_ctzll
)

from cykit.utils.signal_handler cimport (
    init_signal_handler,
    context_notify_fn,
    register_context_notify,
    unregister_context_notify,
    cleanup_signal_handler,
)

from cykit.utils.compat cimport (
    clock_gettime_,
    CLOCK_MONOTONIC_,
    usleep_,
    timespec_,
)



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
    """
    int      _cas_u64(void* obj, uint64_t* expected, uint64_t desired) noexcept nogil
    void     _tls_set_rid(uint32_t rid)                    noexcept nogil
    uint32_t _tls_get_rid()                                noexcept nogil
    void     _tls_set_borrow(uint64_t pos, uint64_t idx)   noexcept nogil
    uint64_t _tls_get_borrow_pos()                         noexcept nogil
    uint64_t _tls_get_borrow_idx()                         noexcept nogil


# =========================================================================
# ======================    HELPER FUNCTIONS    ===========================
# =========================================================================


cdef void queue_notify(void* ctx) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    q.running.store(0, memory_order_release)
    q.tail.fetch_add(1, memory_order_relaxed)
    q.head.fetch_add(1, memory_order_relaxed)
    atomic_notify_all(&q.tail)
    atomic_notify_all(&q.head)
    atomic_notify_all(&q.reader_min_pos)


cdef inline bint _is_empty(QueueImpl* q) noexcept nogil:
    if q.mode == SPMC or q.mode == MPMC:
        return consumer_min_pos(q) == q.tail.load(memory_order_acquire)
    return q.head.load(memory_order_relaxed) == q.tail.load(memory_order_relaxed)

cdef inline long _elapsed_ms(timespec_* start, timespec_* now) noexcept nogil:
    return (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) // 1000000


cdef inline uint64_t consumer_min_pos(QueueImpl* q) noexcept nogil:
    cdef:
        uint64_t mask = q.reader_active_mask.load(memory_order_acquire)
        uint64_t min_pos = q.tail.load(memory_order_acquire)
        uint64_t pos
        int i

    while mask:
        i = builtin_ctzll(mask)
        pos = q.reader_pos[i].load(memory_order_acquire)
        if pos < min_pos:
            min_pos = pos
        mask &= mask - 1
    return min_pos

cdef inline void consumer_update_min(QueueImpl* q) noexcept nogil:
    q.reader_min_pos.store(consumer_min_pos(q), memory_order_release)


cdef int queue_close(void* ctx, long timeout_ms = 0) noexcept nogil:
    cdef:
        QueueImpl*  q        = <QueueImpl*>ctx
        timespec_   start, now
        long        elapsed  = 0
        uint64_t      t, tl

    if not q.running.load(memory_order_acquire):
        return 0

    q.flags |= F_CLOSING

    if timeout_ms == -1:
        while not _is_empty(q):
            usleep_(5000)
    elif timeout_ms > 0:
        clock_gettime_(CLOCK_MONOTONIC_, &start)
        while not _is_empty(q):
            clock_gettime_(CLOCK_MONOTONIC_, &now)
            elapsed = _elapsed_ms(&start, &now)
            if elapsed >= timeout_ms:
                break
            usleep_(5000)
    
    if q.mode == MPSC or q.mode == MPMC:
        t = q.head.load(memory_order_acquire)
        tl = q.tail.load(memory_order_acquire)
        while t < tl:
            idx = t & q.capacity_mask
            while q.publish[idx].seq.load(memory_order_acquire) != t + 1:
                cpu_pause()
            t += 1

    q.running.store(0, memory_order_release)
    q.tail.fetch_add(1, memory_order_release)
    q.head.fetch_add(1, memory_order_release)
    atomic_notify_all(&q.tail)
    atomic_notify_all(&q.head)
    atomic_notify_all(&q.reader_min_pos)

    return 0 if _is_empty(q) else -1


# =========================================================================
# ===============    SPMC - MPMC REGISTER CONSUMER    =====================
# =========================================================================

cdef int register_consumer(void* ctx, uint32_t* out_id) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    cdef uint64_t mask, bit
    cdef uint32_t i

    while True:
        mask = q.reader_active_mask.load(memory_order_acquire)
        if mask == 0xFFFFFFFFFFFFFFFFULL:
            return Q_ERR
        i    = builtin_ctzll(~mask)
        bit  = (<uint64_t>1) << i
        if _cas_u64(&q.reader_active_mask, &mask, mask | bit):
            q.reader_pos[i].store(
                q.tail.load(memory_order_acquire), memory_order_release
            )

            q.consumer_ctx[i].expected_seq = 0
            q.consumer_ctx[i].expected_chunk = 0
            q.consumer_ctx[i].assemble_buf = NULL
            q.consumer_ctx[i].assemble_used = 0
            q.consumer_ctx[i].assemble_cap = 0

            out_id[0] = i
            _tls_set_rid(i)
            consumer_update_min(q)
            atomic_notify_all(&q.reader_min_pos)
            return Q_OK


cdef void unregister_consumer(void* ctx, uint32_t reader_id) noexcept nogil:
    cdef QueueImpl* q   = <QueueImpl*>ctx
    cdef uint64_t mask, bit
    bit = (<uint64_t>1) << reader_id

    if q.consumer_ctx[reader_id].assemble_buf != NULL:
        free(q.consumer_ctx[reader_id].assemble_buf)
        q.consumer_ctx[reader_id].assemble_buf = NULL
        q.consumer_ctx[reader_id].assemble_cap = 0

    while True:
        mask = q.reader_active_mask.load(memory_order_acquire)
        if _cas_u64(&q.reader_active_mask, &mask, mask & ~bit):
            _tls_set_rid(0XFFFFFFFF)
            consumer_update_min(q)
            atomic_notify_all(&q.reader_min_pos)
            return


# =========================================================================
# ===============================   SPSC   ================================
# =========================================================================

# SPSC PUSH ===============================================================

cdef int spsc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if q.flags & F_CLOSING:
        return Q_ERR

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags & F_OVERWRITE:
                q.head.store(head + 1, memory_order_release)
                atomic_notify_one(&q.head)
                continue
            elif q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_notify_one(&q.tail)
                atomic_wait(&q.head, head)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
                continue
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask
        slot = &q.slots[idx]

        if q.flags & F_ZEROCOPY:
            slot.buf  = <char*>data
            slot.size = size
        else:
            if size > q.slot_size:
                size = q.slot_size
            memcpy(slot.buf, data, size)
            slot.size = size

        atomic_thread_fence(memory_order_release)
        q.tail.store(tail + 1, memory_order_release)
        atomic_notify_one(&q.tail)
        return Q_OK

    return Q_ERR


cdef int spsc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR

    head = q.head.load(memory_order_acquire)
    tail = q.tail.load(memory_order_relaxed)

    if tail - head >= q.capacity_mask + 1:
        if q.flags & F_OVERWRITE:
            q.head.store(head + 1, memory_order_release)
            atomic_notify_one(&q.head)
            head = head + 1
            if tail - head >= q.capacity_mask + 1:
                return Q_FULL
        else:
            return Q_FULL

    idx  = tail & q.capacity_mask
    slot = &q.slots[idx]

    if q.flags & F_ZEROCOPY:
        slot.buf  = <char*>data
        slot.size = size
    else:
        if size > q.slot_size:
            size = q.slot_size
        memcpy(slot.buf, data, size)
        slot.size = size

    atomic_thread_fence(memory_order_release)
    q.tail.store(tail + 1, memory_order_release)
    atomic_notify_one(&q.tail)
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

    if q.flags & F_CLOSING:
        return Q_ERR

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    seq_id       = q.seq_counter
    q.seq_counter += 1
    offset       = 0

    for chunk_idx in range(total_chunks):
        while q.running.load(memory_order_acquire):
            head = q.head.load(memory_order_acquire)
            tail = q.tail.load(memory_order_relaxed)

            if tail - head >= q.capacity_mask + 1:
                if q.flags & F_OVERWRITE:
                    victim      = &q.slots[head & q.capacity_mask]
                    chunks_left = victim.total_chunks - victim.chunk_idx
                    if chunks_left == 0:
                        chunks_left = 1
                    q.head.store(head + chunks_left, memory_order_release)
                    atomic_notify_one(&q.head)
                    continue
                elif q.flags & F_BLOCK_ON_FULL:
                    if not q.running.load(memory_order_acquire):
                        return Q_ERR
                    atomic_notify_one(&q.tail)
                    atomic_wait(&q.head, head)
                    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                        return Q_ERR
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
            atomic_notify_one(&q.tail)
            break

        if not q.running.load(memory_order_acquire):
            return Q_ERR

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

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    seq_id       = q.seq_counter
    q.seq_counter += 1
    offset       = 0

    for chunk_idx in range(total_chunks):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags & F_OVERWRITE:
                victim      = &q.slots[head & q.capacity_mask]
                chunks_left = victim.total_chunks - victim.chunk_idx
                if chunks_left == 0:
                    chunks_left = 1
                q.head.store(head + chunks_left, memory_order_release)
                atomic_notify_one(&q.head)
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
        atomic_notify_one(&q.tail)

    return Q_OK


# SPSC POP  ===============================================================


cdef int spsc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        out_buf[0]  = slot.buf
        out_size[0] = slot.size

        atomic_thread_fence(memory_order_acquire)
        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head)
        return Q_OK

    return Q_ERR


cdef int spsc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_ERR

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx  = head & q.capacity_mask
    slot = &q.slots[idx]

    out_buf[0]  = slot.buf
    out_size[0] = slot.size

    atomic_thread_fence(memory_order_acquire)
    q.head.store(head + 1, memory_order_release)
    atomic_notify_one(&q.head)
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
                return Q_ERR
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx  = head & q.capacity_mask
        slot = &q.slots[idx]

        atomic_thread_fence(memory_order_acquire)
        out_buf[0]  = slot.buf
        out_size[0] = slot.size
        return Q_OK

    return Q_ERR


cdef void spsc_pop_commit(void* ctx) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    cdef uint64_t head = q.head.load(memory_order_relaxed)
    q.head.store(head + 1, memory_order_release)
    atomic_notify_one(&q.head)


cdef int spsc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0]
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
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
                atomic_notify_one(&q.head)
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_ERR
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head)

        st.expected_chunk += 1

        if st.expected_chunk == slot.total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_ERR


cdef int spsc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0]
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp

    if not q.running.load(memory_order_acquire):
        return Q_ERR

    while True:
        if not q.running.load(memory_order_acquire):
            return Q_ERR

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
                atomic_notify_one(&q.head)
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_ERR
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&q.head)

        st.expected_chunk += 1

        if st.expected_chunk == slot.total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK


# =========================================================================
# ===============================   MPSC   ================================
# =========================================================================

# MPSC PUSH ===============================================================

cdef int mpsc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if q.flags & F_CLOSING:
        return Q_ERR

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head >= q.capacity_mask + 1:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.head, head)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
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
        atomic_notify_all(&q.publish[idx].seq)
        atomic_notify_all(&q.tail)
        return Q_OK

    return Q_ERR


cdef int mpsc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR

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
    atomic_notify_all(&q.publish[idx].seq)
    atomic_notify_all(&q.tail)
    return Q_OK


cdef int mpsc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx, cap
        QueueSlot* slot
        size_t offset, chunk_bytes
        uint16_t total_chunks, chunk_idx
        uint32_t seq_id

    if q.flags & F_CLOSING:
        return Q_ERR

    cap          = q.capacity_mask + 1
    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if (tail + total_chunks) - head > cap:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.head, head)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + total_chunks):
            cpu_pause()
            continue

        seq_id = q.seq_counter
        q.seq_counter += 1
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
            atomic_notify_all(&q.publish[idx].seq)
            atomic_notify_all(&q.tail)

        return Q_OK

    return Q_ERR


cdef int mpsc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx, cap
        QueueSlot* slot
        size_t offset, chunk_bytes
        uint16_t total_chunks, chunk_idx
        uint32_t seq_id

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR

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

    seq_id = q.seq_counter
    q.seq_counter += 1
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
        atomic_notify_all(&q.publish[idx].seq)
        atomic_notify_all(&q.tail)

    return Q_OK


# MPSC POP  ===============================================================


cdef int mpsc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx = head & q.capacity_mask

        while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            if not q.running.load(memory_order_acquire):
                return Q_ERR            
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out_buf[0]  = slot.buf
        out_size[0] = slot.size

        q.head.store(head + 1, memory_order_release)
        q.publish[idx].seq.store(
            head + 1 + (q.capacity_mask + 1), memory_order_release
        )
        atomic_notify_all(&q.head)
        return Q_OK

    return Q_ERR


cdef int mpsc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_ERR

    head = q.head.load(memory_order_relaxed)
    tail = q.tail.load(memory_order_acquire)

    if head == tail:
        return Q_EMPTY

    idx = head & q.capacity_mask

    if q.publish[idx].seq.load(memory_order_acquire) != head + 1:
        return Q_EMPTY

    slot = &q.slots[idx]
    atomic_thread_fence(memory_order_acquire)

    out_buf[0]  = slot.buf
    out_size[0] = slot.size

    q.head.store(head + 1, memory_order_release)
    q.publish[idx].seq.store(
        head + 1 + (q.capacity_mask + 1), memory_order_release
    )
    atomic_notify_all(&q.head)
    return Q_OK


cdef int mpsc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t head, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx = head & q.capacity_mask

        while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            atomic_wait(&q.publish[idx].seq, q.publish[idx].seq.load(memory_order_relaxed))

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out_buf[0]  = slot.buf
        out_size[0] = slot.size
        _tls_set_borrow(head, idx)
        return Q_OK

    return Q_ERR


cdef void mpsc_pop_commit(void* ctx) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        uint64_t bpos = _tls_get_borrow_pos()
        uint64_t bidx = _tls_get_borrow_idx()

    while q.publish[bidx].seq.load(memory_order_acquire) != bpos + 1:
        if not q.running.load(memory_order_acquire):
            return

    q.head.store(bpos + 1, memory_order_release)
    q.publish[bidx].seq.store(
        bpos + 1 + (q.capacity_mask + 1), memory_order_release
    )
    atomic_notify_all(&q.head)


cdef int mpsc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0]
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head == tail:
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx = head & q.capacity_mask

        while q.publish[idx].seq.load(memory_order_acquire) != head + 1:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0
            else:
                q.head.store(head + 1, memory_order_release)
                q.publish[idx].seq.store(
                    head + 1 + (q.capacity_mask + 1), memory_order_release
                )
                atomic_notify_all(&q.head)
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_ERR
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        q.head.store(head + 1, memory_order_release)
        q.publish[idx].seq.store(
            head + 1 + (q.capacity_mask + 1), memory_order_release
        )
        atomic_notify_all(&q.head)

        st.expected_chunk += 1

        if st.expected_chunk == slot.total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_ERR


cdef int mpsc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q = <QueueImpl*>ctx
        ConsumerCtx* st = &q.consumer_ctx[0]
        uint64_t head, tail, idx
        QueueSlot* slot
        size_t needed
        char* tmp

    if not q.running.load(memory_order_acquire):
        return Q_ERR

    while True:
        if not q.running.load(memory_order_acquire):
            return Q_ERR

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
            else:
                q.head.store(head + 1, memory_order_release)
                q.publish[idx].seq.store(
                    head + 1 + (q.capacity_mask + 1), memory_order_release
                )
                atomic_notify_all(&q.head)
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_ERR
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        q.head.store(head + 1, memory_order_release)
        q.publish[idx].seq.store(
            head + 1 + (q.capacity_mask + 1), memory_order_release
        )
        atomic_notify_all(&q.head)

        st.expected_chunk += 1

        if st.expected_chunk == slot.total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK


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
        uint64_t   pos, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx = pos & q.capacity_mask

        while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            cpu_pause()

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out_buf[0]  = slot.buf
        out_size[0] = slot.size

        q.reader_pos[rid].store(pos + 1, memory_order_release)
        consumer_update_min(q)
        atomic_notify_all(&q.reader_min_pos)

        return Q_OK

    return Q_ERR


cdef inline int _mc_try_pop_impl(
    QueueImpl* q,
    char**     out_buf,
    size_t*    out_size,
    uint32_t   rid,
) noexcept nogil:
    cdef:
        uint64_t   pos, tail, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire):
        return Q_ERR

    pos  = q.reader_pos[rid].load(memory_order_acquire)
    tail = q.tail.load(memory_order_acquire)

    if pos == tail:
        return Q_EMPTY

    idx = pos & q.capacity_mask

    if q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
        return Q_EMPTY

    slot = &q.slots[idx]
    atomic_thread_fence(memory_order_acquire)

    out_buf[0]  = slot.buf
    out_size[0] = slot.size

    q.reader_pos[rid].store(pos + 1, memory_order_release)
    consumer_update_min(q)
    atomic_notify_all(&q.reader_min_pos)

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

    if q.flags & F_CLOSING:
        return Q_ERR

    while q.running.load(memory_order_acquire):
        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.reader_min_pos, min_pos)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
                continue
            else:
                return Q_FULL

        idx  = tail & q.capacity_mask

        slot = &q.slots[idx]

        if q.flags & F_ZEROCOPY:
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
        atomic_notify_all(&q.tail)
        return Q_OK

    return Q_ERR


cdef int spmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR

    tail    = q.tail.load(memory_order_relaxed)
    min_pos = q.reader_min_pos.load(memory_order_acquire)

    if tail - min_pos >= q.capacity_mask + 1:
        return Q_FULL

    idx  = tail & q.capacity_mask

    slot = &q.slots[idx]

    if q.flags & F_ZEROCOPY:
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
    atomic_notify_all(&q.tail)
    return Q_OK


cdef int spmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if q.flags & F_CLOSING:
        return Q_ERR

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    seq_id       = q.seq_counter
    q.seq_counter += 1
    offset       = 0

    for chunk_idx in range(total_chunks):
        while q.running.load(memory_order_acquire):
            tail    = q.tail.load(memory_order_relaxed)
            min_pos = q.reader_min_pos.load(memory_order_acquire)

            if tail - min_pos >= q.capacity_mask + 1:
                if q.flags & F_BLOCK_ON_FULL:
                    if not q.running.load(memory_order_acquire):
                        return Q_ERR
                    atomic_wait(&q.reader_min_pos, min_pos)
                    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                        return Q_ERR
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
            atomic_notify_all(&q.tail)
            break

        if not q.running.load(memory_order_acquire):
            return Q_ERR

    return Q_OK


cdef int spmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR

    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)
    seq_id       = q.seq_counter
    q.seq_counter += 1
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
        atomic_notify_all(&q.tail)

    return Q_OK

# SPMC POP  ===============================================================

cdef int spmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_pop_impl(q, out_buf, out_size, _tls_get_rid())


cdef int spmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_try_pop_impl(q, out_buf, out_size, _tls_get_rid())


cdef int spmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        uint64_t   pos, tail, idx
        QueueSlot* slot

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx = pos & q.capacity_mask

        while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            if not q.running.load(memory_order_acquire):
                return Q_ERR

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        out_buf[0]  = slot.buf
        out_size[0] = slot.size
        _tls_set_borrow(pos, idx)
        return Q_OK

    return Q_ERR

cdef void spmc_pop_commit(void* ctx) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        uint64_t   pos = _tls_get_borrow_pos()

    q.reader_pos[rid].store(pos + 1, memory_order_release)
    consumer_update_min(q)
    atomic_notify_all(&q.reader_min_pos)


cdef int spmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        ConsumerCtx* st = &q.consumer_ctx[rid]
        uint64_t   pos, tail, idx
        QueueSlot* slot
        size_t     needed
        char*      tmp

    while q.running.load(memory_order_acquire):
        pos  = q.reader_pos[rid].load(memory_order_acquire)
        tail = q.tail.load(memory_order_acquire)

        if pos == tail:
            atomic_wait(&q.tail, tail)
            if not q.running.load(memory_order_acquire):
                return Q_ERR
            continue

        idx = pos & q.capacity_mask

        while q.publish[idx].seq.load(memory_order_acquire) != pos + 1:
            if not q.running.load(memory_order_acquire):
                return Q_ERR

        slot = &q.slots[idx]
        atomic_thread_fence(memory_order_acquire)

        if slot.seq_id != st.expected_seq or slot.chunk_idx != st.expected_chunk:
            if slot.chunk_idx == 0:
                st.expected_seq   = slot.seq_id
                st.expected_chunk = 0
                st.assemble_used  = 0
            else:
                q.reader_pos[rid].store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos)
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_ERR
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        q.reader_pos[rid].store(pos + 1, memory_order_release)
        consumer_update_min(q)
        atomic_notify_all(&q.reader_min_pos)

        st.expected_chunk += 1

        if st.expected_chunk == slot.total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK

    return Q_ERR


cdef int spmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint32_t   rid = _tls_get_rid()
        ConsumerCtx* st = &q.consumer_ctx[rid]
        uint64_t   pos, tail, idx
        QueueSlot* slot
        size_t     needed
        char*      tmp

    if not q.running.load(memory_order_acquire):
        return Q_ERR

    while True:
        if not q.running.load(memory_order_acquire):
            return Q_ERR

        pos  = q.reader_pos[rid].load(memory_order_acquire)
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
            else:
                q.reader_pos[rid].store(pos + 1, memory_order_release)
                consumer_update_min(q)
                atomic_notify_all(&q.reader_min_pos)
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                continue

        needed = st.assemble_used + slot.size
        if needed > st.assemble_cap:
            tmp = <char*>realloc(st.assemble_buf, needed * 2)
            if tmp == NULL:
                return Q_ERR
            st.assemble_buf = tmp
            st.assemble_cap = needed * 2

        memcpy(st.assemble_buf + st.assemble_used, slot.buf, slot.size)
        st.assemble_used += slot.size

        q.reader_pos[rid].store(pos + 1, memory_order_release)
        consumer_update_min(q)
        atomic_notify_all(&q.reader_min_pos)

        st.expected_chunk += 1

        if st.expected_chunk == slot.total_chunks:
            out_buf[0]       = st.assemble_buf
            out_size[0]      = st.assemble_used
            st.assemble_used  = 0
            st.expected_seq  += 1
            st.expected_chunk = 0
            return Q_OK


# =========================================================================
# ===============================   MPMC   ================================
# =========================================================================

# MPMC PUSH ===============================================================

cdef int mpmc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if q.flags & F_CLOSING:
        return Q_ERR

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.load(memory_order_acquire) == 0:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.reader_active_mask, <uint64_t>0)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if tail - min_pos >= q.capacity_mask + 1:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.reader_min_pos, min_pos)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
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
        atomic_notify_all(&q.tail)
        return Q_OK

    return Q_ERR


cdef int mpmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx
        QueueSlot* slot

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR
    
    if q.reader_active_mask.load(memory_order_acquire) == 0:
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
    atomic_notify_all(&q.tail)
    return Q_OK


cdef int mpmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx, cap
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if q.flags & F_CLOSING:
        return Q_ERR

    cap          = q.capacity_mask + 1
    total_chunks = <uint16_t>((size + q.slot_size - 1) / q.slot_size)

    while q.running.load(memory_order_acquire):
        if q.reader_active_mask.load(memory_order_acquire) == 0:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.reader_active_mask, <uint64_t>0)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
                continue
            else:
                return Q_NO_CONSUMER

        tail    = q.tail.load(memory_order_relaxed)
        min_pos = q.reader_min_pos.load(memory_order_acquire)

        if (tail + total_chunks) - min_pos > cap:
            if q.flags & F_BLOCK_ON_FULL:
                if not q.running.load(memory_order_acquire):
                    return Q_ERR
                atomic_wait(&q.reader_min_pos, min_pos)
                if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
                    return Q_ERR
                continue
            else:
                return Q_FULL

        if not _cas_u64(&q.tail, &tail, tail + total_chunks):
            cpu_pause()
            continue

        for chunk_idx in range(total_chunks):
            idx = (tail + chunk_idx) & q.capacity_mask

        seq_id = q.seq_counter
        q.seq_counter += 1
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
            atomic_notify_all(&q.tail)

        return Q_OK

    return Q_ERR


cdef int mpmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        QueueImpl* q   = <QueueImpl*>ctx
        uint64_t   tail, min_pos, idx, cap
        QueueSlot* slot
        size_t     offset, chunk_bytes
        uint16_t   total_chunks, chunk_idx
        uint32_t   seq_id

    if not q.running.load(memory_order_acquire) or (q.flags & F_CLOSING):
        return Q_ERR
    
    if q.reader_active_mask.load(memory_order_acquire) == 0:
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

    seq_id = q.seq_counter
    q.seq_counter += 1
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
        atomic_notify_all(&q.tail)

    return Q_OK

# MPMC POP ===============================================================

cdef int mpmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_pop_impl(q, out_buf, out_size, _tls_get_rid())

cdef int mpmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef QueueImpl* q = <QueueImpl*>ctx
    return _mc_try_pop_impl(q, out_buf, out_size, _tls_get_rid())

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

cdef class Queue:

    def __cinit__(self):
        self._q.head.store(0, memory_order_relaxed)
        self._q.tail.store(0, memory_order_relaxed)
        self._q.running.store(1, memory_order_relaxed)

        self._q.seq_counter    = 0

        self._q.slots     = NULL
        self._q.slot_bufs = NULL
        self._q.publish   = NULL

        self._q.reader_active_mask.store(0, memory_order_relaxed)
        self._q.reader_min_pos.store(0, memory_order_relaxed)

        cdef uint32_t _ri
        for _ri in range(64):
            self._q.reader_pos[_ri].store(0, memory_order_relaxed)
        
        cdef int _ci
        for _ci in range(64):
            self._q.consumer_ctx[_ci].expected_seq = 0
            self._q.consumer_ctx[_ci].expected_chunk = 0
            self._q.consumer_ctx[_ci].assemble_buf = NULL
            self._q.consumer_ctx[_ci].assemble_used = 0
            self._q.consumer_ctx[_ci].assemble_cap = 0

        self._q.fn_register_consumer   = NULL
        self._q.fn_unregister_consumer = NULL

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

    def __init__(
            self,
            size_t    slot_size,
            size_t    capacity,
            QueueMode mode          = QueueMode.SPSC,
            bint      overwrite     = False,
            bint      zerocopy      = False,
            bint      block_on_full = False,
        ):
        cdef size_t i

        if capacity == 0 or (capacity & (capacity - 1)) != 0:
            raise ValueError("capacity must be a non-zero power of 2")
        if slot_size == 0:
            raise ValueError("slot_size must be > 0")

        self._q.mode = mode
        self._q.flags = (
            (F_OVERWRITE     if overwrite     else 0) |
            (F_ZEROCOPY      if zerocopy      else 0) |
            (F_BLOCK_ON_FULL if block_on_full else 0)
        )
        self._q.capacity_mask = capacity - 1
        self._q.slot_size     = slot_size

        self._q.slots     = <QueueSlot*>aligned_alloc_(64, capacity * sizeof(QueueSlot))
        self._q.slot_bufs = <char*>aligned_alloc_(64, capacity * slot_size)

        if self._q.slots == NULL or self._q.slot_bufs == NULL:
            raise MemoryError("failed to allocate queue slots")

        memset(self._q.slot_bufs, 0, capacity * slot_size)

        for i in range(capacity):
            self._q.slots[i].buf          = self._q.slot_bufs + i * slot_size
            self._q.slots[i].size         = 0
            self._q.slots[i].seq_id       = 0
            self._q.slots[i].chunk_idx    = 0
            self._q.slots[i].total_chunks = 0

        if mode != SPSC:
            self._q.publish = <PublishEntry*>aligned_alloc_(
                64, capacity * sizeof(PublishEntry)
            )
            if self._q.publish == NULL:
                raise MemoryError("failed to allocate publish array")
            for i in range(capacity):
                self._q.publish[i].seq.store(i, memory_order_relaxed)

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

        init_signal_handler()
        register_context_notify(
            <void*>&self._q,
            NULL,
            <context_notify_fn>queue_notify,
        )

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

    cdef int close(self, long timeout_ms = 0) noexcept nogil:
        return queue_close(<void*>&self._q, timeout_ms)

    def __dealloc__(self):
        self.close()
        unregister_context_notify(<void*>&self._q)
        cleanup_signal_handler()

        cdef int _ci
        for _ci in range(64):
            if self._q.consumer_ctx[_ci].assemble_buf != NULL:
                free(self._q.consumer_ctx[_ci].assemble_buf)
                self._q.consumer_ctx[_ci].assemble_buf = NULL

        if self._q.publish != NULL:
            aligned_free_(self._q.publish)
            self._q.publish = NULL
        if self._q.slot_bufs != NULL:
            aligned_free_(self._q.slot_bufs)
            self._q.slot_bufs = NULL
        if self._q.slots != NULL:
            aligned_free_(self._q.slots)
            self._q.slots = NULL