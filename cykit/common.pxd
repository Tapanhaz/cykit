
from libc.stdint cimport uint32_t, uint64_t
from cpython.ref cimport PyObject
from libcpp.atomic cimport atomic

cdef extern from "Python.h":
    void Py_INCREF(PyObject*)
    void Py_DECREF(PyObject*)
    void Py_XDECREF(PyObject*)
    
    char* PyBytes_AsString(object)
    char* PyBytes_AS_STRING(PyObject*)
    Py_ssize_t PyBytes_Size(object)
    Py_ssize_t PyBytes_GET_SIZE(PyObject*)
    PyObject* PyBytes_FromStringAndSize(char*, Py_ssize_t)
    PyObject* PyUnicode_FromString(const char*)
    
    PyObject* PyObject_CallFunctionObjArgs(PyObject*, ...)
    int Py_AddPendingCall(int (*func)(void*), void*)
    PyObject* PyObject_Vectorcall(PyObject *callable, PyObject * const *args, size_t nargsf, PyObject *kwnames)
    
    PyObject* PyImport_ImportModule(char*)
    PyObject* PyObject_GetAttrString(PyObject*, char*)
    PyObject* PyObject_HasAttrString(PyObject*, char*)
    int PyCallable_Check(PyObject*)
    PyObject* PyObject_CallFunction(PyObject*, char*, ...)
    PyObject* PyObject_CallMethod(PyObject*, char*, char*, ...)    
    
    void PyErr_SetString(PyObject *exception, const char *message)
    PyObject* PyErr_Format(PyObject* exception, const char* fmt, ...)
    void PyErr_SetObject(PyObject *exception, PyObject *value)
    PyObject* PyExc_RuntimeError
    PyObject* PyExc_ValueError
    PyObject* PyExc_ImportError
    PyObject* PyExc_TypeError
    void PyErr_Print()
    void PyErr_Clear()
    PyObject* PyErr_Occurred()
    void PyErr_SetInterrupt()

    int PyLong_Check(PyObject* obj)     
    int PyLong_CheckExact(PyObject* obj) 
    long PyLong_AsLong(PyObject* obj) 
    PyObject* PyLong_FromLong(long v) 

    int PyObject_GetBuffer(PyObject*, Py_buffer*, int)
    void PyBuffer_Release(Py_buffer*)
    const char* PyUnicode_AsUTF8AndSize(PyObject*, Py_ssize_t*)
    int PyBytes_AsStringAndSize(PyObject*, char**, Py_ssize_t*)
    PyObject* PyObject_Bytes(PyObject *o)
    int PyBUF_SIMPLE

    ctypedef struct Py_buffer:
        void* buf
        Py_ssize_t len

cdef extern from "<atomic>" namespace "std" nogil:
    cdef enum memory_order:
        memory_order_relaxed
        memory_order_acquire
        memory_order_release
        memory_order_seq_cst
    
    cdef cppclass atomic_uint64_t "std::atomic<uint64_t>":
        atomic_uint64_t() nogil
        atomic_uint64_t(uint64_t) nogil
        uint64_t load(int) nogil
        void store(uint64_t, int) nogil
        uint64_t fetch_add(uint64_t, int) nogil

    void atomic_thread_fence(memory_order)
    bint atomic_compare_exchange_strong[T](atomic[T]* obj, T* expected, T desired) noexcept
    bint atomic_compare_exchange_strong_explicit[T](atomic[T]* obj, T* expected, T desired, 
                                                     memory_order success, memory_order failure) noexcept
    void atomic_wait[uint64_t](const atomic[uint64_t]* obj, uint64_t val) noexcept
    void atomic_wait[uint64_t](volatile atomic[uint64_t]* obj, uint64_t val) noexcept
    void atomic_notify_all[uint64_t](atomic[uint64_t]* obj) noexcept
    void atomic_notify_all[uint64_t](volatile atomic[uint64_t]* obj) noexcept
    void atomic_notify_one[uint64_t](const atomic[uint64_t]* obj, uint64_t val) noexcept
    void atomic_notify_one[uint64_t](volatile atomic[uint64_t]* obj) noexcept

cdef extern from *:
    """
    #ifdef _WIN32
        #include <malloc.h>
        #define aligned_alloc_(alignment, size)  _aligned_malloc(size, alignment)
        #define aligned_free_(ptr)               _aligned_free(ptr)
    #else
        #include <stdlib.h>
        #define aligned_alloc_(alignment, size)  aligned_alloc(alignment, size)
        #define aligned_free_(ptr)               free(ptr)
    #endif
    """ 
    void* aligned_alloc_(size_t alignment, size_t size) noexcept nogil
    void  aligned_free_(void* ptr) noexcept nogil


cdef extern from "<thread>" namespace "std" nogil:
    cdef cppclass thread:
        thread() noexcept
        void join() noexcept
        void detach() noexcept
        bint joinable() noexcept

cdef extern from *:
    """
    #include <thread>

    template<typename F, typename A>
    std::thread make_thread(F f, A a) { return std::thread(f, a); }
    """
    thread make_thread[F, A](F f, A a) noexcept nogil


cdef bint is_power_of_two(uint32_t n) noexcept nogil

cdef int buf_to_cbuf(object msg, Py_buffer* view, const char** data, size_t* size) except -1
cdef int str_to_cbuf(object msg, const char** data, size_t* size) except -1
cdef int obj_to_cbuf(object msg, PyObject** pb, const char** data, size_t* size) except -1