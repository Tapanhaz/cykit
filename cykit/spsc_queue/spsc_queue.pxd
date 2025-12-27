from libcpp.atomic cimport atomic
from libc.stdint cimport uint8_t, uint64_t

cdef struct SPSCSlot:
    char* buf
    size_t size

cdef struct SPSCQueue:
    atomic[uint64_t] head
    uint8_t[64] pad_head
    atomic[uint64_t] tail
    uint8_t[64] pad_tail
    size_t capacity_mask
    size_t slot_size
    SPSCSlot* slots       
    char* slot_bufs   
    atomic[uint64_t] running 

cdef void init_spscq(SPSCQueue* q, size_t slot_size, size_t capacity) noexcept nogil
cdef bint spscq_push(SPSCQueue* q, const char* data, size_t size, bint block) noexcept nogil
cdef bint spscq_pop(SPSCQueue* q, char** out_buf, size_t* out_size, bint block) noexcept nogil
cdef void spscq_close(SPSCQueue* q) noexcept nogil