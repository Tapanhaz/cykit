
from cpython.ref cimport PyObject

ctypedef void (*c_callback_func)(char* data, size_t size) noexcept nogil
cdef PyObject* global_sync_callback = NULL

cdef int _fire_and_forget_sync_callback(void* arg) noexcept

cdef class CyMsgBroker:
    cdef:
        PyObject* _callback 
        bint _is_async
        bint _sync_blocking_callback

        c_callback_func _c_callback
        bint _use_c_callback

        PyObject* _asyncio_module
        PyObject* _get_async_loop_func
        PyObject* _create_task_method
        PyObject* _call_soon_threadsafe_func
        PyObject* _run_coroutine_threadsafe_func
        PyObject* _loop
        PyObject* _msgspec_module
        PyObject* _msgspec_json_decoder
        PyObject* _msgspec_decode_method

        void (*_callback_func)(CyMsgBroker, PyObject*)
        void (*_process_message_func)(CyMsgBroker, char*, size_t) noexcept nogil

    cdef inline int __init_class(self)
    cdef inline int __init_async(self)
    cdef inline int __init_methods(self)
    cdef inline int _is_async_callback(self)
    cdef PyObject* _get_loop(self) noexcept
    cdef void _register_output_func(self)
    cdef void _register_sync_callback(self)
    cdef void _send_async(self, PyObject* data)
    cdef void _send_sync(self, PyObject* data)
    cdef void _send_sync_blocking(self, PyObject* arg)
    cdef void _process_message_c(self, char* data, size_t size) noexcept nogil
    cdef void _process_message_py(self, char* data, size_t size) noexcept with gil

    cdef void process_message(self, char* data, size_t size) noexcept nogil
    