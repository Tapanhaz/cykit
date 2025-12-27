

from cython cimport bint
from cykit.common cimport (
    Py_INCREF,
    Py_DECREF,
    Py_XDECREF,
    PyErr_Clear,
    PyErr_Print,
    PyLong_Check,
    PyLong_AsLong,
    PyErr_SetString,
    PyCallable_Check,
    PyExc_ValueError,
    Py_AddPendingCall,
    PyExc_ImportError,
    PyExc_RuntimeError,
    PyObject_Vectorcall,
    PyObject_CallFunction,
    PyImport_ImportModule,
    PyObject_GetAttrString,
    PyBytes_FromStringAndSize,
    PyObject_CallFunctionObjArgs
)



cdef int _fire_and_forget_sync_callback(void* arg) noexcept:  ## ==>> This is only for very low count of (occasional) messages 
    cdef:
        PyObject* decoded = <PyObject*>arg
        PyObject* args[1]
        PyObject* result

    args[0] = decoded
    result = PyObject_Vectorcall(global_sync_callback, args, 1, NULL)
    Py_XDECREF(result)
    Py_DECREF(decoded)  

    return 0

cdef class CyMsgBroker:
    
    def __cinit__(
            self,
            object callback,
            bint sync_blocking_callback = True,
            object loop = None,
            size_t c_callback_ptr = 0 
            ):

        self._c_callback = <c_callback_func>c_callback_ptr
        self._use_c_callback = (c_callback_ptr != 0)

        if not self._use_c_callback:
            if callback is None:
                PyErr_SetString(PyExc_ValueError, b"Either callback or c_callback_ptr must be provided\n")
                return
            
            self._callback = <PyObject*>callback
            if self._callback != NULL:
                Py_INCREF(self._callback)
        else:
            self._callback = NULL

        self._is_async = False
        self._sync_blocking_callback = sync_blocking_callback

        self._asyncio_module = NULL
        self._get_async_loop_func = NULL
        self._create_task_method = NULL
        self._call_soon_threadsafe_func = NULL
        self._run_coroutine_threadsafe_func = NULL
        self._loop = NULL

        if loop:
            self._loop = <PyObject*>loop
            Py_INCREF(self._loop)

        self._msgspec_module = NULL
        self._msgspec_json_decoder  = NULL
        self._msgspec_decode_method = NULL

        if self.__init_class() == 0:
            return

    cdef inline int __init_class(self):
        if self._use_c_callback:
            self._process_message_func = <void (*)(CyMsgBroker, char*, size_t) noexcept nogil>self._process_message_c
            return 1

        if self._callback == NULL or not PyCallable_Check(self._callback):
            PyErr_SetString(PyExc_ValueError, b"Callback is either NULL or not Callable. \n")
            return 0
        
        if self.__init_methods() == 0:
            return 0

        if self._is_async_callback():
            self._is_async = True
            
            if self.__init_async() == 0:
                return 0
            
            if self._loop == NULL:
                self._loop = self._get_loop()
                if self._loop != NULL:
                    Py_INCREF(self._loop)
                else:
                    return 0
            
            if self._loop != NULL:
                self._call_soon_threadsafe_func = PyObject_GetAttrString(self._loop, "call_soon_threadsafe")
                if self._call_soon_threadsafe_func != NULL:
                    Py_INCREF(self._call_soon_threadsafe_func)
                else:
                    PyErr_SetString(PyExc_ValueError, b"Method call soon threadsafe isn't found. \n")
                    return 0
            
        self._register_output_func()
        self._process_message_func = <void (*)(CyMsgBroker, char*, size_t) noexcept nogil>self._process_message_py

        return 1

    cdef inline int __init_async(self):
        self._asyncio_module = PyImport_ImportModule("asyncio")
        if self._asyncio_module == NULL:
            PyErr_Print()
            return 0     

        self._get_async_loop_func = PyObject_GetAttrString(self._asyncio_module, "get_running_loop")
        if self._get_async_loop_func == NULL:
            PyErr_Clear()
            self._get_async_loop_func = PyObject_GetAttrString(self._asyncio_module, "get_event_loop")
            if self._get_async_loop_func == NULL:
                PyErr_Print()
                return 0
        
        self._create_task_method= PyObject_GetAttrString(self._asyncio_module, "create_task")
        if self._create_task_method == NULL:
            PyErr_Print()
            return 0
        
        self._run_coroutine_threadsafe_func = PyObject_GetAttrString(self._asyncio_module, "run_coroutine_threadsafe")
        if self._run_coroutine_threadsafe_func == NULL:
            PyErr_Print()
            return 0

        Py_INCREF(self._asyncio_module)
        Py_INCREF(self._get_async_loop_func)
        Py_INCREF(self._create_task_method)
        Py_INCREF(self._run_coroutine_threadsafe_func)

        return 1
    
    cdef inline int __init_methods(self):
        cdef PyObject* json_module

        self._msgspec_module = PyImport_ImportModule("msgspec")
        if self._msgspec_module == NULL:
            PyErr_SetString(PyExc_ImportError, b"Module msgspec is not found. \n")
            return 0
        
        json_module = PyObject_GetAttrString(self._msgspec_module, "json")
        if json_module == NULL:
            PyErr_SetString(PyExc_ValueError, b"msgspec.json is not available. \n")
            return 0
            
        self._msgspec_json_decoder = PyObject_GetAttrString(json_module, "Decoder")
        if self._msgspec_json_decoder == NULL:
            PyErr_SetString(PyExc_ValueError, b"msgspec.json.Decoder is not available. \n")
            Py_DECREF(json_module)
            return 0
            
        Py_DECREF(json_module)
                
        self._msgspec_json_decoder = PyObject_CallFunction(self._msgspec_json_decoder, NULL)
        if self._msgspec_json_decoder == NULL:
            PyErr_SetString(PyExc_ValueError, b"msgspec.json.Decoder() is not available. \n")
            return 0
            
        self._msgspec_decode_method = PyObject_GetAttrString(self._msgspec_json_decoder, "decode")
        if self._msgspec_decode_method == NULL:
            PyErr_SetString(PyExc_ValueError, b"msgspec.json.Decoder().decode() method is not available. \n")
            return 0
        
        return 1
            
    cdef inline int _is_async_callback(self):
        cdef:
            long flags
            PyObject* code_obj
            PyObject* flags_obj
            
        code_obj = PyObject_GetAttrString(self._callback, b"__code__")
        if code_obj == NULL:
            PyErr_Clear()  
            return 0

        flags_obj = PyObject_GetAttrString(code_obj, b"co_flags")
        Py_DECREF(code_obj)

        if flags_obj == NULL:
            PyErr_Clear()
            return 0

        if not PyLong_Check(flags_obj):
            Py_DECREF(flags_obj)
            return 0

        flags = PyLong_AsLong(flags_obj)
        Py_DECREF(flags_obj)

        return (flags & 0X80) != 0 or (flags & 0X100) != 0
    
    cdef PyObject* _get_loop(self) noexcept:
        if self._get_async_loop_func != NULL:
            loop = PyObject_CallFunctionObjArgs(self._get_async_loop_func, NULL)
            if loop == NULL:
                PyErr_SetString(PyExc_ValueError, b"Could not get running event loop. \n")
                return NULL
        else:
            PyErr_SetString(PyExc_RuntimeError, b"Could not get event loop. \n")
            return NULL
        return loop      

    cdef void _register_output_func(self):
        if self._is_async:
            self._callback_func = <void (*)(CyMsgBroker, PyObject*)>self._send_async
        else:
            if self._sync_blocking_callback:
                self._callback_func = <void (*)(CyMsgBroker, PyObject*)>self._send_sync_blocking
            else:
                self._callback_func = <void (*)(CyMsgBroker, PyObject*)>self._send_sync
                self._register_sync_callback()
    
    cdef void _register_sync_callback(self):
        global global_sync_callback
        global_sync_callback = self._callback
        Py_INCREF(global_sync_callback)
    
    cdef void _send_async(self, PyObject* data):
        cdef:
            PyObject* coro
            PyObject* result
            PyObject* args[1]
            PyObject* args2[2]

        args[0] = data
        coro = PyObject_Vectorcall(self._callback, args, 1, NULL)

        if coro == NULL:
            PyErr_Print()
            Py_DECREF(data)
            return
        args2[0] = self._create_task_method
        args2[1] = coro

        result = PyObject_Vectorcall(self._call_soon_threadsafe_func, args2, 2, NULL)

        if result == NULL:
            PyErr_Print()
        else:
            Py_DECREF(result)

        Py_DECREF(coro)
        Py_DECREF(data)
    
    cdef void _send_sync(self, PyObject* data):
        Py_INCREF(data)   
        Py_AddPendingCall(_fire_and_forget_sync_callback, <void*>data)

        Py_DECREF(data)
        
    cdef void _send_sync_blocking(self, PyObject* arg):
        cdef:
            PyObject* result
            PyObject* args[1]
        
        args[0] = arg
        result = PyObject_Vectorcall(self._callback, args, 1, NULL)
        
        if result != NULL:
            Py_DECREF(result)

        Py_DECREF(arg)
    
    cdef void _process_message_c(self, char* data, size_t size) noexcept nogil:
        self._c_callback(data, size)
    
    cdef void _process_message_py(self, char* data, size_t size) noexcept with gil:
        cdef:
            PyObject* py_bytes = PyBytes_FromStringAndSize(data, size)
            PyObject* decoded_data = PyObject_CallFunction(self._msgspec_decode_method, "O", py_bytes)
            PyObject* result

        Py_DECREF(py_bytes)
        self._callback_func(self, decoded_data)
    
    cdef void process_message(self, char* data, size_t size) noexcept nogil:
        self._process_message_func(self, data, size)
    
    def __dealloc__(self):
        if self._callback != NULL:
            Py_DECREF(self._callback)

        if self._asyncio_module != NULL:
            Py_XDECREF(self._asyncio_module)

        if self._get_async_loop_func != NULL:
            Py_XDECREF(self._get_async_loop_func)

        if self._create_task_method != NULL:
            Py_XDECREF(self._create_task_method)
        
        if self._call_soon_threadsafe_func != NULL: 
            Py_XDECREF(self._call_soon_threadsafe_func)
        
        if self._loop != NULL:
            Py_DECREF(self._loop)

        if self._msgspec_module != NULL:
            Py_XDECREF(self._msgspec_module)
        
        if self._msgspec_json_decoder != NULL:
            Py_XDECREF(self._msgspec_json_decoder)
        
        if self._msgspec_decode_method != NULL:
            Py_XDECREF(self._msgspec_decode_method)
        
        if global_sync_callback != NULL:
            Py_DECREF(global_sync_callback)
