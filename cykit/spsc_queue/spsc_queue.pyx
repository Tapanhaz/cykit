from libc.stdint cimport uint64_t
from libc.stddef cimport size_t
from libc.string cimport memcpy, memset
from libc.stdlib cimport free, realloc
from cykit.common cimport (
    atomic_notify_one, 
    atomic_thread_fence,
    atomic_wait,
    memory_order_acquire,
    memory_order_release,
    memory_order_relaxed,
    aligned_alloc
)

from cykit.utils.signal_handler cimport (
    init_signal_handler, 
    context_notify_fn,
    register_context_notify, 
    unregister_context_notify,
    cleanup_signal_handler
)

from cykit.utils.compat cimport usleep_



cdef void spsc_queue_notify(void* ctx) noexcept nogil:
    cdef SPSCQueueImpl* q = <SPSCQueueImpl*>ctx
    q.running.store(0, memory_order_release)

    q.tail.fetch_add(1, memory_order_relaxed)
    q.head.fetch_add(1, memory_order_relaxed)

    atomic_notify_one(&q.tail)
    atomic_notify_one(&q.head)


cdef class SPSCQueue:
    
    def __cinit__(
            self,
            size_t slot_size,
            size_t capacity,
            bint overwrite= False,
            bint zerocopy= False,
            bint block_on_full= False
        ):
        cdef size_t i

        self._q.flags = (
                            (F_OVERWRITE     if overwrite     else 0) |
                            (F_ZEROCOPY      if zerocopy      else 0) |
                            (F_BLOCK_ON_FULL if block_on_full else 0)
                        )

        self._q.head.store(0, memory_order_relaxed)
        self._q.tail.store(0, memory_order_relaxed)
        self._q.capacity_mask = capacity - 1
        self._q.slot_size     = slot_size

        self._q.seq_counter    = 0
        self._q.expected_seq   = 0
        self._q.expected_chunk = 0
        self._q.assemble_buf   = NULL
        self._q.assemble_used  = 0
        self._q.assemble_cap   = 0

        self._q.running.store(1, memory_order_relaxed)

        self._q.slots = <SPSCSlot*>aligned_alloc(64, capacity * sizeof(SPSCSlot))
        self._q.slot_bufs = <char*>aligned_alloc(64, capacity * slot_size)

        memset(self._q.slot_bufs, 0, capacity * slot_size)

        for i in range(capacity):
            self._q.slots[i].buf  = self._q.slot_bufs + i * slot_size
            self._q.slots[i].size = 0

        init_signal_handler()

        register_context_notify(
            <void*>&self._q,
            NULL,
            <context_notify_fn>spsc_queue_notify
        )

    
    cdef int push(
            self,
            const char* data,
            size_t size
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot

        while self._q.running.load(memory_order_acquire):

            head = self._q.head.load(memory_order_acquire)
            tail = self._q.tail.load(memory_order_relaxed)

            if tail - head >= self._q.capacity_mask + 1:

                if self._q.flags & F_OVERWRITE:
                    self._q.head.store(head + 1, memory_order_release)
                    atomic_notify_one(&self._q.head)
                    continue

                elif self._q.flags & F_BLOCK_ON_FULL:
                    if not self._q.running.load(memory_order_acquire):
                        return SPSC_ERR

                    atomic_wait(&self._q.head, head)

                    if not self._q.running.load(memory_order_acquire):
                        return SPSC_ERR

                    continue

                else:
                    return SPSC_FULL

            idx = tail & self._q.capacity_mask
            slot = &self._q.slots[idx]

            if self._q.flags & F_ZEROCOPY:
                slot.buf  = <char*>data
                slot.size = size
            else:
                if size > self._q.slot_size:
                    size = self._q.slot_size
                memcpy(slot.buf, data, size)
                slot.size = size
                

            atomic_thread_fence(memory_order_release)
            self._q.tail.store(tail + 1, memory_order_release)            
            atomic_notify_one(&self._q.tail)
            return SPSC_OK

        return SPSC_ERR


    cdef int try_push(
            self,
            const char* data,
            size_t size
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot

        if not self._q.running.load(memory_order_acquire):
            return SPSC_ERR

        head = self._q.head.load(memory_order_acquire)
        tail = self._q.tail.load(memory_order_relaxed)

        if tail - head >= self._q.capacity_mask + 1:
            if self._q.flags & F_OVERWRITE:
                self._q.head.store(head + 1, memory_order_release)

                atomic_notify_one(&self._q.head)

                head = head + 1
                if tail - head >= self._q.capacity_mask + 1:
                    return SPSC_FULL
            else:
                return SPSC_FULL

        idx = tail & self._q.capacity_mask
        slot = &self._q.slots[idx]

        if self._q.flags & F_ZEROCOPY:
            slot.buf  = <char*>data
            slot.size = size
        else:
            if size > self._q.slot_size:
                size = self._q.slot_size
            memcpy(slot.buf, data, size)
            slot.size = size

        atomic_thread_fence(memory_order_release)
        self._q.tail.store(tail + 1, memory_order_release)
        atomic_notify_one(&self._q.tail)
        return SPSC_OK
        
    
    cdef int push_var(
            self,
            const char* data,
            size_t size
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot
            SPSCSlot* victim
            size_t offset, chunk_bytes
            uint16_t total_chunks, chunk_idx, chunks_left
            uint32_t seq_id

        total_chunks = <uint16_t>((size + self._q.slot_size - 1) / self._q.slot_size)
        seq_id       = self._q.seq_counter
        self._q.seq_counter += 1
        offset       = 0

        for chunk_idx in range(total_chunks):

            while self._q.running.load(memory_order_acquire):

                head = self._q.head.load(memory_order_acquire)
                tail = self._q.tail.load(memory_order_relaxed)

                if tail - head >= self._q.capacity_mask + 1:
                    if self._q.flags & F_OVERWRITE:
                        victim = &self._q.slots[head & self._q.capacity_mask]
                        chunks_left = victim.total_chunks - victim.chunk_idx

                        if chunks_left == 0:
                            chunks_left = 1
                        self._q.head.store(head + chunks_left, memory_order_release)

                        atomic_notify_one(&self._q.head)

                        continue

                    elif self._q.flags & F_BLOCK_ON_FULL:
                        atomic_wait(&self._q.head, head)

                        if not self._q.running.load(memory_order_acquire):
                            return SPSC_ERR

                        continue

                    else:
                        return SPSC_FULL

                idx  = tail & self._q.capacity_mask
                slot = &self._q.slots[idx]

                chunk_bytes = size - offset
                if chunk_bytes > self._q.slot_size:
                    chunk_bytes = self._q.slot_size

                memcpy(slot.buf, data + offset, chunk_bytes)
                slot.size         = chunk_bytes
                slot.seq_id       = seq_id
                slot.chunk_idx    = chunk_idx
                slot.total_chunks = total_chunks

                offset += chunk_bytes

                atomic_thread_fence(memory_order_release)
                self._q.tail.store(tail + 1, memory_order_release)

                atomic_notify_one(&self._q.tail)
                break

            if not self._q.running.load(memory_order_acquire):
                return SPSC_ERR

        return SPSC_OK
    

    cdef int try_push_var(
            self,
            const char* data,
            size_t size
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot
            SPSCSlot* victim
            size_t offset, chunk_bytes
            uint16_t total_chunks, chunk_idx, chunks_left
            uint32_t seq_id

        if not self._q.running.load(memory_order_acquire):
            return SPSC_ERR

        total_chunks = <uint16_t>((size + self._q.slot_size - 1) / self._q.slot_size)
        seq_id       = self._q.seq_counter
        self._q.seq_counter += 1
        offset       = 0

        for chunk_idx in range(total_chunks):

            head = self._q.head.load(memory_order_acquire)
            tail = self._q.tail.load(memory_order_relaxed)

            if tail - head >= self._q.capacity_mask + 1:
                if self._q.flags & F_OVERWRITE:
                    victim = &self._q.slots[head & self._q.capacity_mask]
                    chunks_left = victim.total_chunks - victim.chunk_idx

                    if chunks_left == 0:
                        chunks_left = 1

                    self._q.head.store(head + chunks_left, memory_order_release)

                    atomic_notify_one(&self._q.head)

                    head = self._q.head.load(memory_order_acquire)
                    tail = self._q.tail.load(memory_order_relaxed)

                    if tail - head >= self._q.capacity_mask + 1:
                        return SPSC_FULL
                else:
                    return SPSC_FULL

            idx  = tail & self._q.capacity_mask
            slot = &self._q.slots[idx]

            chunk_bytes = size - offset
            if chunk_bytes > self._q.slot_size:
                chunk_bytes = self._q.slot_size

            memcpy(slot.buf, data + offset, chunk_bytes)
            slot.size         = chunk_bytes
            slot.seq_id       = seq_id
            slot.chunk_idx    = chunk_idx
            slot.total_chunks = total_chunks

            offset += chunk_bytes

            atomic_thread_fence(memory_order_release)
            self._q.tail.store(tail + 1, memory_order_release)
            atomic_notify_one(&self._q.tail)
        
        return SPSC_OK


    cdef int pop(
            self,
            char** out_buf,
            size_t* out_size
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot

        while self._q.running.load(memory_order_acquire):

            head = self._q.head.load(memory_order_relaxed)
            tail = self._q.tail.load(memory_order_acquire)

            if head == tail:
                if not self._q.running.load(memory_order_acquire):
                    return SPSC_ERR

                atomic_wait(&self._q.tail, tail)

                if not self._q.running.load(memory_order_acquire):
                    return SPSC_ERR

                continue

            idx = head & self._q.capacity_mask
            slot = &self._q.slots[idx]

            out_buf[0]  = slot.buf
            out_size[0] = slot.size

            atomic_thread_fence(memory_order_acquire)
            self._q.head.store(head + 1, memory_order_release)
            atomic_notify_one(&self._q.head)
            return SPSC_OK

        return SPSC_ERR
    

    cdef int pop_borrow(
            self,
            char** out_buf,
            size_t* out_size
        ) noexcept nogil:

        cdef:
            uint64_t  head, tail, idx
            SPSCSlot* slot

        while self._q.running.load(memory_order_acquire):

            head = self._q.head.load(memory_order_relaxed)
            tail = self._q.tail.load(memory_order_acquire)

            if head == tail:
                if not self._q.running.load(memory_order_acquire):
                    return SPSC_ERR

                atomic_wait(&self._q.tail, tail)

                if not self._q.running.load(memory_order_acquire):
                    return SPSC_ERR

                continue

            idx         = head & self._q.capacity_mask
            slot        = &self._q.slots[idx]

            atomic_thread_fence(memory_order_acquire)

            out_buf[0]  = slot.buf
            out_size[0] = slot.size

            return SPSC_OK

        return SPSC_ERR

    cdef void pop_commit(self) noexcept nogil:
        cdef uint64_t head = self._q.head.load(memory_order_relaxed)
        self._q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&self._q.head)

    cdef int try_pop(
            self,
            char** out_buf,
            size_t* out_size,
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot

        if not self._q.running.load(memory_order_acquire):
            return SPSC_ERR

        head = self._q.head.load(memory_order_relaxed)
        tail = self._q.tail.load(memory_order_acquire)

        if head == tail:
            return SPSC_EMPTY

        idx = head & self._q.capacity_mask
        slot = &self._q.slots[idx]

        out_buf[0]  = slot.buf
        out_size[0] = slot.size

        atomic_thread_fence(memory_order_acquire)
        self._q.head.store(head + 1, memory_order_release)
        atomic_notify_one(&self._q.head)
        return SPSC_OK  
    
    cdef int pop_var(
            self,
            char** out_buf,
            size_t* out_size
        ) noexcept nogil:
    
        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot
            size_t needed
            char* tmp
    
        while self._q.running.load(memory_order_acquire):
        
            head = self._q.head.load(memory_order_relaxed)
            tail = self._q.tail.load(memory_order_acquire)
    
            if head == tail:
                atomic_wait(&self._q.tail, tail)
                if not self._q.running.load(memory_order_acquire):
                    return SPSC_ERR
                continue
    
            idx  = head & self._q.capacity_mask
            slot = &self._q.slots[idx]
    
            atomic_thread_fence(memory_order_acquire)
    
            if slot.seq_id != self._q.expected_seq or slot.chunk_idx != self._q.expected_chunk:
                if slot.chunk_idx == 0:
                    self._q.expected_seq   = slot.seq_id
                    self._q.expected_chunk = 0
                    self._q.assemble_used  = 0
                else:
                    self._q.head.store(head + 1, memory_order_release)
                    atomic_notify_one(&self._q.head)
                    continue
    
            needed = self._q.assemble_used + slot.size
            if needed > self._q.assemble_cap:
                tmp = <char*>realloc(self._q.assemble_buf, needed * 2)
                if tmp == NULL:
                    return SPSC_ERR
                self._q.assemble_buf  = tmp
                self._q.assemble_cap  = needed * 2
    
            memcpy(self._q.assemble_buf + self._q.assemble_used, slot.buf, slot.size)
            self._q.assemble_used += slot.size
    
            self._q.head.store(head + 1, memory_order_release)
            atomic_notify_one(&self._q.head)
    
            self._q.expected_chunk += 1
    
            if self._q.expected_chunk == slot.total_chunks:
                out_buf[0]             = self._q.assemble_buf
                out_size[0]            = self._q.assemble_used
                self._q.assemble_used  = 0
                self._q.expected_seq  += 1
                self._q.expected_chunk = 0
                return SPSC_OK
    
        return SPSC_ERR
    

    cdef int try_pop_var(
            self,
            char** out_buf,
            size_t* out_size
        ) noexcept nogil:

        cdef:
            uint64_t head, tail, idx
            SPSCSlot* slot
            size_t needed
            char* tmp

        if not self._q.running.load(memory_order_acquire):
            return SPSC_ERR

        while True:
            if not self._q.running.load(memory_order_acquire):
                return SPSC_ERR

            head = self._q.head.load(memory_order_relaxed)
            tail = self._q.tail.load(memory_order_acquire)

            if head == tail:
                return SPSC_EMPTY 

            idx  = head & self._q.capacity_mask
            slot = &self._q.slots[idx]

            atomic_thread_fence(memory_order_acquire)

            if slot.seq_id != self._q.expected_seq or slot.chunk_idx != self._q.expected_chunk:
                if slot.chunk_idx == 0:
                    self._q.expected_seq   = slot.seq_id
                    self._q.expected_chunk = 0
                    self._q.assemble_used  = 0
                else:
                    self._q.head.store(head + 1, memory_order_release)
                    atomic_notify_one(&self._q.head)

                    if not self._q.running.load(memory_order_acquire):
                        return SPSC_ERR

                    continue

            needed = self._q.assemble_used + slot.size
            if needed > self._q.assemble_cap:
                tmp = <char*>realloc(self._q.assemble_buf, needed * 2)
                if tmp == NULL:
                    return SPSC_ERR
                self._q.assemble_buf = tmp
                self._q.assemble_cap = needed * 2

            memcpy(self._q.assemble_buf + self._q.assemble_used, slot.buf, slot.size)
            self._q.assemble_used += slot.size

            self._q.head.store(head + 1, memory_order_release)
            atomic_notify_one(&self._q.head)

            self._q.expected_chunk += 1

            if self._q.expected_chunk == slot.total_chunks:
                out_buf[0]             = self._q.assemble_buf
                out_size[0]            = self._q.assemble_used
                self._q.assemble_used  = 0
                self._q.expected_seq  += 1
                self._q.expected_chunk = 0
                return SPSC_OK
        

    cdef void close(self) noexcept nogil:
        self._q.running.store(0, memory_order_relaxed)

        atomic_notify_one(&self._q.tail)
        atomic_notify_one(&self._q.head)

        if self._q.slot_bufs != NULL:
            free(self._q.slot_bufs)
            self._q.slot_bufs = NULL
        if self._q.slots != NULL:
            free(self._q.slots)
            self._q.slots = NULL
        if self._q.assemble_buf != NULL:
            free(self._q.assemble_buf)
            self._q.assemble_buf = NULL

    
    def __dealloc__(self):
        self.close()
        usleep_(2000)

        unregister_context_notify(<void*>&self._q)
        usleep_(2000)
        cleanup_signal_handler()
