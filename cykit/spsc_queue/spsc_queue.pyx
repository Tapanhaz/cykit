# distutils: language = c++
# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
# cython: infer_types=True, nonecheck=False, initializedcheck=False

from libc.stdint cimport uint64_t, uint32_t
from libc.stddef cimport size_t
from libc.string cimport memcpy
from cykit.common cimport (
    atomic_wait,
    atomic_notify_one,
    atomic_thread_fence,
    memory_order_relaxed,
    memory_order_acquire,
    memory_order_release, 
    is_power_of_two,
    PyErr_Format,
    PyErr_SetString,
    PyExc_ValueError,
    PyExc_RuntimeError
)

cdef inline void init_spscq(SPSCQueue* q, size_t slot_size, size_t capacity) noexcept nogil:
    q.head.store(0, memory_order_relaxed)
    q.tail.store(0, memory_order_relaxed)

    q.capacity_mask = capacity - 1
    q.slot_size = slot_size
    q.running.store(1, memory_order_relaxed)

cdef inline bint spscq_push(SPSCQueue* q, const char* data, size_t size, bint block) noexcept nogil:
    cdef:
        SPSCSlot* slot
        uint64_t head
        uint64_t tail
        uint64_t idx

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_acquire)
        tail = q.tail.load(memory_order_relaxed)

        if tail - head < q.capacity_mask + 1:
            if size > q.slot_size:
                size = q.slot_size

            idx = tail & q.capacity_mask
            slot = &q.slots[idx]

            memcpy(slot.buf, data, size)
            slot.size = size

            atomic_thread_fence(memory_order_release)
            q.tail.store(tail + 1, memory_order_release)

            atomic_notify_one(&q.tail)
            return 1

        if not block:
            return 0 

        atomic_wait(&q.head, head)

    return 0 
    

cdef inline bint spscq_pop(SPSCQueue* q, char** out_buf, size_t* out_size, bint block) noexcept nogil:
    cdef:
        SPSCSlot* slot
        uint64_t head
        uint64_t tail
        uint64_t idx

    while q.running.load(memory_order_acquire):
        head = q.head.load(memory_order_relaxed)
        tail = q.tail.load(memory_order_acquire)

        if head != tail:
            idx = head & q.capacity_mask
            slot = &q.slots[idx]
            out_buf[0] = slot.buf
            out_size[0] = slot.size
            atomic_thread_fence(memory_order_acquire)
            q.head.store(head + 1, memory_order_release)
            
            atomic_notify_one(&q.head)
            return 1

        if not block:
            return 0

        atomic_wait(&q.tail, tail)

    return 0

cdef inline void spscq_close(SPSCQueue* q) noexcept nogil:
    q.running.store(0, memory_order_relaxed)
    atomic_notify_one(&q.tail)
    atomic_notify_one(&q.head)



cdef class PySPSCQueue:

    cdef:
        SPSCQueue* _q
        uint32_t _slot_size
        uint32_t _capacity
        bint _block
        object callback

    def __cinit__(
            self,
            uint32_t slot_size= 2048,
            uint32_t capacity= 65536,
            bint block= True,
            object producer_callback= None,
            object consumer_callback= None
        ):

        if not is_power_of_two(slot_size):
            PyErr_Format(PyExc_ValueError, b"slot_size must be a power of 2, got :: %u", slot_size)
        if not is_power_of_two(capacity):
            PyErr_Format(PyExc_ValueError, b"capacity must be a power of 2, got :: %u", capacity)            
        if not (producer_callback &  consumer_callback):
            PyErr_SetString(PyExc_RuntimeError, b"cython / python / python async callback functions required for producer and consumer side")

        self._slot_size = slot_size
        self._capacity = capacity
        self._block = block

        



