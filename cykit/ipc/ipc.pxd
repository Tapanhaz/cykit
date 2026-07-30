from libcpp.atomic cimport atomic
from cykit.ipc.shared_memory cimport *
#from cykit.common cimport *
from cykit.common cimport (
    htonl,
    ntohl,
    cpu_pause,
    atomic_bool,
    builtin_ctzll,
    placement_new,
    is_power_of_two,
    placement_destroy,
    atomic_thread_fence,
    atomic_compare_exchange_strong_explicit,
    memory_order,
)
from libc.stdint cimport uint32_t, uint64_t, uint8_t, uint16_t,intptr_t, int64_t
from libc.stddef cimport size_t
from libc.stdlib cimport malloc, free, realloc
from libc.string cimport memcpy, memset, strdup
from libcpp.atomic cimport atomic, memory_order
from libcpp cimport bool as cbool
from cykit.utils.atomic cimport (
    CACHELINE,
    CachelineBoundary,
    PaddedAtomicU64
)


cdef enum:
    IPC_OK            =  1
    IPC_EMPTY         =  0
    IPC_FULL          = -1
    IPC_ERR           = -2
    IPC_CLOSING       = -3
    IPC_DRAIN_TIMEOUT = -4
    IPC_ORPHANED      = -5
    IPC_NO_CONSUMER   = -6

cdef enum:
    F_IPC_CLOSING         = 1 << 0
    F_IPC_BLOCK_ON_FULL   = 1 << 1
    F_IPC_OVERWRITE       = 1 << 2
    F_IPC_WAIT_CONSUMERS  = 1 << 3
    F_IPC_ABORT           = 1 << 4
    F_IPC_LAG_EVICT       = 1 << 5

cdef enum:
    INITIAL_SEQUENCE = 1
    MAX_CONSUMERS = 64
    POP_ORPHAN_STALL_MS = 3000
    LAG_EVICT_DIVISOR = 3

cdef enum class RunningMode:
    SPMC = 0
    MPSC = 1
    MPMC = 2

cdef enum class ProcessRole:
    Producer = 1
    Consumer = 2 

ctypedef atomic[uint64_t] atomic_uint64
ctypedef atomic[bint]     atomic_bint

cdef const int ALIGN_BYTES = 8


cdef struct SlotSeq:
    PaddedAtomicU64 seq

cdef struct ReaderSlot:
    PaddedAtomicU64 pos
    PaddedAtomicU64 lag_flag_pos

cdef struct SharedDataImpl:
    atomic[uint32_t] magic_number
    uint32_t         mode
    uint32_t         block_count
    uint32_t         block_size
    uint32_t         slot_stride
    atomic[int]      process_count
    atomic_bool     sem_initialized
    atomic[uint32_t] shared_flags

    PaddedAtomicU64  global_sequence
    atomic[int]      writer_count
    atomic_bool     writer_active

    PaddedAtomicU64  consumer_sequence
    atomic_bool     consumer_active
    atomic_bool     consumer_waiting

    PaddedAtomicU64  reader_active_mask
    PaddedAtomicU64  reader_min_position
    
    CachelineBoundary _boundary

    interprocess_mutex     notify_mutex
    interprocess_condition notify_cond

    char[0] data



cdef struct Context:
    int running    
    ProcessRole role

    SharedDataImpl* sd
    
    atomic[int] process_alive
    SharedMemory* shm_obj
    Semaphore* sem_obj
    
    SlotSeq* slot_sequences
    ReaderSlot* reader_slots
    char* slot_buffers    

    uint32_t         reader_id
    uint64_t         borrow_pos
    uint32_t         borrow_idx
    uint32_t         local_flags

    char*            assemble_buf
    size_t           assemble_used
    size_t           assemble_cap
    uint32_t         expected_seq
    uint16_t         expected_chunk

    char*            scratch_buf
    size_t           scratch_cap


cdef struct SharedMemSystem:
    const char* shm_name
    const char* sem_name
    uint32_t block_count
    uint32_t block_size
    RunningMode mode
    Context* ctx
    cbool lag_evict


cdef int init_shared_memory(SharedMemSystem* shmsys) except -1 nogil

cdef int init_producer_system(SharedMemSystem* shmsys) except -1 nogil
cdef int init_consumer_system(SharedMemSystem* shmsys) except -1 nogil

cdef void notify_context(void* ctx_ptr) noexcept nogil

cdef int ipc_spmc_push(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_spmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_spmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_spmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil

cdef int ipc_spmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_spmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_spmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef void ipc_spmc_pop_commit(void* ctx) noexcept nogil
cdef int ipc_spmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_spmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil

cdef int ipc_mpsc_push(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_mpsc_try_push(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_mpsc_push_var(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_mpsc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil

cdef int ipc_mpsc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_mpsc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_mpsc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef void ipc_mpsc_pop_commit(void* ctx) noexcept nogil
cdef int ipc_mpsc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_mpsc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil

cdef int ipc_mpmc_push(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_mpmc_try_push(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_mpmc_push_var(void* ctx, const char* data, size_t size) noexcept nogil
cdef int ipc_mpmc_try_push_var(void* ctx, const char* data, size_t size) noexcept nogil

cdef int ipc_mpmc_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_mpmc_try_pop(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_mpmc_pop_borrow(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef void ipc_mpmc_pop_commit(void* ctx) noexcept nogil
cdef int ipc_mpmc_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil
cdef int ipc_mpmc_try_pop_var(void* ctx, char** out_buf, size_t* out_size) noexcept nogil

cdef void cleanup_consumer_system(SharedMemSystem* shmsys) noexcept nogil
cdef int cleanup_producer_system(SharedMemSystem* shmsys) noexcept nogil
cdef int  shm_close(SharedMemSystem* shmsys, long timeout_ms = ?, long close_signal_wait_ms = ?) noexcept nogil

cdef int detach_producer(SharedMemSystem* shmsys) noexcept nogil
cdef int detach_consumer(
    SharedMemSystem* shmsys,
    long timeout_ms = ?,
    long close_signal_wait_ms = ?,
    long stall_ms= ?
) noexcept nogil
cdef int shutdown_pipeline(SharedMemSystem* shmsys, long timeout_ms = ?) noexcept nogil
      