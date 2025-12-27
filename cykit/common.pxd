
from libc.stdint cimport uint32_t, uint64_t
from cpython.ref cimport PyObject
from libcpp.atomic cimport atomic

cdef extern from "Python.h":
    void Py_INCREF(PyObject*)
    void Py_DECREF(PyObject*)
    void Py_XDECREF(PyObject*)
    
    char* PyBytes_AsString(object)
    Py_ssize_t PyBytes_Size(object)
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


cdef bint is_power_of_two(uint32_t n) nogil