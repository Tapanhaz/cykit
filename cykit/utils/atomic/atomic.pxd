

from libcpp.atomic cimport atomic
from libc.stdint cimport uint64_t

cdef extern from "cacheline.hpp" namespace "cykit" nogil:
    size_t CACHELINE
    struct CachelineBoundary:
        pass
    struct PaddedAtomicU64:
        atomic[uint64_t] value
    cppclass CachelinePadded[T]:
        T value


cdef extern from "atomic_wait.hpp" namespace "cykit" nogil:
    void atomic_wait[T](atomic[T]* obj, T expected)
    void atomic_notify_one[T](atomic[T]* obj)
    void atomic_notify_all[T](atomic[T]* obj)

    cppclass WaiterMetaPadded[T]:
        pass
    cppclass WaiterMetaPaddedBare[T]:
        pass

    cppclass WaiterMeta[T]:
        pass
    cppclass WaiterMetaBare[T]:
        pass
        
    void atomic_wait[T, Meta](atomic[T]* obj, T expected, Meta* meta)
    void atomic_notify_one[T, Meta](atomic[T]* obj, Meta* meta)
    void atomic_notify_all[T, Meta](atomic[T]* obj, Meta* meta)
