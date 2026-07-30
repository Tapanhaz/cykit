"""
@file ipc.pyx
@brief Shared-memory IPC transport (SPMC/MPSC/MPMC) built on Boost.Interprocess.
@date 2026-07-14
@copyright Part of the https://github.com/Tapanhaz/cykit library.
"""

from libc.stdio cimport printf
from libcpp.string cimport string
from cpython.bytes cimport PyBytes_FromStringAndSize
from cykit.utils.compat cimport timespec_, clock_gettime_, usleep_, CLOCK_MONOTONIC_

from cykit.utils.signal_handler cimport (
    init_signal_handler,
    context_notify_fn,
    register_context_notify,
    unregister_context_notify,
    cleanup_signal_handler
)

from cykit.utils.msgbridge cimport (
    #SyncDispatcher, 
    #AsyncDispatcher, 
    CBufferView,
    MsgKind
)

import warnings


cdef inline const char* get_ctx_tag(SharedMemSystem* shmsys) nogil:
    if shmsys == NULL:
        return b"NULL"

    if shmsys.mode == RunningMode.SPMC:
        if shmsys.ctx.role == ProcessRole.Producer:
            return b"SPMC:PRODUCER"
        elif shmsys.ctx.role == ProcessRole.Consumer:
            return b"SPMC:CONSUMER"
    elif shmsys.mode == RunningMode.MPSC:
        if shmsys.ctx.role == ProcessRole.Producer:
            return b"MPSC:PRODUCER"
        elif shmsys.ctx.role == ProcessRole.Consumer:
            return b"MPSC:CONSUMER"
    elif shmsys.mode == RunningMode.MPMC:
        if shmsys.ctx.role == ProcessRole.Producer:
            return b"MPMC:PRODUCER"
        elif shmsys.ctx.role == ProcessRole.Consumer:
            return b"MPMC:CONSUMER"
    return b"UNKNOWN"

cdef inline size_t ceil_align(size_t off) nogil:
    return ((off + ALIGN_BYTES - 1) // ALIGN_BYTES) * ALIGN_BYTES

cdef inline size_t ceil_align_custom(size_t off, size_t alignment) nogil:
    return ((off + alignment - 1) // alignment) * alignment

cdef inline int64_t _elapsed_ms(timespec_* start, timespec_* now) noexcept nogil:
    return (now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) // 1000000

cdef inline size_t calculate_shared_data_size(uint32_t block_count, uint32_t block_size) nogil:
    cdef:
        size_t base_size = sizeof(SharedDataImpl)
        size_t seq_array_size = block_count * sizeof(SlotSeq)
        size_t reader_array_size = <size_t>MAX_CONSUMERS * sizeof(ReaderSlot)
        
        size_t slot_stride = ceil_align_custom(block_size, CACHELINE)
        size_t total_payload_size = block_count * slot_stride

    base_size = ceil_align_custom(base_size, CACHELINE)
    seq_array_size = ceil_align_custom(seq_array_size, CACHELINE)
    reader_array_size = ceil_align_custom(reader_array_size, CACHELINE)

    return base_size + seq_array_size + reader_array_size + total_payload_size

cdef inline size_t _sd_base_offset() nogil:
    return ceil_align_custom(sizeof(SharedDataImpl), CACHELINE)

cdef inline SlotSeq* get_slot_sequences_ptr(SharedDataImpl* sd) nogil:
    return <SlotSeq*>(<char*>sd + _sd_base_offset())

cdef inline ReaderSlot* get_reader_slots_ptr(SharedDataImpl* sd, uint32_t block_count) nogil:
    cdef size_t off = _sd_base_offset() + ceil_align_custom(block_count * sizeof(SlotSeq), CACHELINE)
    return <ReaderSlot*>(<char*>sd + off)

cdef inline char* get_buffer_ptr(SharedDataImpl* sd, uint32_t block_count, uint32_t idx, uint32_t block_size) nogil:
    cdef size_t off = (
        _sd_base_offset()
        + ceil_align_custom(block_count * sizeof(SlotSeq), CACHELINE)
        + ceil_align_custom(<size_t>MAX_CONSUMERS * sizeof(ReaderSlot), CACHELINE)
        + <size_t>idx * ceil_align_custom(block_size, CACHELINE)
    )
    return <char*>sd + off

cdef inline void update_spmc_reader_min_position(SharedDataImpl* sd, ReaderSlot* r_slots) noexcept nogil:
    cdef:
        uint64_t mask = sd.reader_active_mask.value.load(memory_order.memory_order_acquire)
        uint64_t min_pos = 0
        uint64_t pos
        int i
        bint found = False
        cbool lag_evict = (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_LAG_EVICT) != 0

    if not lag_evict:
        while mask:
            i = builtin_ctzll(mask)
            pos = r_slots[i].pos.value.load(memory_order.memory_order_acquire)
            if not found or pos < min_pos:
                min_pos = pos
                found = True
            mask &= mask - 1

        if not found:
            min_pos = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        sd.reader_min_position.value.store(min_pos, memory_order.memory_order_release)
        return
    
    cdef:
        uint64_t min1, min2, bit, flagged, threshold, cur
        uint64_t min1_bit = 0
        int min1_idx = -1
    
    min1 = 0
    min2 = 0xFFFFFFFFFFFFFFFFULL
    threshold = <uint64_t>sd.block_count // LAG_EVICT_DIVISOR

    while mask:
        i = builtin_ctzll(mask)
        bit = (<uint64_t>1) << i
        pos = r_slots[i].pos.value.load(memory_order.memory_order_acquire)
        if not found or pos < min1:
            if found:
                min2 = min1
            min1 = pos
            min1_bit = bit
            min1_idx = i
            found = True
        elif pos < min2:
            min2 = pos
        mask &= mask - 1

    if not found:
        min1 = sd.global_sequence.value.load(memory_order.memory_order_acquire)
        sd.reader_min_position.value.store(min1, memory_order.memory_order_release)
        return

    if min2 == 0xFFFFFFFFFFFFFFFFULL or (min2 - min1) < threshold:
        sd.reader_min_position.value.store(min1, memory_order.memory_order_release)
        return

    flagged = r_slots[min1_idx].lag_flag_pos.value.load(memory_order.memory_order_relaxed)
    if flagged != min1:
        r_slots[min1_idx].lag_flag_pos.value.store(min1, memory_order.memory_order_relaxed)
        sd.reader_min_position.value.store(min1, memory_order.memory_order_release)
        return

    if (min2 - min1) < 2 * threshold:
        sd.reader_min_position.value.store(min1, memory_order.memory_order_release)
        return

    cur = sd.reader_active_mask.value.load(memory_order.memory_order_acquire)
    while True:
        if atomic_compare_exchange_strong_explicit(
            &sd.reader_active_mask.value, &cur, cur & ~min1_bit,
            memory_order.memory_order_acq_rel,
            memory_order.memory_order_relaxed
        ):
            break
    sd.notify_cond.notify_all()
    sd.reader_min_position.value.store(min2, memory_order.memory_order_release)


# =========================================================================
# ============================   INITIALIZATION    ========================
# =========================================================================

    
cdef int init_shared_memory(SharedMemSystem* shmsys) except -1 nogil:
    cdef:
        bint is_first = False
        scoped_lock lock
        uint32_t i
        uint32_t magic
        bint init_complete
        int wait_iterations = 0
        int max_wait_iterations = 50
        size_t shm_size = calculate_shared_data_size(shmsys.block_count, shmsys.block_size)
        int proc_count = 0
        SlotSeq* seq_arr
        ReaderSlot* r_arr 
    
    with gil:
        try:
            shmsys.ctx.shm_obj = create_shared_memory(shmsys.shm_name, shm_size)
        except Exception as e:
            printf(b"[%s:INIT] Failed to create/open shared memory\n", get_ctx_tag(shmsys))
            return -1

    shmsys.ctx.sd = <SharedDataImpl*>shmsys.ctx.shm_obj.get_address()
    if shmsys.ctx.sd == NULL:
        printf(b"[%s:INIT] ERROR: Failed to acquire shared address\n", get_ctx_tag(shmsys))
        return -1

    is_first = shmsys.ctx.shm_obj.is_creator()
    magic = shmsys.ctx.shm_obj.get_magic()
    
    if is_first:
        memset(<void*>shmsys.ctx.sd, 0, shm_size)

        shmsys.ctx.sd.mode = <uint32_t>shmsys.mode
        shmsys.ctx.sd.block_count = shmsys.block_count
        shmsys.ctx.sd.block_size = shmsys.block_size
        shmsys.ctx.sd.slot_stride = <uint32_t>ceil_align_custom(shmsys.block_size, CACHELINE)

        init_atomic_uint32(&shmsys.ctx.sd.magic_number, 0)
        init_atomic_int   (&shmsys.ctx.sd.process_count, 0)
        init_atomic_bool  (&shmsys.ctx.sd.sem_initialized, False)
        init_atomic_int   (&shmsys.ctx.sd.writer_count, 0)
        init_atomic_bool  (&shmsys.ctx.sd.writer_active, False)
        init_atomic_bool  (&shmsys.ctx.sd.consumer_active, False)
        init_atomic_bool  (&shmsys.ctx.sd.consumer_waiting, False)
        init_atomic_uint32(&shmsys.ctx.sd.shared_flags, 0)
        if shmsys.lag_evict:
            shmsys.ctx.sd.shared_flags.fetch_or(
                <uint32_t>F_IPC_LAG_EVICT, memory_order.memory_order_relaxed
            )

        shmsys.ctx.sd.magic_number.store(0, memory_order.memory_order_relaxed)
        init_atomic_uint64(&shmsys.ctx.sd.global_sequence.value,      INITIAL_SEQUENCE)
        init_atomic_uint64(&shmsys.ctx.sd.consumer_sequence.value,    INITIAL_SEQUENCE)
        init_atomic_uint64(&shmsys.ctx.sd.reader_min_position.value,  INITIAL_SEQUENCE)
        init_atomic_uint64(&shmsys.ctx.sd.reader_active_mask.value,   0)

        init_interprocess_mutex(&shmsys.ctx.sd.notify_mutex)
        init_interprocess_condition(&shmsys.ctx.sd.notify_cond)

        seq_arr = get_slot_sequences_ptr(shmsys.ctx.sd)
        for i in range(shmsys.block_count):
            init_atomic_uint64(
                &seq_arr[i].seq.value,
                <uint64_t>shmsys.block_count if i == 0 else <uint64_t>i
            )
        
        r_arr = get_reader_slots_ptr(shmsys.ctx.sd, shmsys.block_count)
        for i in range(<uint32_t>MAX_CONSUMERS):
            init_atomic_uint64(&r_arr[i].pos.value, INITIAL_SEQUENCE)
            init_atomic_uint64(&r_arr[i].lag_flag_pos.value, 0xFFFFFFFFFFFFFFFFULL)
        
        atomic_thread_fence(memory_order.memory_order_seq_cst)
        shmsys.ctx.shm_obj.mark_init_complete()
        shmsys.ctx.shm_obj.set_magic(MAGIC_INITIALIZED)
        shmsys.ctx.sd.notify_cond.notify_all()
        
    else:
        while True:
            magic = shmsys.ctx.shm_obj.get_magic()
            if magic == MAGIC_INITIALIZED:
                break
            elif magic == MAGIC_FINALIZING:
                return -2
            cpu_pause()

        lock = scoped_lock(shmsys.ctx.sd.notify_mutex)
        if not shmsys.ctx.shm_obj.is_init_complete():
            cond_wait(&shmsys.ctx.sd.notify_cond, &lock)
        lock.unlock()

        if shmsys.ctx.sd.block_count != shmsys.block_count or \
           shmsys.ctx.sd.block_size != shmsys.block_size:
            printf(b"[%s:INIT] ERROR: Shared configuration layout mismatch!\n", get_ctx_tag(shmsys))
            return -1
        
    shmsys.ctx.slot_sequences = get_slot_sequences_ptr(shmsys.ctx.sd)
    shmsys.ctx.reader_slots = get_reader_slots_ptr(shmsys.ctx.sd, shmsys.block_count)
    shmsys.ctx.slot_buffers = get_buffer_ptr(shmsys.ctx.sd, shmsys.block_count, 0, shmsys.block_size)

    if shmsys.ctx.sd.shared_flags.load(memory_order.memory_order_acquire) & F_IPC_CLOSING:
        return IPC_CLOSING

    if shmsys.ctx.role == ProcessRole.Producer:
        if shmsys.mode == RunningMode.SPMC:
            if not shmsys.ctx.shm_obj.try_acquire_writer():
                return -1
        else:
            shmsys.ctx.shm_obj.increment_writer_count()
    else:
        if shmsys.mode == RunningMode.MPSC:
            if not shmsys.ctx.shm_obj.try_acquire_reader():
                return -1

    shmsys.ctx.sd.process_count.fetch_add(1, memory_order.memory_order_acq_rel)
    return 0


cdef int init_shared_memory_with_retry(SharedMemSystem* shmsys) nogil:
    cdef:
        int result
        int retry_count = 0
        int max_retries = 5
        int stale
    
    while retry_count < max_retries:
        stale = cleanup_orphan_memory(shmsys.shm_name, shmsys.sem_name)
        if stale == 1:
            printf(b"[%s:INIT] Orphaned memory detected .. \n", get_ctx_tag(shmsys))
            usleep_(50000)
            if shmsys.ctx.shm_obj != NULL:
                with gil:
                    del shmsys.ctx.shm_obj
                shmsys.ctx.shm_obj = NULL
        result = init_shared_memory(shmsys)
        if result == 0:            
            return 0
        elif result == -2:
            if shmsys.ctx.shm_obj != NULL:
                with gil:
                    del shmsys.ctx.shm_obj
                shmsys.ctx.shm_obj = NULL
            printf(b"[%s:INIT] Attempt %d/%d - cleanup detected, retrying...\n", 
                   get_ctx_tag(shmsys), retry_count + 1, max_retries)
            retry_count += 1
            usleep_(200000)
            
        else:
            if shmsys.ctx.shm_obj != NULL:
                with gil:
                    del shmsys.ctx.shm_obj
                shmsys.ctx.shm_obj = NULL
            retry_count += 1
            if retry_count >= max_retries:
                printf(b"[%s:INIT] Fatal error during initialization\n", get_ctx_tag(shmsys))
                return -1
            printf(b"[%s:INIT] Attempt %d/%d - join race detected, retrying...\n",
                   get_ctx_tag(shmsys), retry_count, max_retries)
            usleep_(50000)
    return -1


cdef int init_producer_system(SharedMemSystem* shmsys) except -1 nogil:    
    if init_shared_memory_with_retry(shmsys) != 0:
        return -1
        
    shmsys.ctx.process_alive.store(1, memory_order.memory_order_relaxed)
    
    with gil:
        try:
            shmsys.ctx.sem_obj = create_semaphore(shmsys.sem_name)
        except:
            printf(b"[%s:INIT] Failed to create semaphore\n", get_ctx_tag(shmsys))
            return -1
    
    shmsys.ctx.sd.sem_initialized.store(True, memory_order.memory_order_release)
    return 0


cdef int init_consumer_system(SharedMemSystem* shmsys) except -1 nogil:
    if init_shared_memory_with_retry(shmsys) != 0:
        return -1
         
    shmsys.ctx.process_alive.store(1, memory_order.memory_order_relaxed)
    
    with gil:
        try:
            shmsys.ctx.sem_obj = create_semaphore(shmsys.sem_name)
        except:
            printf(b"[%s:INIT] Failed to create semaphore\n", get_ctx_tag(shmsys))
            return -1
    
    shmsys.ctx.sd.consumer_active.store(True, memory_order.memory_order_release)

    shmsys.ctx.scratch_buf = <char*>malloc(shmsys.block_size)
    if shmsys.ctx.scratch_buf == NULL:
        printf(b"[%s:INIT] OOM for scratch_buf\n", get_ctx_tag(shmsys))
        return -1
    shmsys.ctx.scratch_cap = shmsys.block_size

    cdef uint64_t mask, bit
    cdef int rid

    mask = shmsys.ctx.sd.reader_active_mask.value.load(memory_order.memory_order_acquire)
    while True:
        rid = builtin_ctzll(~mask)
        bit = (<uint64_t>1) << rid
        if atomic_compare_exchange_strong_explicit(
            &shmsys.ctx.sd.reader_active_mask.value, &mask, mask | bit,
            memory_order.memory_order_acq_rel,
            memory_order.memory_order_relaxed
        ):
            break

    shmsys.ctx.reader_id = <uint32_t>rid
    shmsys.ctx.reader_slots[rid].pos.value.store(
        shmsys.ctx.sd.global_sequence.value.load(memory_order.memory_order_acquire),
        memory_order.memory_order_release
    )
    shmsys.ctx.reader_slots[rid].lag_flag_pos.value.store(
        0xFFFFFFFFFFFFFFFFULL, memory_order.memory_order_relaxed
    )
    update_spmc_reader_min_position(shmsys.ctx.sd, shmsys.ctx.reader_slots)

    atomic_thread_fence(memory_order.memory_order_seq_cst)
    shmsys.ctx.sd.notify_cond.notify_all()
    
    return 0

cdef inline void notify_context(void* ctx_ptr) noexcept nogil:
    cdef Context* ctx = <Context*>ctx_ptr

    
    printf(b"Shutting Down .. please wait")

    if ctx == NULL:
        return

    ctx.local_flags |= F_IPC_CLOSING
    ctx.running = 0
    if ctx and ctx.sd:
        ctx.sd.notify_cond.notify_all()


cdef void cleanup_consumer_system(SharedMemSystem* shmsys) noexcept nogil:
    cdef:
        uint64_t mask, bit
        uint32_t rid = shmsys.ctx.reader_id

    if shmsys.ctx.sd == NULL:
        return
    if shmsys.ctx.scratch_buf != NULL:
        free(shmsys.ctx.scratch_buf)
        shmsys.ctx.scratch_buf = NULL

    bit = (<uint64_t>1) << rid
    while True:
        mask = shmsys.ctx.sd.reader_active_mask.value.load(
            memory_order.memory_order_acquire
        )
        if atomic_compare_exchange_strong_explicit(
            &shmsys.ctx.sd.reader_active_mask.value,
            &mask, mask & ~bit,
            memory_order.memory_order_acq_rel,
            memory_order.memory_order_relaxed
        ):
            break

    update_spmc_reader_min_position(shmsys.ctx.sd, shmsys.ctx.reader_slots)

    shmsys.ctx.sd.notify_cond.notify_all()

    if shmsys.mode == RunningMode.SPMC:
        pass 
    elif shmsys.mode == RunningMode.MPSC:
        shmsys.ctx.shm_obj.release_reader()
    elif shmsys.mode == RunningMode.MPMC:
        shmsys.ctx.shm_obj.decrement_reader_count()

    shmsys.ctx.sd.process_count.fetch_sub(1, memory_order.memory_order_acq_rel)
    if shmsys.mode == RunningMode.MPSC:
        shmsys.ctx.sd.consumer_active.store(False, memory_order.memory_order_release)

cdef int cleanup_producer_system(SharedMemSystem* shmsys) noexcept nogil:
    cdef int remaining

    if shmsys.ctx.sd == NULL:
        return 0
    
    shmsys.ctx.running = 0
    shmsys.ctx.local_flags |= F_IPC_CLOSING

    if shmsys.mode == RunningMode.SPMC:
        shmsys.ctx.shm_obj.release_writer()
        remaining = 0
    else:
        remaining = shmsys.ctx.shm_obj.decrement_writer_count()

    shmsys.ctx.sd.process_count.fetch_sub(1, memory_order.memory_order_acq_rel)

    shmsys.ctx.sd.notify_cond.notify_all()
    return remaining


# =========================================================================
# ======================    SHUTDOWN PRIMITIVES    ========================
# =========================================================================

cdef inline bint _all_consumers_drained(
    SharedDataImpl* sd, ReaderSlot* r_slots, uint64_t mask, uint64_t target
) noexcept nogil:
    cdef uint64_t m = mask
    cdef int i
    while m:
        i = builtin_ctzll(m)
        if r_slots[i].pos.value.load(memory_order.memory_order_acquire) < target:
            return False
        m &= m - 1
    return True

cdef inline bint _global_drained(SharedMemSystem* shmsys) noexcept nogil:
    cdef Context* c = shmsys.ctx
    if shmsys.mode == RunningMode.MPSC:
        return c.sd.consumer_sequence.value.load(memory_order.memory_order_acquire) == \
               c.sd.global_sequence.value.load(memory_order.memory_order_acquire)
    return c.sd.reader_active_mask.value.load(memory_order.memory_order_acquire) == 0


cdef inline bint _mpsc_drained(SharedDataImpl* sd) noexcept nogil:
    return sd.consumer_sequence.value.load(
        memory_order.memory_order_acquire
    ) == sd.global_sequence.value.load(memory_order.memory_order_acquire)


cdef int _mpsc_drain(SharedMemSystem* shmsys, long budget_ms, long stall_ms = 2000) noexcept nogil:
    cdef:
        Context* c = shmsys.ctx
        SharedDataImpl* sd = c.sd
        uint64_t t, idx, tail, spins
        timespec_ outer_start, slot_start, now
        bint orphaned
        int ret = IPC_OK

    clock_gettime_(CLOCK_MONOTONIC_, &outer_start)

    while True:
        t    = sd.consumer_sequence.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if t == tail:
            #return IPC_OK
            break

        idx = t & (sd.block_count - 1)
        spins = 0
        orphaned = False
        clock_gettime_(CLOCK_MONOTONIC_, &slot_start)

        while c.slot_sequences[idx].seq.value.load(
            memory_order.memory_order_acquire
        ) != t + 1:
            spins += 1
            if spins & 0x3FF == 0:
                if not shmsys.ctx.shm_obj.has_other_live_attachers():
                    orphaned = True
                    break
                if stall_ms >= 0:
                    clock_gettime_(CLOCK_MONOTONIC_, &now)
                    if _elapsed_ms(&slot_start, &now) >= <int64_t>stall_ms:
                        orphaned = True
                        break
            cpu_pause()

        _sc_recycle(c, idx, t)
        if orphaned:
            printf(b"[%s:DETACH] slot abandoned, seq=%llu (claimant stuck/dead)\n",
                   get_ctx_tag(shmsys), <unsigned long long>t)

        if budget_ms >= 0:
            clock_gettime_(CLOCK_MONOTONIC_, &now)
            if _elapsed_ms(&outer_start, &now) >= <int64_t>budget_ms:
                #return IPC_DRAIN_TIMEOUT
                ret= IPC_DRAIN_TIMEOUT
                break
    return ret


cdef int _fanout_drain(SharedMemSystem* shmsys, long budget_ms, long stall_ms = 2000) noexcept nogil:
    cdef:
        Context* c = shmsys.ctx
        SharedDataImpl* sd = c.sd
        uint32_t rid = c.reader_id
        uint64_t pos, tail, idx, spins
        timespec_ outer_start, slot_start, now
        bint orphaned
        int ret = IPC_OK

    clock_gettime_(CLOCK_MONOTONIC_, &outer_start)

    while True:
        pos  = c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            #return IPC_OK
            break

        idx = pos & (sd.block_count - 1)
        orphaned = False
        spins = 0
        clock_gettime_(CLOCK_MONOTONIC_, &slot_start)

        while not _spmc_slot_ready(c, idx, pos):
            spins += 1
            if spins & 0x3FF == 0:
                if not shmsys.ctx.shm_obj.has_other_live_attachers():
                    orphaned = True
                    break
                if stall_ms >= 0:
                    clock_gettime_(CLOCK_MONOTONIC_, &now)
                    if _elapsed_ms(&slot_start, &now) >= <int64_t>stall_ms:
                        orphaned = True
                        break
            cpu_pause()

        if orphaned:
            printf(b"[%s:DETACH] slot abandoned, pos=%llu (claimant stuck/dead)\n",
                   get_ctx_tag(shmsys), <unsigned long long>pos)

        _spmc_advance(c, rid, pos + 1)

        if budget_ms >= 0:
            clock_gettime_(CLOCK_MONOTONIC_, &now)
            if _elapsed_ms(&outer_start, &now) >= <int64_t>budget_ms:
                #return IPC_DRAIN_TIMEOUT
                ret= IPC_DRAIN_TIMEOUT
                break
    return ret


cdef inline bint _fanout_all_drained_live(
    SharedDataImpl* sd, ReaderSlot* r_slots, uint64_t target
) noexcept nogil:
    cdef uint64_t mask = sd.reader_active_mask.value.load(memory_order.memory_order_acquire)
    cdef int i
    while mask:
        i = builtin_ctzll(mask)
        if r_slots[i].pos.value.load(memory_order.memory_order_acquire) < target:
            return False
        mask &= mask - 1
    return True

cdef inline void _signal_abort(SharedDataImpl* sd) noexcept nogil:
    sd.shared_flags.fetch_or(<uint32_t>F_IPC_ABORT, memory_order.memory_order_acq_rel)
    sd.notify_cond.notify_all()

cdef int detach_producer(SharedMemSystem* shmsys) noexcept nogil:
    return cleanup_producer_system(shmsys)

cdef int detach_consumer(
    SharedMemSystem* shmsys,
    long timeout_ms = 0,
    long close_signal_wait_ms = 3000,
    long stall_ms = 2000
) noexcept nogil:
    cdef:
        Context*        ctx = shmsys.ctx
        SharedDataImpl* sd  = ctx.sd
        timespec_       t_start, t_now
        bint            seen_closing

    if sd == NULL:
        return IPC_OK

    ctx.running = 0

    if timeout_ms == 0:
        cleanup_consumer_system(shmsys)
        return IPC_OK

    elif timeout_ms == -1:
        if close_signal_wait_ms == -1:
            seen_closing = True

        elif close_signal_wait_ms == 0:
            seen_closing = (sd.shared_flags.load(memory_order.memory_order_acquire) & F_IPC_CLOSING) != 0

        else: 
            clock_gettime_(CLOCK_MONOTONIC_, &t_start)
            seen_closing = False
            while True:
                if sd.shared_flags.load(memory_order.memory_order_acquire) & F_IPC_CLOSING:
                    seen_closing = True
                    break
                clock_gettime_(CLOCK_MONOTONIC_, &t_now)
                if _elapsed_ms(&t_start, &t_now) >= <int64_t>close_signal_wait_ms:
                    break
                usleep_(5000)

        if seen_closing:
            if shmsys.mode == RunningMode.MPSC:
                _mpsc_drain(shmsys, -1, -1 if close_signal_wait_ms == -1 else stall_ms)
            else:
                _fanout_drain(shmsys, -1, -1 if close_signal_wait_ms == -1 else stall_ms)

        cleanup_consumer_system(shmsys)
        return IPC_OK if seen_closing else IPC_DRAIN_TIMEOUT

    else: 
        if shmsys.mode == RunningMode.MPSC:
            _mpsc_drain(shmsys, timeout_ms, stall_ms)
        else:
            _fanout_drain(shmsys, timeout_ms, stall_ms)
        cleanup_consumer_system(shmsys)
        return IPC_OK


cdef int shutdown_pipeline(
    SharedMemSystem* shmsys,
    long timeout_ms = 0
) noexcept nogil:
    cdef:
        Context*        ctx = shmsys.ctx
        SharedDataImpl* sd  = ctx.sd
        uint64_t        drain_target
        timespec_       t_start, t_now
        scoped_lock     lock

    if sd == NULL:
        return IPC_OK

    lock = scoped_lock(sd.notify_mutex)
    sd.shared_flags.fetch_or(<uint32_t>F_IPC_CLOSING, memory_order.memory_order_acq_rel)
    sd.notify_cond.notify_all()
    lock.unlock()

    if timeout_ms == 0:
        _signal_abort(sd)
        return IPC_OK

    if timeout_ms > 0:
        clock_gettime_(CLOCK_MONOTONIC_, &t_start)

    if shmsys.mode == RunningMode.MPSC:
        while not _mpsc_drained(sd):
            if sd.reader_active_mask.value.load(memory_order.memory_order_acquire) == 0:
                _signal_abort(sd)
                return IPC_DRAIN_TIMEOUT
            if timeout_ms > 0:
                clock_gettime_(CLOCK_MONOTONIC_, &t_now)
                if _elapsed_ms(&t_start, &t_now) >= <int64_t>timeout_ms:
                    _signal_abort(sd)
                    return IPC_DRAIN_TIMEOUT
            usleep_(5000)
        _signal_abort(sd)
        return IPC_OK

    else: 
        drain_target = sd.global_sequence.value.load(memory_order.memory_order_acquire)
        while not _fanout_all_drained_live(sd, ctx.reader_slots, drain_target):
            if timeout_ms > 0:
                clock_gettime_(CLOCK_MONOTONIC_, &t_now)
                if _elapsed_ms(&t_start, &t_now) >= <int64_t>timeout_ms:
                    _signal_abort(sd)
                    return IPC_DRAIN_TIMEOUT
            usleep_(5000)
        _signal_abort(sd)
        return IPC_OK


cdef int shm_close(
    SharedMemSystem* shmsys,
    long timeout_ms = 0,
    long close_signal_wait_ms = 3000
) noexcept nogil:
    cdef:
        Context*        ctx   = shmsys.ctx
        SharedDataImpl* sd    = ctx.sd
        timespec_       t_start, t_now
        long            elapsed
        uint64_t        drain_target, reg_mask

    if not ctx.running:
        return IPC_OK

    ctx.local_flags |= F_IPC_CLOSING
    ctx.running = 0

    if ctx.role == ProcessRole.Producer:
        sd.shared_flags.fetch_or(
            <uint32_t>F_IPC_CLOSING, memory_order.memory_order_relaxed
        )
        sd.notify_cond.notify_all()

        if timeout_ms == 0:
            return IPC_OK

        if shmsys.mode == RunningMode.SPMC or shmsys.mode == RunningMode.MPMC:
            drain_target = sd.global_sequence.value.load(memory_order.memory_order_acquire)
            reg_mask     = sd.reader_active_mask.value.load(memory_order.memory_order_acquire)

            if reg_mask == 0:
                return IPC_OK 

            if timeout_ms == -1:
                while not _all_consumers_drained(sd, ctx.reader_slots, reg_mask, drain_target):
                    usleep_(5000)
                return IPC_OK
            else:
                clock_gettime_(CLOCK_MONOTONIC_, &t_start)
                while not _all_consumers_drained(sd, ctx.reader_slots, reg_mask, drain_target):
                    clock_gettime_(CLOCK_MONOTONIC_, &t_now)
                    if _elapsed_ms(&t_start, &t_now) >= <int64_t>timeout_ms:
                        return IPC_DRAIN_TIMEOUT
                    usleep_(5000)
                return IPC_OK

        else:
            if timeout_ms == -1:
                while not _mpsc_drained(sd):
                    usleep_(5000)
                return IPC_OK
            else:
                clock_gettime_(CLOCK_MONOTONIC_, &t_start)
                while not _mpsc_drained(sd):
                    clock_gettime_(CLOCK_MONOTONIC_, &t_now)
                    if _elapsed_ms(&t_start, &t_now) >= <int64_t>timeout_ms:
                        return IPC_DRAIN_TIMEOUT
                    usleep_(5000)
                return IPC_OK

    else: 
        if timeout_ms == -1:
            clock_gettime_(CLOCK_MONOTONIC_, &t_start)
            while not (sd.shared_flags.load(
                memory_order.memory_order_acquire
            ) & F_IPC_CLOSING):
                clock_gettime_(CLOCK_MONOTONIC_, &t_now)
                if _elapsed_ms(&t_start, &t_now) >= <int64_t>close_signal_wait_ms:
                    return IPC_DRAIN_TIMEOUT
                usleep_(5000)
            return IPC_OK

        return IPC_OK

# =========================================================================
# ======================    QUEUE HELPERS    ==============================
# =========================================================================

cdef inline char* _slot(Context* c, uint64_t idx) noexcept nogil:
    return c.slot_buffers + idx * c.sd.slot_stride

cdef inline void _stage_slot(Context* c, char* src, size_t size) noexcept nogil:
    memcpy(c.scratch_buf, src, size)

cdef inline void _write_fixed_hdr(char* slot, uint32_t size) noexcept nogil:
    (<uint32_t*>slot)[0] = htonl(size)
    (<uint32_t*>(slot + 4))[0] = 0

cdef inline void _write_var_hdr(
    char* slot, uint32_t chunk_size, uint16_t chunk_idx, uint16_t total_chunks
) noexcept nogil:
    (<uint32_t*>slot)[0]       = htonl(chunk_size)
    (<uint32_t*>(slot + 4))[0] = htonl(
        (<uint32_t>chunk_idx << 16) | <uint32_t>total_chunks
    )

cdef inline void _read_fixed_hdr(char* slot, size_t* out_size) noexcept nogil:
    out_size[0] = <size_t>ntohl((<uint32_t*>slot)[0])

cdef inline void _read_var_hdr(
    char* slot, size_t* chunk_size, uint16_t* chunk_idx, uint16_t* total_chunks
) noexcept nogil:
    cdef uint32_t hdr = ntohl((<uint32_t*>(slot + 4))[0])
    chunk_size[0]    = <size_t>ntohl((<uint32_t*>slot)[0])
    chunk_idx[0]     = <uint16_t>(hdr >> 16)
    total_chunks[0]  = <uint16_t>(hdr & 0xFFFF)

cdef inline bint _assemble(
    Context* c, char* payload, size_t chunk_size,
    uint16_t chunk_idx, uint16_t total_chunks,
    char** out_buf, size_t* out_size
) noexcept nogil:
    cdef:
        size_t needed
        char*  tmp

    if chunk_idx != c.expected_chunk:
        if chunk_idx == 0:
            c.expected_chunk = 0
            c.assemble_used  = 0
        else:
            return False

    needed = c.assemble_used + chunk_size
    if needed > c.assemble_cap:
        tmp = <char*>realloc(c.assemble_buf, needed * 2)
        if tmp == NULL:
            return False
        c.assemble_buf = tmp
        c.assemble_cap = needed * 2

    memcpy(c.assemble_buf + c.assemble_used, payload, chunk_size)
    c.assemble_used  += chunk_size
    c.expected_chunk += 1

    if c.expected_chunk == total_chunks:
        out_buf[0]       = c.assemble_buf
        out_size[0]      = c.assemble_used
        c.assemble_used  = 0
        c.expected_chunk = 0
        return True

    return False

cdef inline void _reset_assemble(Context* c) noexcept nogil:
    c.expected_chunk = 0
    c.assemble_used  = 0

# =========================================================================
# ===========================    SPMC PUSH    =============================
# =========================================================================

# SPMC PUSH HELPERS ============================================================

cdef inline bint _spmc_has_space(
    SharedDataImpl* sd, uint64_t tail, uint32_t n_slots
) noexcept nogil:
    return tail - sd.reader_min_position.value.load(
        memory_order.memory_order_acquire
    ) + n_slots <= sd.block_count

cdef inline bint _spmc_has_consumers(SharedDataImpl* sd) noexcept nogil:
    return sd.reader_active_mask.value.load(
        memory_order.memory_order_acquire
    ) != 0


# SPMC PUSH ====================================================================

cdef int ipc_spmc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        tail, idx
        char*           slot
        scoped_lock     lock
        size_t          payload_cap = sd.block_size - 8

    if (c.local_flags & F_IPC_CLOSING) or \
       (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if size > payload_cap:
        size = payload_cap

    while c.running:
        if not _spmc_has_consumers(sd):
            if c.local_flags & F_IPC_WAIT_CONSUMERS:
                lock = scoped_lock(sd.notify_mutex)
                if not _spmc_has_consumers(sd) and \
                   not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                    cond_wait(&sd.notify_cond, &lock)
                lock.unlock()
                if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
                continue
            return IPC_NO_CONSUMER

        tail = sd.global_sequence.value.load(memory_order.memory_order_relaxed)

        if not _spmc_has_space(sd, tail, 1):
            if c.local_flags & F_IPC_BLOCK_ON_FULL:
                lock = scoped_lock(sd.notify_mutex)
                if not _spmc_has_space(
                    sd,
                    sd.global_sequence.value.load(memory_order.memory_order_relaxed),
                    1
                ) and not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                    cond_wait(&sd.notify_cond, &lock)
                lock.unlock()
                if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
                continue
            elif c.local_flags & F_IPC_OVERWRITE:
                sd.reader_min_position.value.fetch_add(
                    1, memory_order.memory_order_acq_rel
                )
            else:
                return IPC_FULL

        idx  = tail & (sd.block_count - 1)
        slot = _slot(c, idx)

        _write_fixed_hdr(slot, <uint32_t>size)
        memcpy(slot + 8, data, size)

        atomic_thread_fence(memory_order.memory_order_release)
        c.slot_sequences[idx].seq.value.store(tail + 1, memory_order.memory_order_release)
        sd.global_sequence.value.store(tail + 1, memory_order.memory_order_release)
        sd.notify_cond.notify_all()
        return IPC_OK

    return IPC_CLOSING


cdef int ipc_spmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        tail, idx
        char*           slot
        size_t          payload_cap = sd.block_size - 8

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING
    if not _spmc_has_consumers(sd):
        return IPC_NO_CONSUMER

    tail = sd.global_sequence.value.load(memory_order.memory_order_relaxed)

    if not _spmc_has_space(sd, tail, 1):
        return IPC_FULL

    if size > payload_cap:
        size = payload_cap

    idx  = tail & (sd.block_count - 1)
    slot = _slot(c, idx)

    _write_fixed_hdr(slot, <uint32_t>size)
    memcpy(slot + 8, data, size)

    atomic_thread_fence(memory_order.memory_order_release)
    c.slot_sequences[idx].seq.value.store(tail + 1, memory_order.memory_order_release)
    sd.global_sequence.value.store(tail + 1, memory_order.memory_order_release)
    sd.notify_cond.notify_all()
    return IPC_OK


cdef int ipc_spmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        tail, idx
        char*           slot
        scoped_lock     lock
        size_t          payload_cap  = sd.block_size - 8
        size_t          remaining    = size
        uint16_t        total_chunks = <uint16_t>((size + payload_cap - 1) / payload_cap)
        uint16_t        chunk_idx    = 0
        size_t          chunk_size

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    for chunk_idx in range(total_chunks):
        while c.running:
            if (c.local_flags & F_IPC_CLOSING) or \
               (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
                return IPC_CLOSING

            if not _spmc_has_consumers(sd):
                if c.local_flags & F_IPC_WAIT_CONSUMERS:
                    lock = scoped_lock(sd.notify_mutex)
                    if not _spmc_has_consumers(sd) and \
                        not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                        cond_wait(&sd.notify_cond, &lock)
                    lock.unlock()
                    if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                        return IPC_CLOSING
                    continue
                return IPC_NO_CONSUMER

            tail = sd.global_sequence.value.load(memory_order.memory_order_relaxed)

            if not _spmc_has_space(sd, tail, 1):
                if c.local_flags & F_IPC_BLOCK_ON_FULL:
                    lock = scoped_lock(sd.notify_mutex)
                    if not _spmc_has_space(
                        sd,
                        sd.global_sequence.value.load(memory_order.memory_order_relaxed),
                        1
                    ) and not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                        cond_wait(&sd.notify_cond, &lock)
                    lock.unlock()
                    if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                        return IPC_CLOSING
                    continue
                else:
                    return IPC_FULL

            idx        = tail & (sd.block_count - 1)
            slot       = _slot(c, idx)
            chunk_size = remaining if remaining <= payload_cap else payload_cap

            _write_var_hdr(slot, <uint32_t>chunk_size, chunk_idx, total_chunks)
            memcpy(slot + 8, data + (size - remaining), chunk_size)
            remaining -= chunk_size

            atomic_thread_fence(memory_order.memory_order_release)
            c.slot_sequences[idx].seq.value.store(tail + 1, memory_order.memory_order_release)
            sd.global_sequence.value.store(tail + 1, memory_order.memory_order_release)
            sd.notify_cond.notify_all()
            break

        if not c.running:
            return IPC_CLOSING

    return IPC_OK


cdef int ipc_spmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        tail, idx
        char*           slot
        size_t          payload_cap  = sd.block_size - 8
        size_t          remaining    = size
        uint16_t        total_chunks = <uint16_t>((size + payload_cap - 1) / payload_cap)
        uint16_t        chunk_idx
        size_t          chunk_size

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING
    if not _spmc_has_consumers(sd):
        return IPC_NO_CONSUMER

    tail = sd.global_sequence.value.load(memory_order.memory_order_relaxed)

    if not _spmc_has_space(sd, tail, total_chunks):
        return IPC_FULL

    for chunk_idx in range(total_chunks):
        tail       = sd.global_sequence.value.load(memory_order.memory_order_relaxed)
        idx        = tail & (sd.block_count - 1)
        slot       = _slot(c, idx)
        chunk_size = remaining if remaining <= payload_cap else payload_cap

        _write_var_hdr(slot, <uint32_t>chunk_size, chunk_idx, total_chunks)
        memcpy(slot + 8, data + (size - remaining), chunk_size)
        remaining -= chunk_size

        atomic_thread_fence(memory_order.memory_order_release)
        c.slot_sequences[idx].seq.value.store(tail + 1, memory_order.memory_order_release)
        sd.global_sequence.value.store(tail + 1, memory_order.memory_order_release)
        sd.notify_cond.notify_all()

    return IPC_OK

# SPMC POP HELPERS============================================================================

cdef inline bint _spmc_slot_ready(
    Context* c, uint64_t idx, uint64_t pos
) noexcept nogil:
    return c.slot_sequences[idx].seq.value.load(
        memory_order.memory_order_acquire
    ) == pos + 1

cdef inline void _spmc_advance(
    Context* c, uint32_t rid, uint64_t new_pos
) noexcept nogil:
    c.reader_slots[rid].pos.value.store(new_pos, memory_order.memory_order_release)
    update_spmc_reader_min_position(c.sd, c.reader_slots)
    c.sd.notify_cond.notify_all()

cdef inline bint _abort_requested(Context* c) noexcept nogil:
    if not c.running:
        return True
    if c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
        c.running = 0
        return True
    return False

cdef inline bint _claimed_slot_orphaned(
    Context* c, timespec_* slot_start, cbool* timer_started
) noexcept nogil:
    cdef timespec_ now
    if not timer_started[0]:
        clock_gettime_(CLOCK_MONOTONIC_, slot_start)
        timer_started[0] = True
        return False
    if not c.shm_obj.has_other_live_attachers():
        printf(b"[POP] slot abandoned, producer dead\n")
        return True
    clock_gettime_(CLOCK_MONOTONIC_, &now)
    if _elapsed_ms(slot_start, &now) >= <int64_t>POP_ORPHAN_STALL_MS:
        printf(b"[POP] slot abandoned (stall)\n")
        return True
    return False


# SPMC POP ====================================================================================

cdef int ipc_spmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint32_t        rid  = c.reader_id
        uint64_t        pos, tail, idx, spins
        char*           slot
        scoped_lock     lock
        timespec_       slot_start
        cbool            timer_started
    
    if _abort_requested(c):
        return IPC_CLOSING

    while c.running:
        pos  = c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            lock = scoped_lock(sd.notify_mutex)
            if c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire) == \
               sd.global_sequence.value.load(memory_order.memory_order_acquire) and c.running and \
               not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            _abort_requested(c)
            continue

        idx = pos & (sd.block_count - 1)
        spins = 0
        timer_started = False

        while not _spmc_slot_ready(c, idx, pos):
            if _abort_requested(c):
                return IPC_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(c, &slot_start, &timer_started):
                _spmc_advance(c, rid, pos + 1)
                return IPC_ORPHANED
            cpu_pause()

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_fixed_hdr(slot, out_size)
        _stage_slot(c, slot + 8, out_size[0])
        out_buf[0] = c.scratch_buf

        _spmc_advance(c, rid, pos + 1)
        return IPC_OK

    return IPC_CLOSING


cdef int ipc_spmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint32_t        rid  = c.reader_id
        uint64_t        pos, tail, idx
        char*           slot

    if _abort_requested(c):
        return IPC_CLOSING

    pos  = c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire)
    tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

    if pos == tail:
        if _abort_requested(c):
            return IPC_CLOSING
        return IPC_EMPTY

    idx = pos & (sd.block_count - 1)

    if not _spmc_slot_ready(c, idx, pos):
        return IPC_EMPTY

    slot = _slot(c, idx)
    atomic_thread_fence(memory_order.memory_order_acquire)

    _read_fixed_hdr(slot, out_size)
    _stage_slot(c, slot + 8, out_size[0])
    out_buf[0] = c.scratch_buf

    _spmc_advance(c, rid, pos + 1)
    return IPC_OK



cdef int ipc_spmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint32_t        rid  = c.reader_id
        uint64_t        pos, tail, idx, spins
        char*           slot
        scoped_lock     lock
        timespec_       slot_start
        cbool            timer_started

    
    if _abort_requested(c):
        return IPC_CLOSING

    while c.running:
        pos  = c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            lock = scoped_lock(sd.notify_mutex)
            if c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire) == \
               sd.global_sequence.value.load(memory_order.memory_order_acquire) and c.running and \
               not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            _abort_requested(c)
            continue

        idx = pos & (sd.block_count - 1)
        spins = 0
        timer_started = False

        while not _spmc_slot_ready(c, idx, pos):
            if _abort_requested(c):
                return IPC_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(c, &slot_start, &timer_started):
                _spmc_advance(c, rid, pos + 1)
                return IPC_ORPHANED
            cpu_pause()

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_fixed_hdr(slot, out_size)
        out_buf[0] = slot + 8

        c.borrow_pos = pos
        c.borrow_idx = <uint32_t>idx
        return IPC_OK

    return IPC_CLOSING


cdef void ipc_spmc_pop_commit(void* ctx) noexcept nogil:
    cdef Context* c = <Context*>ctx
    _spmc_advance(c, c.reader_id, c.borrow_pos + 1)



cdef int ipc_spmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint32_t        rid          = c.reader_id
        uint64_t        pos, tail, idx, spins
        char*           slot
        scoped_lock     lock
        size_t          chunk_size
        uint16_t        chunk_idx, total_chunks
        bint            assemble_done
        timespec_       slot_start
        cbool            timer_started
    
    if _abort_requested(c):
        return IPC_CLOSING

    while c.running:
        pos  = c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            lock = scoped_lock(sd.notify_mutex)
            if c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire) == \
               sd.global_sequence.value.load(memory_order.memory_order_acquire) and c.running and \
               not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            _abort_requested(c)
            continue

        idx = pos & (sd.block_count - 1)
        spins = 0
        timer_started = False

        while not _spmc_slot_ready(c, idx, pos):
            if _abort_requested(c):
                return IPC_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(c, &slot_start, &timer_started):
                _reset_assemble(c)
                _spmc_advance(c, rid, pos + 1)
                return IPC_ORPHANED
            cpu_pause()

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_var_hdr(slot, &chunk_size, &chunk_idx, &total_chunks)
        assemble_done = _assemble(c, slot + 8, chunk_size, chunk_idx, total_chunks, out_buf, out_size)

        _spmc_advance(c, rid, pos + 1)

        if assemble_done:
            return IPC_OK

    return IPC_CLOSING


cdef int ipc_spmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint32_t        rid          = c.reader_id
        uint64_t        pos, tail, idx
        char*           slot
        size_t          chunk_size
        uint16_t        chunk_idx, total_chunks
        bint            assemble_done
        int ret = IPC_OK

    if _abort_requested(c):
        return IPC_CLOSING

    while True:
        pos  = c.reader_slots[rid].pos.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            if _abort_requested(c):
                #return IPC_CLOSING
                ret= IPC_CLOSING
                break
            #return IPC_EMPTY
            ret= IPC_EMPTY
            break

        idx = pos & (sd.block_count - 1)

        if not _spmc_slot_ready(c, idx, pos):
            #return IPC_EMPTY
            ret= IPC_EMPTY
            break

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_var_hdr(slot, &chunk_size, &chunk_idx, &total_chunks)
        assemble_done = _assemble(c, slot + 8, chunk_size, chunk_idx, total_chunks, out_buf, out_size)

        _spmc_advance(c, rid, pos + 1)

        if assemble_done:
            #return IPC_OK
            break

        if _abort_requested(c):
            #return IPC_CLOSING
            ret= IPC_CLOSING
            break
    return ret

# =========================================================================
# ============================    MPSC    =================================
# =========================================================================

cdef inline bint _mpsc_has_space(
    SharedDataImpl* sd, uint64_t tail, uint32_t n_slots
) noexcept nogil:
    return tail - sd.consumer_sequence.value.load(
        memory_order.memory_order_acquire
    ) + n_slots <= sd.block_count

cdef inline bint _mp_claim(
    SharedDataImpl* sd, uint32_t n_slots, uint64_t* out_tail
) noexcept nogil:
    cdef uint64_t t = sd.global_sequence.value.load(memory_order.memory_order_relaxed)
    #while True:
    #    if not _mpsc_has_space(sd, t, n_slots):
    #        return False
    while _mpsc_has_space(sd, t, n_slots):
        if atomic_compare_exchange_strong_explicit(
            &sd.global_sequence.value, &t, t + n_slots,
            memory_order.memory_order_acq_rel,
            memory_order.memory_order_relaxed
        ):
            out_tail[0] = t
            return True
    return False


cdef inline void _mp_wait_slot(
    Context* c, uint64_t idx, uint64_t tail
) noexcept nogil:
    cdef:
        SharedDataImpl* sd = c.sd
        scoped_lock lock

    while c.slot_sequences[idx].seq.value.load(
        memory_order.memory_order_acquire
    ) != tail:
        #if not c.running:
        #    return
        lock = scoped_lock(sd.notify_mutex)
        if c.slot_sequences[idx].seq.value.load(
            memory_order.memory_order_acquire         
        ) != tail:
             cond_wait(&sd.notify_cond, &lock)
        lock.unlock()


cdef inline void _mp_publish(
    Context* c, uint64_t idx, uint64_t tail
) noexcept nogil:
    atomic_thread_fence(memory_order.memory_order_release)
    c.slot_sequences[idx].seq.value.store(tail + 1, memory_order.memory_order_release)
    c.sd.notify_cond.notify_all()


cdef inline void _sc_recycle(
    Context* c, uint64_t idx, uint64_t pos
) noexcept nogil:
    c.slot_sequences[idx].seq.value.store(
        pos + c.sd.block_count, memory_order.memory_order_release
    )
    c.sd.consumer_sequence.value.store(pos + 1, memory_order.memory_order_release)
    c.sd.notify_cond.notify_all()

cdef inline bint _mpsc_has_consumer(SharedDataImpl* sd) noexcept nogil:
    return sd.consumer_active.load(memory_order.memory_order_acquire)

# MPSC PUSH ===========================================================================

cdef int ipc_mpsc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        tail, idx
        char*           slot
        scoped_lock     lock
        size_t          payload_cap = sd.block_size - 8
        cbool           claimed= False

    if (c.local_flags & F_IPC_CLOSING) or \
       (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if size > payload_cap:
        size = payload_cap

    while c.running:
        if (c.local_flags & F_IPC_CLOSING) or \
           (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
            return IPC_CLOSING
        if not _mpsc_has_consumer(sd):
            if c.local_flags & F_IPC_WAIT_CONSUMERS:
                lock = scoped_lock(sd.notify_mutex)
                if not _mpsc_has_consumer(sd) and \
                   not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                    cond_wait(&sd.notify_cond, &lock)
                lock.unlock()
                if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
                continue
            return IPC_NO_CONSUMER
        if _mp_claim(sd, 1, &tail):
            claimed= True
            break
        if c.local_flags & F_IPC_BLOCK_ON_FULL:
            lock = scoped_lock(sd.notify_mutex)
            if not _mpsc_has_space(sd, sd.global_sequence.value.load(
                memory_order.memory_order_relaxed
            ), 1) and not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                return IPC_CLOSING
            continue
        return IPC_FULL

    if not claimed:
        return IPC_CLOSING

    idx  = tail & (sd.block_count - 1)
    slot = _slot(c, idx)

    _mp_wait_slot(c, idx, tail)
    #if not c.running:
    #    return IPC_CLOSING

    _write_fixed_hdr(slot, <uint32_t>size)
    memcpy(slot + 8, data, size)
    _mp_publish(c, idx, tail)
    return IPC_OK


cdef int ipc_mpsc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        tail, idx
        char*           slot
        size_t          payload_cap = sd.block_size - 8

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if not _mpsc_has_consumer(sd): 
        return IPC_NO_CONSUMER

    if not _mp_claim(sd, 1, &tail):
        return IPC_FULL

    if size > payload_cap:
        size = payload_cap

    idx  = tail & (sd.block_count - 1)
    slot = _slot(c, idx)

    _mp_wait_slot(c, idx, tail)
    #if not c.running:
    #    return IPC_CLOSING

    _write_fixed_hdr(slot, <uint32_t>size)
    memcpy(slot + 8, data, size)
    _mp_publish(c, idx, tail)
    return IPC_OK


cdef int ipc_mpsc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        tail, idx
        char*           slot
        scoped_lock     lock
        size_t          payload_cap  = sd.block_size - 8
        size_t          remaining    = size
        uint16_t        total_chunks = <uint16_t>((size + payload_cap - 1) / payload_cap)
        uint16_t        chunk_idx
        size_t          chunk_size
        cbool           claimed= False

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if total_chunks == 0 or total_chunks > sd.block_count:
        return IPC_ERR 

    while c.running:
        if (c.local_flags & F_IPC_CLOSING) or \
           (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
            return IPC_CLOSING
        if not _mpsc_has_consumer(sd):
            if c.local_flags & F_IPC_WAIT_CONSUMERS:
                lock = scoped_lock(sd.notify_mutex)
                if not _mpsc_has_consumer(sd) and \
                   not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                    cond_wait(&sd.notify_cond, &lock)
                lock.unlock()
                if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
                continue
            return IPC_NO_CONSUMER
        if _mp_claim(sd, <uint32_t>total_chunks, &tail):
            claimed = True
            break
        if c.local_flags & F_IPC_BLOCK_ON_FULL:
            lock = scoped_lock(sd.notify_mutex)
            if not _mpsc_has_space(sd, sd.global_sequence.value.load(
                memory_order.memory_order_relaxed
            ), <uint32_t>total_chunks) and not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                return IPC_CLOSING
            continue
        return IPC_FULL

    if not claimed:
        return IPC_CLOSING

    for chunk_idx in range(total_chunks):
        idx        = (tail + chunk_idx) & (sd.block_count - 1)
        slot       = _slot(c, idx)
        chunk_size = remaining if remaining <= payload_cap else payload_cap

        _mp_wait_slot(c, idx, tail + chunk_idx)
        #if not c.running:
        #    return IPC_CLOSING

        _write_var_hdr(slot, <uint32_t>chunk_size, chunk_idx, total_chunks)
        memcpy(slot + 8, data + (size - remaining), chunk_size)
        remaining -= chunk_size
        _mp_publish(c, idx, tail + chunk_idx)

    return IPC_OK


cdef int ipc_mpsc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        tail, idx
        char*           slot
        size_t          payload_cap  = sd.block_size - 8
        size_t          remaining    = size
        uint16_t        total_chunks = <uint16_t>((size + payload_cap - 1) / payload_cap)
        uint16_t        chunk_idx
        size_t          chunk_size

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING
    
    if not _mpsc_has_consumer(sd): 
        return IPC_NO_CONSUMER

    if total_chunks == 0 or total_chunks > sd.block_count:
        return IPC_ERR

    if not _mp_claim(sd, <uint32_t>total_chunks, &tail):
        return IPC_FULL

    for chunk_idx in range(total_chunks):
        idx        = (tail + chunk_idx) & (sd.block_count - 1)
        slot       = _slot(c, idx)
        chunk_size = remaining if remaining <= payload_cap else payload_cap

        _mp_wait_slot(c, idx, tail + chunk_idx)
        #if not c.running:
        #    return IPC_CLOSING

        _write_var_hdr(slot, <uint32_t>chunk_size, chunk_idx, total_chunks)
        memcpy(slot + 8, data + (size - remaining), chunk_size)
        remaining -= chunk_size
        _mp_publish(c, idx, tail + chunk_idx)

    return IPC_OK

# MPSC POP ==========================================================================

cdef int ipc_mpsc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        pos, tail, idx, spins
        char*           slot
        scoped_lock     lock
        timespec_       slot_start
        cbool            timer_started

    if _abort_requested(c):
        return IPC_CLOSING

    while c.running:
        pos  = sd.consumer_sequence.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            lock = scoped_lock(sd.notify_mutex)
            if sd.consumer_sequence.value.load(memory_order.memory_order_acquire) == \
               sd.global_sequence.value.load(memory_order.memory_order_acquire) and c.running and \
               not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            _abort_requested(c)
            continue

        idx = pos & (sd.block_count - 1)
        spins = 0
        timer_started = False

        while c.slot_sequences[idx].seq.value.load(
            memory_order.memory_order_acquire
        ) != pos + 1:
            if _abort_requested(c):
                 return IPC_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(c, &slot_start, &timer_started):
                _sc_recycle(c, idx, pos)
                return IPC_ORPHANED
            cpu_pause()

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_fixed_hdr(slot, out_size)
        _stage_slot(c, slot + 8, out_size[0])
        out_buf[0] = c.scratch_buf

        _sc_recycle(c, idx, pos)
        return IPC_OK

    return IPC_CLOSING



cdef int ipc_mpsc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        pos, tail, idx
        char*           slot

    if _abort_requested(c):
        return IPC_CLOSING

    pos  = sd.consumer_sequence.value.load(memory_order.memory_order_acquire)
    tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

    if pos == tail:
        if _abort_requested(c):
            return IPC_CLOSING
        return IPC_EMPTY

    idx = pos & (sd.block_count - 1)

    if c.slot_sequences[idx].seq.value.load(
        memory_order.memory_order_acquire
    ) != pos + 1:
        return IPC_EMPTY

    slot = _slot(c, idx)
    atomic_thread_fence(memory_order.memory_order_acquire)

    _read_fixed_hdr(slot, out_size)
    _stage_slot(c, slot + 8, out_size[0])
    out_buf[0] = c.scratch_buf

    _sc_recycle(c, idx, pos)
    return IPC_OK


cdef int ipc_mpsc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        pos, tail, idx, spins
        char*           slot
        scoped_lock     lock
        timespec_       slot_start
        cbool            timer_started
    
    if _abort_requested(c):
        return IPC_CLOSING

    while c.running:
        pos  = sd.consumer_sequence.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            lock = scoped_lock(sd.notify_mutex)
            if sd.consumer_sequence.value.load(memory_order.memory_order_acquire) == \
               sd.global_sequence.value.load(memory_order.memory_order_acquire) and c.running and \
               not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            _abort_requested(c)
            continue

        idx = pos & (sd.block_count - 1)
        spins = 0
        timer_started = False

        while c.slot_sequences[idx].seq.value.load(
            memory_order.memory_order_acquire
        ) != pos + 1:
            if _abort_requested(c):
                 return IPC_CLOSING
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(c, &slot_start, &timer_started):
                _sc_recycle(c, idx, pos)
                return IPC_ORPHANED
            cpu_pause()

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_fixed_hdr(slot, out_size)
        out_buf[0] = slot + 8

        c.borrow_pos = pos
        c.borrow_idx = <uint32_t>idx
        return IPC_OK

    return IPC_CLOSING


cdef void ipc_mpsc_pop_commit(void* ctx) noexcept nogil:
    cdef Context* c = <Context*>ctx
    _sc_recycle(c, c.borrow_idx, c.borrow_pos)



cdef int ipc_mpsc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        pos, tail, idx, spins
        char*           slot
        scoped_lock     lock
        size_t          chunk_size
        uint16_t        chunk_idx, total_chunks
        bint            assemble_done
        timespec_       slot_start
        cbool            timer_started
    
    if _abort_requested(c):
        return IPC_CLOSING

    while c.running:
        pos  = sd.consumer_sequence.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            lock = scoped_lock(sd.notify_mutex)
            if sd.consumer_sequence.value.load(memory_order.memory_order_acquire) == \
               sd.global_sequence.value.load(memory_order.memory_order_acquire) and c.running and \
               not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            _abort_requested(c)
            continue

        idx = pos & (sd.block_count - 1)
        spins = 0
        timer_started = False

        while c.slot_sequences[idx].seq.value.load(
            memory_order.memory_order_acquire
        ) != pos + 1:
            spins += 1
            if spins & 0x3FF == 0 and _claimed_slot_orphaned(c, &slot_start, &timer_started):
                _reset_assemble(c)   
                _sc_recycle(c, idx, pos)
                return IPC_ORPHANED
            cpu_pause()

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_var_hdr(slot, &chunk_size, &chunk_idx, &total_chunks)
        assemble_done = _assemble(c, slot + 8, chunk_size, chunk_idx, total_chunks, out_buf, out_size)

        _sc_recycle(c, idx, pos)

        if assemble_done:
            return IPC_OK

    return IPC_CLOSING


cdef int ipc_mpsc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        pos, tail, idx
        char*           slot
        size_t          chunk_size
        uint16_t        chunk_idx, total_chunks
        bint            assemble_done
        int             ret = IPC_OK

    if _abort_requested(c):
        return IPC_CLOSING

    while True:
        pos  = sd.consumer_sequence.value.load(memory_order.memory_order_acquire)
        tail = sd.global_sequence.value.load(memory_order.memory_order_acquire)

        if pos == tail:
            if _abort_requested(c):
                #return IPC_CLOSING
                ret= IPC_CLOSING
                break
            #return IPC_EMPTY
            ret= IPC_EMPTY
            break

        idx = pos & (sd.block_count - 1)

        if c.slot_sequences[idx].seq.value.load(
            memory_order.memory_order_acquire
        ) != pos + 1:
            #return IPC_EMPTY
            ret= IPC_EMPTY
            break

        slot = _slot(c, idx)
        atomic_thread_fence(memory_order.memory_order_acquire)

        _read_var_hdr(slot, &chunk_size, &chunk_idx, &total_chunks)
        assemble_done = _assemble(c, slot + 8, chunk_size, chunk_idx, total_chunks, out_buf, out_size)

        _sc_recycle(c, idx, pos)

        if assemble_done:
            #return IPC_OK
            break

        if _abort_requested(c):
            #return IPC_CLOSING
            ret= IPC_CLOSING
            break
    return ret

# =========================================================================
# ==========================    MPMC    ===================================
# =========================================================================

cdef inline bint _mpmc_has_space(
    SharedDataImpl* sd, uint64_t tail, uint32_t n_slots
) noexcept nogil:
    return tail - sd.reader_min_position.value.load(
        memory_order.memory_order_acquire
    ) + n_slots <= sd.block_count

cdef inline bint _mpmc_claim(
    Context* c, uint32_t n_slots, uint64_t* out_tail
) noexcept nogil:
    cdef:
        SharedDataImpl* sd = c.sd
        uint64_t        t  = sd.global_sequence.value.load(memory_order.memory_order_relaxed)
    #while True:
    #    if not _mpmc_has_space(sd, t, n_slots):
    #        return False
    while _mpmc_has_space(sd, t, n_slots):
        if atomic_compare_exchange_strong_explicit(
            &sd.global_sequence.value, &t, t + n_slots,
            memory_order.memory_order_acq_rel,
            memory_order.memory_order_relaxed
        ):
            out_tail[0] = t
            return True
    return False


cdef inline void _mpmc_wait_slot(
    Context* c, uint64_t tail, uint64_t idx
) noexcept nogil:
    cdef SharedDataImpl* sd = c.sd
    cdef scoped_lock lock
    while tail - sd.reader_min_position.value.load(
        memory_order.memory_order_acquire
    ) >= <uint64_t>sd.block_count:
        #if not c.running:
        #    return
        lock = scoped_lock(sd.notify_mutex)
        if tail - sd.reader_min_position.value.load(
            memory_order.memory_order_acquire
        ) != tail:
            cond_wait(&sd.notify_cond, &lock)
        lock.unlock()


cdef inline void _mpmc_publish(
    Context* c, uint64_t idx, uint64_t tail
) noexcept nogil:
    atomic_thread_fence(memory_order.memory_order_release)
    c.slot_sequences[idx].seq.value.store(tail + 1, memory_order.memory_order_release)
    c.sd.notify_cond.notify_all()


# MPMC PUSH ==========================================================================

cdef int ipc_mpmc_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        tail, idx
        char*           slot
        scoped_lock     lock
        size_t          payload_cap = sd.block_size - 8
        cbool           claimed= False

    if (c.local_flags & F_IPC_CLOSING) or \
       (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if size > payload_cap:
        size = payload_cap

    while c.running:
        if not _spmc_has_consumers(sd):
            if c.local_flags & F_IPC_WAIT_CONSUMERS:
                lock = scoped_lock(sd.notify_mutex)
                if not _spmc_has_consumers(sd) and \
                    not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                    cond_wait(&sd.notify_cond, &lock)
                lock.unlock()
                if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
                continue
            return IPC_NO_CONSUMER

        if _mpmc_claim(c, 1, &tail):
            claimed= True
            break
        if c.local_flags & F_IPC_BLOCK_ON_FULL:
            lock = scoped_lock(sd.notify_mutex)
            if not _mpmc_has_space(sd, sd.global_sequence.value.load(
                memory_order.memory_order_relaxed
            ), 1
            ) and not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
            continue
        elif c.local_flags & F_IPC_OVERWRITE:
            sd.reader_min_position.value.fetch_add(
                1, memory_order.memory_order_acq_rel
            )
            continue
        return IPC_FULL

    if not claimed:
        return IPC_CLOSING

    idx  = tail & (sd.block_count - 1)
    slot = _slot(c, idx)

    _mpmc_wait_slot(c, tail, idx)
    #if not c.running:
    #    return IPC_CLOSING

    _write_fixed_hdr(slot, <uint32_t>size)
    memcpy(slot + 8, data, size)
    _mpmc_publish(c, idx, tail)
    return IPC_OK


cdef int ipc_mpmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c    = <Context*>ctx
        SharedDataImpl* sd   = c.sd
        uint64_t        tail, idx
        char*           slot
        size_t          payload_cap = sd.block_size - 8

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if not _spmc_has_consumers(sd):
        return IPC_NO_CONSUMER
    if not _mpmc_claim(c, 1, &tail):
        return IPC_FULL

    if size > payload_cap:
        size = payload_cap

    idx  = tail & (sd.block_count - 1)
    slot = _slot(c, idx)

    _mpmc_wait_slot(c, tail, idx)
    #if not c.running:
    #    return IPC_CLOSING

    _write_fixed_hdr(slot, <uint32_t>size)
    memcpy(slot + 8, data, size)
    _mpmc_publish(c, idx, tail)
    return IPC_OK


cdef int ipc_mpmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        tail, idx
        char*           slot
        scoped_lock     lock
        size_t          payload_cap  = sd.block_size - 8
        size_t          remaining    = size
        uint16_t        total_chunks = <uint16_t>((size + payload_cap - 1) / payload_cap)
        uint16_t        chunk_idx
        size_t          chunk_size
        cbool           claimed= False

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING

    if total_chunks == 0 or total_chunks > sd.block_count:
        return IPC_ERR

    while c.running:
        if (c.local_flags & F_IPC_CLOSING) or \
           (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
            return IPC_CLOSING
        if not _spmc_has_consumers(sd):
            if c.local_flags & F_IPC_WAIT_CONSUMERS:
                lock = scoped_lock(sd.notify_mutex)
                if not _spmc_has_consumers(sd) and \
                    not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                    cond_wait(&sd.notify_cond, &lock)
                lock.unlock()
                if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                    return IPC_CLOSING
                continue
            return IPC_NO_CONSUMER
        if _mpmc_claim(c, <uint32_t>total_chunks, &tail):
            claimed= True
            break
        if c.local_flags & F_IPC_BLOCK_ON_FULL:
            lock = scoped_lock(sd.notify_mutex)
            if not _mpmc_has_space(sd, sd.global_sequence.value.load(
                memory_order.memory_order_relaxed
                ), <uint32_t>total_chunks
            ) and not (sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT):
                cond_wait(&sd.notify_cond, &lock)
            lock.unlock()
            if sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_ABORT:
                return IPC_CLOSING
            continue
        return IPC_FULL

    if not claimed:
        return IPC_CLOSING

    for chunk_idx in range(total_chunks):
        idx        = (tail + chunk_idx) & (sd.block_count - 1)
        slot       = _slot(c, idx)
        chunk_size = remaining if remaining <= payload_cap else payload_cap

        _mpmc_wait_slot(c, tail + chunk_idx, idx)
        #if not c.running:
        #    return IPC_CLOSING

        _write_var_hdr(slot, <uint32_t>chunk_size, chunk_idx, total_chunks)
        memcpy(slot + 8, data + (size - remaining), chunk_size)
        remaining -= chunk_size
        _mpmc_publish(c, idx, tail + chunk_idx)

    return IPC_OK


cdef int ipc_mpmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil:
    cdef:
        Context*        c            = <Context*>ctx
        SharedDataImpl* sd           = c.sd
        uint64_t        tail, idx
        char*           slot
        size_t          payload_cap  = sd.block_size - 8
        size_t          remaining    = size
        uint16_t        total_chunks = <uint16_t>((size + payload_cap - 1) / payload_cap)
        uint16_t        chunk_idx
        size_t          chunk_size

    if not c.running or (c.local_flags & F_IPC_CLOSING) or (c.sd.shared_flags.load(memory_order.memory_order_relaxed) & F_IPC_CLOSING):
        return IPC_CLOSING
    if not _spmc_has_consumers(sd):
        return IPC_NO_CONSUMER

    if total_chunks == 0 or total_chunks > sd.block_count:
        return IPC_ERR

    if not _mpmc_claim(c, <uint32_t>total_chunks, &tail):
        return IPC_FULL

    for chunk_idx in range(total_chunks):
        idx        = (tail + chunk_idx) & (sd.block_count - 1)
        slot       = _slot(c, idx)
        chunk_size = remaining if remaining <= payload_cap else payload_cap

        _mpmc_wait_slot(c, tail + chunk_idx, idx)
        #if not c.running:
        #    return IPC_CLOSING

        _write_var_hdr(slot, <uint32_t>chunk_size, chunk_idx, total_chunks)
        memcpy(slot + 8, data + (size - remaining), chunk_size)
        remaining -= chunk_size
        _mpmc_publish(c, idx, tail + chunk_idx)

    return IPC_OK

# MPMC POP =========================================================================

cdef int ipc_mpmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return ipc_spmc_pop(ctx, out_buf, out_size)

cdef int ipc_mpmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return ipc_spmc_try_pop(ctx, out_buf, out_size)

cdef int ipc_mpmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return ipc_spmc_pop_borrow(ctx, out_buf, out_size)

cdef void ipc_mpmc_pop_commit(void* ctx) noexcept nogil:
    ipc_spmc_pop_commit(ctx)

cdef int ipc_mpmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return ipc_spmc_pop_var(ctx, out_buf, out_size)

cdef int ipc_mpmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil:
    return ipc_spmc_try_pop_var(ctx, out_buf, out_size)
      
# =================x=========================x====================x==================x=============x===============
# =================x=========================x====================x==================x=============x===============


ctypedef int  (*push_fn)(void*, const char*, size_t) noexcept nogil
ctypedef int  (*pop_fn) (void*, char**, size_t*)     noexcept nogil
ctypedef int  (*borrow_fn)(void*, char**, size_t*)   noexcept nogil
ctypedef void (*commit_fn)(void*)                    noexcept nogil


ctypedef int (*ipc_push_fn_t)(
    void*,
    const char*,
    size_t
) noexcept nogil

ctypedef int (*ipc_pop_fn_t)(
    void*,
    char**,
    size_t*
) noexcept nogil

ctypedef void (*ipc_commit_fn_t)(
    void*
) noexcept nogil



cdef class ShmBase:
    cdef:
        SharedMemSystem _shmsys
        Context* _ctx
    
        string _shm_name
        string _sem_name
    
        uint32_t _block_count 
        uint32_t _block_size    
    
        cbool _detached
    
        const char* _ctx_tag

    def __init__(
            self,
            string& name, 
            uint32_t block_count= 16384, 
            uint32_t block_size= 2048, 
            RunningMode mode= RunningMode.SPMC,
            ProcessRole role= ProcessRole.Producer,
            cbool lag_evict = False
            ):

        self._detached = True

        if not is_power_of_two(block_count):
            raise ValueError(b"no_of_blocks must be a power of 2, got %u", block_count)
        if not is_power_of_two(block_size):
            raise ValueError(b"block_size must be a power of 2, got %u", block_size)

        if lag_evict and mode == RunningMode.MPSC:
            warnings.warn(
                "lag_evict has no effect in MPSC mode -- there's only one "
                "consumer, nothing to compare it against",
                RuntimeWarning,
            )
            lag_evict = False

        self._shm_name = string(b"shm_") + name
        self._sem_name = string(b"sem_") + name

        memset(&self._shmsys, 0, sizeof(SharedMemSystem))

        self._shmsys.shm_name = self._shm_name.c_str()
        self._shmsys.sem_name = self._sem_name.c_str()
        self._shmsys.block_count = block_count
        self._shmsys.block_size  = block_size
        self._shmsys.mode = mode

        self._shmsys.lag_evict = lag_evict

        self._shmsys.ctx  = <Context*>malloc(sizeof(Context))

        placement_new[Context](self._shmsys.ctx)
        self._shmsys.ctx.role = role

        self._ctx_tag  = get_ctx_tag(&self._shmsys)

        if self._shmsys.ctx == NULL:
            raise RuntimeError(b"[%s] OOM for Context", self._ctx_tag)       

        self._ctx = self._shmsys.ctx
    
    cdef int close_pipeline(self, long timeout_ms= -1) noexcept nogil:
        return shutdown_pipeline(&self._shmsys, timeout_ms)

    def __dealloc__(self):
        if self._shmsys.ctx != NULL:
            if self._shmsys.ctx.shm_obj != NULL:
                del self._shmsys.ctx.shm_obj
                self._shmsys.ctx.shm_obj = NULL
            if self._shmsys.ctx.sem_obj != NULL:
                del self._shmsys.ctx.sem_obj
                self._shmsys.ctx.sem_obj = NULL
            if self._shmsys.ctx.assemble_buf != NULL:
                free(self._shmsys.ctx.assemble_buf)

            placement_destroy[Context](self._shmsys.ctx)            
            free(self._shmsys.ctx)

        



cdef class ShmProducer(ShmBase):
    cdef:    
        cbool _producer_initialized  
        cbool _signal_handler_registered
        ipc_push_fn_t _push_fn, _try_push_fn, _push_var_fn, _try_push_var_fn


    def __init__(
            self,
            string& name, 
            uint32_t block_count= 16384, 
            uint32_t block_size= 2048, 
            RunningMode mode= RunningMode.SPMC,
            cbool overwrite = False,
            cbool block_on_full = True,
            cbool lag_evict = False
            ):
        super().__init__(name, block_count, block_size, mode, ProcessRole.Producer, lag_evict)

        self._producer_initialized = False
        self._signal_handler_registered = False

        if overwrite and block_on_full:
            warnings.warn(
                "overwrite and block_on_full are both enabled; block_on_full is "
                "checked first in the push path, so overwrite will never trigger",
                RuntimeWarning,
            )
        if overwrite and mode == RunningMode.MPSC:
            warnings.warn(
                "overwrite has no effect in MPSC mode",
                RuntimeWarning,
            )
        if overwrite:
            warnings.warn(
                "overwrite only applies to the fixed-size push path; "
                "push_var/try_push_var ignore it",
                RuntimeWarning,
            )


        if overwrite:
            self._ctx.local_flags |= F_IPC_OVERWRITE
        if block_on_full:
            self._ctx.local_flags |= F_IPC_BLOCK_ON_FULL

        self._ctx.running = 1

        if mode == RunningMode.SPMC:
            self._push_fn = ipc_spmc_push
            self._try_push_fn = ipc_spmc_try_push
            self._push_var_fn = ipc_spmc_push_var
            self._try_push_var_fn = ipc_spmc_try_push_var 
        if mode == RunningMode.MPSC:
            self._push_fn = ipc_mpsc_push
            self._try_push_fn = ipc_mpsc_try_push
            self._push_var_fn = ipc_mpsc_push_var
            self._try_push_var_fn = ipc_mpsc_try_push_var 
        if mode == RunningMode.MPMC:
            self._push_fn = ipc_mpmc_push
            self._try_push_fn = ipc_mpmc_try_push
            self._push_var_fn = ipc_mpmc_push_var
            self._try_push_var_fn = ipc_mpmc_try_push_var 
        
        if init_producer_system(&self._shmsys) == 0:
            self._producer_initialized = True
            self._detached = False
        else:
            raise RuntimeError(b"Init producer failed")

        init_signal_handler()
        register_context_notify(
            <void*>self._shmsys.ctx,
            NULL,
            <context_notify_fn>notify_context,
        )
        self._signal_handler_registered = True
    
    cdef int push(self, const char* data, size_t size) noexcept nogil:
        return self._push_fn(self._ctx, data, size)
    
    cdef int try_push(self, const char* data, size_t size) noexcept nogil:
        return self._try_push_fn(self._ctx, data, size)
    
    cdef int push_var(self, const char* data, size_t size) noexcept nogil:
        return self._push_var_fn(self._ctx, data, size)
    
    cdef int try_push_var(self, const char* data, size_t size) noexcept nogil:
        return self._try_push_var_fn(self._ctx, data, size)

    cdef int detach(self) noexcept nogil:
        cdef int ret
        if self._producer_initialized and not self._detached:
            ret = detach_producer(&self._shmsys)
            self._detached = True
            return ret
        else:
            return -1
    
    def __dealloc__(self):
        self.detach()

        if self._signal_handler_registered:
            unregister_context_notify(<void*>self._shmsys.ctx)
            cleanup_signal_handler()


cdef class ShmConsumer(ShmBase):
    cdef:
        cbool _consumer_initialized 
        cbool _signal_handler_registered

        ipc_pop_fn_t _pop_fn, _try_pop_fn, _pop_borrow_fn, _pop_var_fn, _try_pop_var_fn
        ipc_commit_fn_t _commit_fn

    def __init__(
            self,
            string& name, 
            uint32_t block_count= 16384, 
            uint32_t block_size= 2048, 
            RunningMode mode= RunningMode.SPMC,
            cbool lag_evict = False
            ):
        super().__init__(name, block_count, block_size, mode, ProcessRole.Consumer, lag_evict)

        self._consumer_initialized = False
        self._signal_handler_registered = False

        self._ctx.local_flags |= 0
        self._ctx.running = 1

        if mode == RunningMode.SPMC:
            self._pop_fn            = ipc_spmc_pop
            self._try_pop_fn        = ipc_spmc_try_pop
            self._pop_var_fn        = ipc_spmc_pop_var
            self._try_pop_var_fn    = ipc_spmc_try_pop_var
            self._pop_borrow_fn     = ipc_spmc_pop_borrow
            self._commit_fn        = ipc_spmc_pop_commit

        elif mode == RunningMode.MPSC:
            self._pop_fn            = ipc_mpsc_pop
            self._try_pop_fn        = ipc_mpsc_try_pop
            self._pop_var_fn        = ipc_mpsc_pop_var
            self._try_pop_var_fn    = ipc_mpsc_try_pop_var
            self._pop_borrow_fn     = ipc_mpsc_pop_borrow
            self._commit_fn        = ipc_mpsc_pop_commit

        elif mode == RunningMode.MPMC:
            self._pop_fn            = ipc_mpmc_pop
            self._try_pop_fn        = ipc_mpmc_try_pop
            self._pop_var_fn        = ipc_mpmc_pop_var
            self._try_pop_var_fn    = ipc_mpmc_try_pop_var
            self._pop_borrow_fn     = ipc_mpmc_pop_borrow
            self._commit_fn        = ipc_mpmc_pop_commit  

        if init_consumer_system(&self._shmsys) == 0:
            self._consumer_initialized = True     
            self._detached = False
        else:
            raise RuntimeError(b"Init consumer failed")

        init_signal_handler()
        register_context_notify(
            <void*>self._shmsys.ctx,
            NULL,
            <context_notify_fn>notify_context,
        )
        self._signal_handler_registered = True
    
    cdef int pop(self, char** data, size_t* size) noexcept nogil:
        return self._pop_fn(self._ctx, data, size)

    cdef int try_pop(self, char** data, size_t* size) noexcept nogil:
        return self._try_pop_fn(self._ctx, data, size)

    cdef int pop_var(self, char** data, size_t* size) noexcept nogil:
        return self._pop_var_fn(self._ctx, data, size)

    cdef int try_pop_var(self, char** data, size_t* size) noexcept nogil:
        return self._try_pop_var_fn(self._ctx, data, size)

    cdef int pop_borrow(self, char** data, size_t* size) noexcept nogil:
        return self._pop_borrow_fn(self._ctx, data, size)

    cdef void pop_commit(self) noexcept nogil:
        self._commit_fn(self._ctx)

    cdef int detach(self, long timeout_ms= -1, long close_signal_wait_ms= 3000) noexcept nogil:
        cdef int ret
        if self._consumer_initialized and not self._detached:
            ret = detach_consumer(&self._shmsys, timeout_ms, close_signal_wait_ms)
            self._detached = True
            return ret
        else:
            return -1
    
    def __dealloc__(self):
        self.detach()

        if self._signal_handler_registered:
            unregister_context_notify(<void*>self._shmsys.ctx)
            cleanup_signal_handler()

# ==============================================================================================================
# =========================================       PYTHON API         ===========================================
# ==============================================================================================================

cpdef enum class ShmMode:
    SPMC = <int>RunningMode.SPMC
    MPSC = <int>RunningMode.MPSC
    MPMC = <int>RunningMode.MPMC


class IPCError(Exception):
    pass

class IPCClosed(IPCError):
    pass

class IPCOrphaned(IPCError):
    pass

class IPCDrainTimeout(IPCError):
    pass

class IPCUnknownStatus(IPCError):
    pass


cdef inline int _check_ret(int ret) except -1000:
    if ret == IPC_OK or ret == IPC_EMPTY or ret == IPC_FULL or ret == IPC_NO_CONSUMER:
        return ret
    if ret == IPC_CLOSING:
        raise IPCClosed(b"IPC pipeline is closing")
    elif ret == IPC_ORPHANED:
        raise IPCOrphaned(b"claimed slot was abandoned")
    elif ret == IPC_DRAIN_TIMEOUT:
        raise IPCDrainTimeout(b"shutdown drain timed out")
    elif ret == IPC_ERR:
        raise IPCError(b"message can never fit in this ring")
    else:
        raise IPCUnknownStatus(b"unrecognized IPC status code: %d" % ret)




cdef class Producer(ShmBase):
    cdef:    
        CBufferView _cb
        cbool _producer_initialized  
        cbool _signal_handler_registered
        ipc_push_fn_t _push_fn, _try_push_fn, _push_var_fn, _try_push_var_fn

        char* _name


    def __init__(
            self,
            str name, 
            uint32_t block_count= 16384, 
            uint32_t block_size= 2048, 
            ShmMode mode= ShmMode.SPMC,
            MsgKind msg_kind= MsgKind.OBJ,  
            bint overwrite = False,
            bint block_on_full = True,
            bint lag_evict = False
            ):
        self._name = strdup(name.encode())
        super().__init__(string(self._name), block_count, block_size, <RunningMode>mode, ProcessRole.Producer, <cbool>lag_evict)

        self._producer_initialized = False
        self._signal_handler_registered = False

        if overwrite and block_on_full:
            warnings.warn(
                "overwrite and block_on_full are both enabled; block_on_full is "
                "checked first in the push path, so overwrite will never trigger",
                RuntimeWarning,
            )
        if overwrite and mode == ShmMode.MPSC:
            warnings.warn(
                "overwrite has no effect in MPSC mode",
                RuntimeWarning,
            )
        if overwrite:
            warnings.warn(
                "overwrite only applies to the fixed-size push path; "
                "push_var/try_push_var ignore it",
                RuntimeWarning,
            )

        if overwrite:
            self._ctx.local_flags |= F_IPC_OVERWRITE
        if block_on_full:
            self._ctx.local_flags |= F_IPC_BLOCK_ON_FULL

        self._ctx.running = 1

        if mode == ShmMode.SPMC:
            self._push_fn = ipc_spmc_push
            self._try_push_fn = ipc_spmc_try_push
            self._push_var_fn = ipc_spmc_push_var
            self._try_push_var_fn = ipc_spmc_try_push_var 
        if mode == ShmMode.MPSC:
            self._push_fn = ipc_mpsc_push
            self._try_push_fn = ipc_mpsc_try_push
            self._push_var_fn = ipc_mpsc_push_var
            self._try_push_var_fn = ipc_mpsc_try_push_var 
        if mode == ShmMode.MPMC:
            self._push_fn = ipc_mpmc_push
            self._try_push_fn = ipc_mpmc_try_push
            self._push_var_fn = ipc_mpmc_push_var
            self._try_push_var_fn = ipc_mpmc_try_push_var 
        
        if init_producer_system(&self._shmsys) == 0:
            self._producer_initialized = True
            self._detached = False
        else:
            raise RuntimeError(b"Init producer failed")

        self._cb = CBufferView(msg_kind)

        init_signal_handler()
        register_context_notify(
            <void*>self._shmsys.ctx,
            NULL,
            <context_notify_fn>notify_context,
        )
        self._signal_handler_registered = True
    
    cpdef int push(self, object msg):
        self._cb.load(msg)
        with nogil:
            ret= self._push_fn(self._ctx, self._cb.data, self._cb.size)
        _check_ret(ret)
    
    cpdef int try_push(self, object msg):
        self._cb.load(msg)
        with nogil:
            ret= self._try_push_fn(self._ctx, self._cb.data, self._cb.size)
        _check_ret(ret)
    
    cpdef int push_var(self, object msg):
        self._cb.load(msg)
        with nogil:
            ret=  self._push_var_fn(self._ctx, self._cb.data, self._cb.size)
        _check_ret(ret)
    
    cpdef int try_push_var(self, object msg):
        self._cb.load(msg)
        with nogil:
            ret= self._try_push_var_fn(self._ctx, self._cb.data, self._cb.size)
        _check_ret(ret)

    cpdef int detach(self):
        cdef int ret
        if self._producer_initialized and not self._detached:
            with nogil:
                ret = detach_producer(&self._shmsys)
            self._detached = True
            return ret
        else:
            return -1
    
    cpdef int shutdown(self, long timeout_ms= -1):
        with nogil:
            return shutdown_pipeline(&self._shmsys, timeout_ms)
    
    def __dealloc__(self):
        self.detach()

        if self._signal_handler_registered:
            unregister_context_notify(<void*>self._shmsys.ctx)
            cleanup_signal_handler()



cdef class Consumer(ShmBase):
    cdef:
        cbool _consumer_initialized 
        cbool _signal_handler_registered

        ipc_pop_fn_t _pop_fn, _try_pop_fn, _pop_borrow_fn, _pop_var_fn, _try_pop_var_fn
        ipc_commit_fn_t _commit_fn

        char* _name

    def __init__(
            self,
            str name, 
            uint32_t block_count= 16384, 
            uint32_t block_size= 2048, 
            ShmMode mode= ShmMode.SPMC,
            bint lag_evict = False
            ):
        self._name = strdup(name.encode())
        super().__init__(string(self._name), block_count, block_size, <RunningMode>mode, ProcessRole.Consumer, <cbool>lag_evict)

        self._consumer_initialized = False
        self._signal_handler_registered = False

        self._ctx.local_flags |= 0
        self._ctx.running = 1

        if mode == ShmMode.SPMC:
            self._pop_fn            = ipc_spmc_pop
            self._try_pop_fn        = ipc_spmc_try_pop
            self._pop_var_fn        = ipc_spmc_pop_var
            self._try_pop_var_fn    = ipc_spmc_try_pop_var
            self._pop_borrow_fn     = ipc_spmc_pop_borrow
            self._commit_fn        = ipc_spmc_pop_commit

        elif mode == ShmMode.MPSC:
            self._pop_fn            = ipc_mpsc_pop
            self._try_pop_fn        = ipc_mpsc_try_pop
            self._pop_var_fn        = ipc_mpsc_pop_var
            self._try_pop_var_fn    = ipc_mpsc_try_pop_var
            self._pop_borrow_fn     = ipc_mpsc_pop_borrow
            self._commit_fn        = ipc_mpsc_pop_commit

        elif mode == ShmMode.MPMC:
            self._pop_fn            = ipc_mpmc_pop
            self._try_pop_fn        = ipc_mpmc_try_pop
            self._pop_var_fn        = ipc_mpmc_pop_var
            self._try_pop_var_fn    = ipc_mpmc_try_pop_var
            self._pop_borrow_fn     = ipc_mpmc_pop_borrow
            self._commit_fn        = ipc_mpmc_pop_commit  

        if init_consumer_system(&self._shmsys) == 0:
            self._consumer_initialized = True     
            self._detached = False
        else:
            raise RuntimeError(b"Init consumer failed")

        init_signal_handler()
        register_context_notify(
            <void*>self._shmsys.ctx,
            NULL,
            <context_notify_fn>notify_context,
        )
        self._signal_handler_registered = True
    
    cpdef bytes pop(self):
        cdef:
            char* data
            size_t size
            int ret

        with nogil:
            ret = self._pop_fn(self._ctx, &data, &size)
        if ret == IPC_OK:
            return PyBytes_FromStringAndSize(data, size)
        _check_ret(ret)

    cpdef bytes try_pop(self):
        cdef:
            char* data
            size_t size
            int ret

        with nogil:
            ret =  self._try_pop_fn(self._ctx, &data, &size)
        if ret == IPC_OK:
            return PyBytes_FromStringAndSize(data, size)
        _check_ret(ret)

    cpdef bytes pop_var(self):
        cdef:
            char* data
            size_t size
            int ret

        with nogil:
            ret = self._pop_var_fn(self._ctx, &data, &size)
        if ret == IPC_OK:
            return PyBytes_FromStringAndSize(data, size)
        _check_ret(ret)

    cpdef bytes try_pop_var(self):
        cdef:
            char* data
            size_t size
            int ret

        with nogil:
            ret =  self._try_pop_var_fn(self._ctx, &data, &size)
        if ret == IPC_OK:
            return PyBytes_FromStringAndSize(data, size)
        _check_ret(ret)

    cpdef bytes pop_borrow(self):
        cdef:
            char* data
            size_t size
            int ret

        with nogil:
            ret =  self._pop_borrow_fn(self._ctx, &data, &size)
        if ret == IPC_OK:
            return PyBytes_FromStringAndSize(data, size)
        _check_ret(ret)

    cpdef void pop_commit(self):
        with nogil:
            self._commit_fn(self._ctx)

    cpdef int detach(self, long timeout_ms= -1, long close_signal_wait_ms= 3000):
        cdef int ret
        if self._consumer_initialized and not self._detached:
            with nogil:
                ret = detach_consumer(&self._shmsys, timeout_ms, close_signal_wait_ms)
            self._detached = True
            return ret
        else:
            return -1
    
    cpdef int shutdown(self, long timeout_ms= -1):
        with nogil:
            return shutdown_pipeline(&self._shmsys, timeout_ms)
    
    def __dealloc__(self):
        self.detach()

        if self._signal_handler_registered:
            unregister_context_notify(<void*>self._shmsys.ctx)
            cleanup_signal_handler()

