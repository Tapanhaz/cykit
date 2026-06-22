from libcpp.atomic cimport atomic
from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t
from cykit.common cimport atomic_uint64_t


ctypedef int  (*push_fn)(void*, const char*, size_t) noexcept nogil
ctypedef int  (*pop_fn) (void*, char**, size_t*)     noexcept nogil
ctypedef int  (*borrow_fn)(void*, char**, size_t*)   noexcept nogil
ctypedef void (*commit_fn)(void*)                    noexcept nogil

ctypedef int  (*register_fn)  (void*, uint32_t*) noexcept nogil
ctypedef void (*unregister_fn)(void*, uint32_t)  noexcept nogil


cdef enum:
    F_OVERWRITE     = 1 << 0
    F_ZEROCOPY      = 1 << 1
    F_BLOCK_ON_FULL = 1 << 2
    F_CLOSING       = 1 << 3


cdef enum:
    Q_OK      =  1
    Q_EMPTY   =  0
    Q_FULL    = -2
    Q_ERR     = -1
    Q_PARTIAL =  2
    Q_SKIP    =  3
    Q_NO_CONSUMER = -3

cdef enum QueueMode:
    SPSC = 0
    SPMC = 1
    MPSC = 2
    MPMC = 3

cdef struct QueueSlot:
    char*    buf
    size_t   size
    uint32_t seq_id
    uint16_t chunk_idx
    uint16_t total_chunks

cdef struct PublishEntry:
    atomic[uint64_t] seq  

cdef struct ConsumerCtx:
    uint32_t expected_seq
    uint16_t expected_chunk
    char*    assemble_buf
    size_t   assemble_used
    size_t   assemble_cap


cdef struct QueueImpl:
    atomic[uint64_t] tail
    uint8_t[56]      pad_tail
    
    atomic[uint64_t] head
    uint8_t[56]      pad_head

    size_t      capacity_mask
    size_t      slot_size
    QueueSlot*  slots
    char*       slot_bufs
    atomic[uint64_t] running
    uint8_t     flags
    QueueMode   mode
    
    PublishEntry* publish    
    
    uint32_t seq_counter

    atomic[uint64_t] reader_active_mask
    atomic[uint64_t] reader_min_pos
    uint8_t[48]      pad_bcast

    atomic[uint64_t] reader_pos[64]
    
    ConsumerCtx[64] consumer_ctx
    
    push_fn   fn_push
    push_fn   fn_try_push
    push_fn   fn_push_var
    push_fn   fn_try_push_var

    pop_fn    fn_pop
    pop_fn    fn_try_pop
    pop_fn    fn_pop_var
    pop_fn    fn_try_pop_var

    borrow_fn fn_pop_borrow
    commit_fn fn_pop_commit

    register_fn   fn_register_consumer
    unregister_fn fn_unregister_consumer



cdef int spsc_push(void*, const char*, size_t) noexcept nogil
cdef int spsc_try_push(void*, const char*, size_t) noexcept nogil
cdef int spsc_push_var(void*, const char*, size_t) noexcept nogil
cdef int spsc_try_push_var(void*, const char*, size_t) noexcept nogil

cdef int spsc_pop (void*, char**, size_t*) noexcept nogil
cdef int spsc_try_pop (void*, char**, size_t*) noexcept nogil
cdef int spsc_pop_borrow (void*, char**, size_t*) noexcept nogil
cdef void spsc_pop_commit (void*) noexcept nogil
cdef int spsc_pop_var (void*, char**, size_t*) noexcept nogil
cdef int spsc_try_pop_var (void*, char**, size_t*) noexcept nogil


cdef int spmc_push (void*, const char*, size_t) noexcept nogil
cdef int spmc_try_push(void*, const char*, size_t) noexcept nogil
cdef int spmc_push_var(void*, const char*, size_t) noexcept nogil
cdef int spmc_try_push_var(void*, const char*, size_t) noexcept nogil

cdef int spmc_pop (void*, char**, size_t*) noexcept nogil
cdef int spmc_try_pop (void*, char**, size_t*) noexcept nogil
cdef int spmc_pop_borrow (void*, char**, size_t*) noexcept nogil
cdef void spmc_pop_commit (void*) noexcept nogil
cdef int spmc_pop_var (void*, char**, size_t*) noexcept nogil
cdef int spmc_try_pop_var (void*, char**, size_t*) noexcept nogil



cdef int mpsc_push (void*, const char*, size_t) noexcept nogil
cdef int mpsc_try_push(void*, const char*, size_t) noexcept nogil
cdef int mpsc_push_var(void*, const char*, size_t) noexcept nogil
cdef int mpsc_try_push_var(void*, const char*, size_t) noexcept nogil

cdef int mpsc_pop (void*, char**, size_t*) noexcept nogil
cdef int mpsc_try_pop (void*, char**, size_t*) noexcept nogil
cdef int mpsc_pop_borrow (void*, char**, size_t*) noexcept nogil
cdef void mpsc_pop_commit (void*) noexcept nogil
cdef int mpsc_pop_var (void*, char**, size_t*) noexcept nogil
cdef int mpsc_try_pop_var (void*, char**, size_t*) noexcept nogil



cdef int mpmc_push (void*, const char*, size_t) noexcept nogil
cdef int mpmc_try_push(void*, const char*, size_t) noexcept nogil
cdef int mpmc_push_var(void*, const char*, size_t) noexcept nogil
cdef int mpmc_try_push_var(void*, const char*, size_t) noexcept nogil

cdef int mpmc_pop (void*, char**, size_t*) noexcept nogil
cdef int mpmc_try_pop (void*, char**, size_t*) noexcept nogil
cdef int mpmc_pop_borrow (void*, char**, size_t*) noexcept nogil
cdef void mpmc_pop_commit (void*) noexcept nogil
cdef int mpmc_pop_var (void*, char**, size_t*) noexcept nogil
cdef int mpmc_try_pop_var (void*, char**, size_t*) noexcept nogil

 

cdef void queue_notify(void* ctx) noexcept nogil

cdef int  register_consumer  (void*, uint32_t*) noexcept nogil
cdef void unregister_consumer(void*, uint32_t)  noexcept nogil

cdef int queue_close(void* ctx, long timeout_ms = ?) noexcept nogil


cdef class Queue:
    cdef:
        QueueImpl _q
        
    cdef int push(self, const char* data, size_t size) noexcept nogil
    cdef int try_push(self, const char* data, size_t size) noexcept nogil
    cdef int push_var(self, const char* data, size_t size) noexcept nogil
    cdef int try_push_var(self, const char* data, size_t size) noexcept nogil

    cdef int pop(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef int pop_borrow(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef void pop_commit(self) noexcept nogil
    cdef int try_pop(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef int pop_var(self, char** out_buf, size_t* out_size) noexcept nogil
    cdef int try_pop_var(self, char** out_buf, size_t* out_size) noexcept nogil

    cdef int  register_consumer  (self, uint32_t* out_id)  noexcept nogil
    cdef void unregister_consumer(self, uint32_t reader_id) noexcept nogil

    cdef int close(self, long timeout_ms=?) noexcept nogil
