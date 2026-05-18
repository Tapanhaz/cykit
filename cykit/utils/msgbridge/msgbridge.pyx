from cykit.spsc_queue cimport SPSC_OK
from cykit.common cimport (
    make_thread, 
    buf_to_cbuf, 
    str_to_cbuf, 
    obj_to_cbuf,
    Py_buffer,
    PyBuffer_Release,
    PyObject,
    Py_DECREF
)

import asyncio


cdef inline void _thrded_reader_entry(void* arg) noexcept nogil:
    (<ThreadedDispatcher>arg)._reader()

cdef inline void _thrded_reader_var_entry(void* arg) noexcept nogil:
    (<ThreadedDispatcher>arg)._reader_var()



cdef class AsyncDispatcher:

    def __cinit__(
                self,
                object callback,
                size_t capacity= 16384,
                size_t slot_size= 2048,
                bint overwrite= False,
                bint zerocopy= False,
                bint variable_size= False
                ):

        self._q = SPSCQueue(
                        slot_size= slot_size,
                        capacity= capacity,
                        overwrite= overwrite,
                        zerocopy= zerocopy
                        )
                        
        self._bridge.sock        = -1
        self._callback           = callback
        self._sock               = None
        self._task               = None

        if variable_size:
            self.push = <ad_push_fn_t>self.__try_push_var
            self._pop_func = <ad_pop_fn_t>self._try_pop_var        
        else:
            self.push = <ad_push_fn_t>self.__try_push
            self._pop_func = <ad_pop_fn_t>self._try_pop

    cpdef void setup(self, str host='127.0.0.1'):
        import socket as _socket

        loop = asyncio.get_running_loop()

        sock = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
        sock.setblocking(False)
        sock.bind((host, 0))
        self._sock = sock

        ip, port = sock.getsockname()
        self._bridge.addr.sin_family      = 2
        self._bridge.addr.sin_port        = htons(port)
        self._bridge.addr.sin_addr.s_addr = inet_addr(ip.encode())
        self._bridge.sock                 = sock.fileno()

        self._task  = loop.create_task(self._reader(loop, sock))

    cdef void __try_push(self, const char* data, size_t size) noexcept nogil:
        if self._q.try_push(data, size) > 0:
            sig_notify(&self._bridge)
    
    cdef void __try_push_var(self, const char* data, size_t size) noexcept nogil:
        if self._q.try_push_var(data, size) == SPSC_OK:
            sig_notify(&self._bridge)

    async def _reader(self, loop, sock):
        cdef bytes msg

        while True:
            msg = self._pop_func(self)
            if msg is None:
                await loop.sock_recv(sock, 1) 
            else:
                await self._callback(msg)

    cdef inline bytes _try_pop(self):
        cdef:
            char* buf
            size_t size 

        if self._q.try_pop(&buf, &size) == SPSC_OK:
            return buf[:size]
        return None

    cdef inline bytes _try_pop_var(self):
        cdef:
            char* buf
            size_t size 

        if self._q.try_pop(&buf, &size) == SPSC_OK:
            return buf[:size]
        return None    

    def close(self)-> None:        
        if self._task is not None:
            task = self._task
            self._task = None
            loop = task.get_loop()

            def _finalize():
                if not task.done():
                    task.cancel()

            loop.call_soon_threadsafe(_finalize)

        if self._sock is not None:
            self._sock.close()
            self._sock = None
    
    def __dealloc__(self):
        self.close()





cdef class SyncDispatcher:
    def __cinit__(
            self,
            object callback,
            size_t capacity      = 16384,
            size_t slot_size     = 2048,
            bint zerocopy        = False,
            bint overwrite       = False,
            bint variable_size   = False,
            bint daemon       = False
        ):
    
        self._callback      = callback
        self._variable_size = variable_size
        self._daemon = daemon

        self._bridge.sock        = -1
        self._sock               = None

        self._q = SPSCQueue(
                        slot_size= slot_size,
                        capacity= capacity,
                        overwrite= overwrite,
                        zerocopy= zerocopy
                        )

        if variable_size:
            self.push = <sd_push_fn_t>self.__try_push_var     
        else:
            self.push = <sd_push_fn_t>self.__try_push

    cpdef void setup(self, str host='127.0.0.1'):
        import socket as _socket
        import threading

        sock = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
        sock.setblocking(True)
        sock.bind((host, 0))
        self._sock = sock

        ip, port = sock.getsockname()
        self._bridge.addr.sin_family      = 2
        self._bridge.addr.sin_port        = htons(port)
        self._bridge.addr.sin_addr.s_addr = inet_addr(ip.encode())
        self._bridge.sock                 = sock.fileno()

        if self._variable_size:
            threading.Thread(target= self._try_pop_var, daemon= self._daemon).start()
        else:
            threading.Thread(target= self._try_pop, daemon= self._daemon).start()


    cdef void __try_push(self, const char* data, size_t size) noexcept nogil:
        if self._q.try_push(data, size) > 0:
            sig_notify(&self._bridge)
    
    cdef void __try_push_var(self, const char* data, size_t size) noexcept nogil:
        if self._q.try_push_var(data, size) > 0:
            sig_notify(&self._bridge)

    cpdef void _try_pop(self):
        cdef bytes msg

        while True:
            msg = self.__try_pop()
            if msg is None:
                with nogil:
                    sig_wait(&self._bridge)
            else:
                self._callback(msg)
    
    cpdef void _try_pop_var(self):
        cdef bytes msg

        while True:
            msg = self.__try_pop_var()
            if msg is None:
                with nogil:
                    sig_wait(&self._bridge)
            else:
                self._callback(msg)

    cdef inline bytes __try_pop(self):
        cdef:
            char* buf 
            size_t size 
        
        if self._q.try_pop(&buf, &size) == SPSC_OK:
            return buf[:size]
        return None
    
    cdef inline bytes __try_pop_var(self):
        cdef:
            char* buf 
            size_t size 
        
        if self._q.try_pop_var(&buf, &size) == SPSC_OK:
            return buf[:size]
        return None
    
    cpdef void close(self):
        sig_notify(&self._bridge)

    def __dealloc__(self):
        self.close()





cdef class ThreadedDispatcher:

    def __cinit__(
            self,
            object callback,
            size_t capacity      = 16384,
            size_t slot_size     = 2048,
            bint zerocopy        = False, 
            bint block_on_full   = False,
            bint overwrite       = False,
            bint variable_size   = False
        ):

        self._callback      = callback
        self._variable_size = variable_size

        self._q = SPSCQueue(
            slot_size     = slot_size,
            capacity      = capacity,
            zerocopy      = zerocopy,
            overwrite     = overwrite,
            block_on_full = block_on_full
        )

        if variable_size:
            self.push = <td_push_fn_t>self._push_var
        else:
            self.push = <td_push_fn_t>self._push

    cpdef void setup(self):
        if self._variable_size:
            self._thread = make_thread(_thrded_reader_var_entry, <void*>self)
        else:
            self._thread = make_thread(_thrded_reader_entry, <void*>self)
        
        self._thread.detach()

    cdef void _push(self, const char* data, size_t size) noexcept nogil:
        self._q.push(data, size)

    cdef void _push_var(self, const char* data, size_t size) noexcept nogil:
        self._q.push_var(data, size)

    cdef void _reader(self) noexcept nogil:
        cdef:
            char*  buf
            size_t size            

        while True:
            if self._q.pop_borrow(&buf, &size) != SPSC_OK:
                break

            with gil:
                self._callback(buf[:size])

            self._q.pop_commit()
            

    cdef void _reader_var(self) noexcept nogil:
        cdef:
            char*  buf
            size_t size

        while True:
            if self._q.pop_var(&buf, &size) != SPSC_OK:
                break
            with gil:
                self._callback(buf[:size])

    cpdef void close(self):
        self._q.close()

        with nogil:
            if self._thread.joinable():
                self._thread.join()

    def __dealloc__(self):
        self.close()



## Only for testing purpose ::

cdef class AsyncQueue:        
    def __init__(
            self,
            object loop= None,
            size_t slot_size= 1024,
            size_t capacity= 16384,
            bint overwrite= False,
            bint zerocopy= False,
            bint block_on_full= False
        ):

        self._q = SPSCQueue(
                        slot_size,
                        capacity,
                        overwrite,
                        zerocopy,
                        block_on_full
                    )

        self._lock = asyncio.Lock()
        self._notify_cond = asyncio.Condition(self._lock)

        if loop is None:
            try:
                self._loop = asyncio.get_running_loop()
            except RuntimeError:
                raise RuntimeError(
                    "AsyncQueue must be created inside a running event loop."
                )
        else:
            self._loop = loop
    
    cpdef start_dispatcher(self, object callback):
        self._callback = callback        
        self._task = self._loop.create_task(self.__dispatch()) 

    async def push_buf(self, object msg):
        cdef:
            Py_buffer view
            const char* data 
            size_t size
        
        view.buf = NULL

        try:
            if buf_to_cbuf(msg, &view, &data, &size)!= -1:
                if self._q.try_push(data, size) == SPSC_OK:

                    async with self._notify_cond:
                        self._notify_cond.notify()
        finally:
            if view.buf != NULL:
                PyBuffer_Release(&view)

    async def push_obj(self, object msg):
        cdef:
            PyObject* pb = NULL
            const char* data
            size_t size

        try:
            if obj_to_cbuf(msg, &pb, &data, &size) == 0:
                if self._q.try_push(data, size) == SPSC_OK:
                    async with self._notify_cond:
                        self._notify_cond.notify()

        finally:
            if pb != NULL:
                Py_DECREF(pb)
    
    async def push_str(self, object msg):
        cdef:
            const char* data
            size_t size

        if str_to_cbuf(msg, &data, &size) == 0:
            if self._q.try_push(data, size) == SPSC_OK:
                async with self._notify_cond:
                    self._notify_cond.notify()


    async def pop(self):
        cdef:
            char* data 
            size_t size 
        
        while True:
            if self._q.try_pop(&data, &size) == SPSC_OK:
                return data[:size]
            else:
                async with self._notify_cond:
                    await self._notify_cond.wait()

    
    async def __dispatch(self):
        cdef:
            char* data 
            size_t size 

        while True:
            if self._q.try_pop(&data, &size) == SPSC_OK:
                await self._callback(data[:size])
            
            else:
                async with self._notify_cond:
                    await self._notify_cond.wait()     


    async def shutdown(self, *excinfo):
        async with self._notify_cond:
            self._notify_cond.notify_all()

        if self._task is not None:
            self._task.cancel()

            try:
                await self._task
            except asyncio.CancelledError:
                pass
                