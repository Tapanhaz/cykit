from libcpp.atomic cimport atomic
from libc.stdint cimport uint8_t, uint64_t, uint16_t, uint32_t


cdef enum:
    F_OVERWRITE     = 1 << 0
    F_ZEROCOPY      = 1 << 1
    F_BLOCK_ON_FULL = 1 << 2

cdef enum:
    SPSC_OK    = 1
    SPSC_EMPTY = 0
    SPSC_FULL  = -2
    SPSC_ERR   = -1

    SPSC_PARTIAL  = 2
    SPSC_SKIP     = 3

cdef struct SPSCSlot:
    char* buf
    size_t size

    uint32_t seq_id
    uint16_t chunk_idx
    uint16_t total_chunks

cdef struct SPSCQueueImpl:
    atomic[uint64_t] tail
    uint8_t[56] pad_tail 
    
    atomic[uint64_t] head
    uint8_t[56] pad_head 
    
    size_t  capacity_mask
    size_t  slot_size
    SPSCSlot* slots
    char* slot_bufs
    atomic[uint64_t] running
    uint8_t flags

    uint32_t seq_counter
    uint32_t expected_seq
    uint16_t expected_chunk
    char*    assemble_buf
    size_t   assemble_used
    size_t   assemble_cap

cdef void spsc_queue_notify(void* ctx) noexcept nogil


cdef class SPSCQueue:
    cdef:
        SPSCQueueImpl _q

    cdef int push(self, const char* data, size_t size) noexcept nogil
    cdef int try_push(self, const char* data, size_t size) noexcept nogil
    cdef int push_var(self, const char* data, size_t size) noexcept nogil
    cdef int try_push_var(self, const char* data, size_t size) noexcept nogil

    cdef int pop(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef int pop_borrow(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef void pop_commit(self) noexcept nogil
    cdef int try_pop(self, char** out_buf, size_t* out_size,) noexcept nogil
    cdef int pop_var(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef int try_pop_var(self, char** out_buf, size_t* out_size) noexcept nogil
    
    cdef int close(self, long timeout_ms = ?) noexcept nogil
