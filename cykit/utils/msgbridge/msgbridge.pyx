from cykit.spsc_queue cimport SPSC_OK
from cykit.common cimport (
    make_thread, 
    buf_to_cbuf, 
    str_to_cbuf, 
    obj_to_cbuf,
    Py_buffer,
    PyBuffer_Release,
    PyObject,
    Py_INCREF,
    Py_DECREF,
    PyBytes_FromStringAndSize,
    memory_order_acquire,
    memory_order_release,
    memory_order_seq_cst
)
from libc.errno cimport errno, EPERM, EACCES
from cykit.cylogger import DefaultLogger

import asyncio
import sys

logger = DefaultLogger()




cpdef object setup_socket(bint blocking, int recvbuf):
    import socket as _socket

    sock = _socket.socket(_socket.AF_INET, _socket.SOCK_DGRAM)
    sock.setblocking(blocking)

    if recvbuf > 0:
        if sys.platform.startswith('linux'):

            try:
                sock.setsockopt(_socket.SOL_SOCKET, 33, recvbuf) #SO_RCVBUFFORCE 
            except OSError as e:
                if e.errno in (EPERM, EACCES):
                    logger.warn(
                        "SO_RCVBUFFORCE needs CAP_NET_ADMIN "
                        "(sudo or setcap). Falling back to SO_RCVBUF."
                    )
                else:
                    logger.warn(f"WARNING: SO_RCVBUFFORCE failed ({e}). Falling back.")

                sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, recvbuf)
        else:
            sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, recvbuf)
        
    logger.debug(f"SO_RCVBUF= {sock.getsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF)}")

    return sock


# region Async Dispatcher

cdef class AsyncDispatcher:
    
    def __cinit__(self):
        self._bridge.sock = -1
        self._sock        = None
        self._q           = None
        self._task        = None
        self._running     = True

    def __init__(
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
                        
        self._callback    = callback
        
        self._variable_size = variable_size

        if variable_size:
            self.push = <ad_push_fn_t>self.__try_push_var    
        else:
            self.push = <ad_push_fn_t>self.__try_push

    cpdef void setup(self, str host='127.0.0.1', int recvbuf= 16777216):

        self._sock = setup_socket(blocking= False, recvbuf= recvbuf)

        self._sock.bind((host, 0))

        ip, port = self._sock.getsockname()

        self._bridge.addr.sin_family = AF_INET
        self._bridge.addr.sin_port   = htons(port)

        inet_pton(
            AF_INET,
            ip.encode(),
            &self._bridge.addr.sin_addr
        )

        self._bridge.sock = self._sock.fileno()

        loop = asyncio.get_running_loop()      

        if self._variable_size:
            self._task = loop.create_task(self.__reader_var(loop, self._sock))
        else:
            self._task = loop.create_task(self.__reader(loop, self._sock))

    cdef inline int __try_push(self, const char* data, size_t size) noexcept nogil:
        cdef int ret = self._q.try_push(data, size)
        if ret > 0:
            sig_notify(&self._bridge)
        return ret
    
    cdef inline int __try_push_var(self, const char* data, size_t size) noexcept nogil:
        cdef int ret = self._q.try_push_var(data, size)
        if ret > 0:
            sig_notify(&self._bridge)
        return ret
     
    async def __reader(self, loop, sock):        
        cdef:
            char* buf
            size_t size 
            unsigned int counter = 0 

        while self._running:
            if self._q.try_pop(&buf, &size) == SPSC_OK:
                await self._callback(buf[:size])

                counter = (counter + 1) & 127
                if counter == 0:
                    await asyncio.sleep(0)

            else:
                await loop.sock_recv(sock, 1) 
                
    async def __reader_var(self, loop, sock):        
        cdef:
            char* buf
            size_t size 
            unsigned int counter = 0

        while self._running:
            if self._q.try_pop_var(&buf, &size) == SPSC_OK:
                await self._callback(buf[:size])

                counter = (counter + 1) & 127
                if counter == 0:
                    await asyncio.sleep(0)

            else:
                await loop.sock_recv(sock, 1) 

    def close(self)-> None:  
        self._running = False  

        if self._q is not None:
            with nogil:
                self._q.close() 
        
        sig_notify(&self._bridge)

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

# endregion



# region Sync Dispatcher

cdef inline void _sync_try_pop_entry(void* arg) noexcept nogil:
    (<SyncDispatcher>arg).__try_pop()

cdef inline void _sync_try_pop_var_entry(void* arg) noexcept nogil:
    (<SyncDispatcher>arg).__try_pop_var()

cdef inline void _sync_pop_entry(void* arg) noexcept nogil:
    (<SyncDispatcher>arg).__pop()

cdef inline void _sync_pop_var_entry(void* arg) noexcept nogil:
    (<SyncDispatcher>arg).__pop_var()


cdef class SyncDispatcher:

    def __cinit__(self):
        self._bridge.sock = -1
        self._sock        = None
        self._q           = None
        
        self._running.store(1, memory_order_release)

    def __init__(
            self,
            object callback,
            size_t capacity    = 16384,
            size_t slot_size   = 2048,
            bint zerocopy      = False,
            bint overwrite     = False,
            bint block_on_full = False,
            bint variable_size = False,
            bint detach       = True,
            bint nonblocking   = True
        ):
    
        self._callback      = callback
        self._variable_size = variable_size
        self._detach = detach
        self._nonblocking = nonblocking

        self._q = SPSCQueue(
                        slot_size= slot_size,
                        capacity= capacity,
                        overwrite= overwrite,
                        zerocopy= zerocopy,
                        block_on_full= block_on_full
                        )

        if variable_size:
            if nonblocking:
                self.push = <sd_push_fn_t>self.__try_push_var     
            else:
                self.push = <sd_push_fn_t>self.__push_var
        else:
            if nonblocking:
                self.push = <sd_push_fn_t>self.__try_push
            else:
                self.push = <sd_push_fn_t>self.__push


    cpdef void setup(self, str host='127.0.0.1', int recvbuf= 16777216):

        if self._nonblocking:
            self._sock = setup_socket(blocking=True, recvbuf=recvbuf)

            self._sock.bind((host, 0))

            ip, port = self._sock.getsockname()

            self._bridge.addr.sin_family = AF_INET
            self._bridge.addr.sin_port   = htons(port)

            inet_pton(
                AF_INET,
                ip.encode(),
                &self._bridge.addr.sin_addr
            )

            self._bridge.sock = self._sock.fileno()


        if self._variable_size:
            if self._nonblocking:
                self._thread = make_thread(_sync_try_pop_var_entry, <void*>self)
            else:
                self._thread = make_thread(_sync_pop_var_entry, <void*>self)
        else:
            if self._nonblocking:
                self._thread = make_thread(_sync_try_pop_entry, <void*>self) 
            else:
                self._thread = make_thread(_sync_pop_entry, <void*>self) 
        
        if self._detach:
            self._thread.detach()

    cdef inline int __try_push(self, const char* data, size_t size) noexcept nogil:
        cdef int ret = self._q.try_push(data, size)
        if ret > 0:
            sig_notify(&self._bridge)
        return ret
    
    cdef inline int __try_push_var(self, const char* data, size_t size) noexcept nogil:
        cdef int ret = self._q.try_push_var(data, size)
        if ret > 0:
            sig_notify(&self._bridge)
        return ret
    
    cdef inline int __push(self, const char* data, size_t size) noexcept nogil:
        return self._q.push(data, size)

    cdef inline int __push_var(self, const char* data, size_t size) noexcept nogil:
        return self._q.push_var(data, size)

    cdef void __try_pop(self) noexcept nogil:
        cdef:
            char* buf 
            size_t size
            PyObject* cb 
        
        with gil:
            cb = <PyObject*>self._callback
            Py_INCREF(cb)

        while self._running.load(memory_order_acquire):
            if self._q.try_pop(&buf, &size) == SPSC_OK:
                with gil:
                    (<object>cb)(<object>PyBytes_FromStringAndSize(buf, size))
            else:
                sig_wait(&self._bridge)
        
        with gil:
            Py_DECREF(cb)
    
    cdef void __try_pop_var(self) noexcept nogil:
        cdef:
            char* buf 
            size_t size
            PyObject* cb 
        
        with gil:
            cb = <PyObject*>self._callback
            Py_INCREF(cb)

        while self._running.load(memory_order_acquire):
            if self._q.try_pop_var(&buf, &size) == SPSC_OK:
                with gil:
                    (<object>cb)(<object>PyBytes_FromStringAndSize(buf, size))
            else:
                sig_wait(&self._bridge)
        
        with gil:
            Py_DECREF(cb)
    
    cdef void __pop(self) noexcept nogil:
        cdef:
            char*  buf
            size_t size   

            PyObject* cb      

        with gil:
            cb = <PyObject*>self._callback
            Py_INCREF(cb)

        while self._running.load(memory_order_acquire):
            if self._q.pop_borrow(&buf, &size) == SPSC_OK:
                with gil:
                    (<object>cb)(<object>PyBytes_FromStringAndSize(buf, size))

                self._q.pop_commit()

        with gil:
            Py_DECREF(cb)            

    cdef void __pop_var(self) noexcept nogil:
        cdef:
            char*  buf
            size_t size
            PyObject* cb      

        with gil:
            cb = <PyObject*>self._callback
            Py_INCREF(cb)
            

        while self._running.load(memory_order_acquire):
            if self._q.pop_var(&buf, &size) == SPSC_OK:
                with gil:
                    (<object>cb)(<object>PyBytes_FromStringAndSize(buf, size))
        
        with gil:
            Py_DECREF(cb)
    
    cpdef void close(self):
        self._running.store(0, memory_order_seq_cst)

        if self._q is not None:
            with nogil:
                self._q.close()         

        if self._nonblocking:
            with nogil:
                sig_notify(&self._bridge)                
        
        if self._sock is not None:
            self._sock.close()
            self._sock = None        

        if not self._detach:
            if self._thread.joinable():
                self._thread.join()

    def __dealloc__(self):
        self.close()

# endregion



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
                if self._q.try_push(data, size) > 0:

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
                if self._q.try_push(data, size) > 0:
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
            if self._q.try_push(data, size) > 0:
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