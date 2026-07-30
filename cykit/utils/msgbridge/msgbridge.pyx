"""
@file msgbridge.pyx
@brief Message dispatchers and communication primitives.
@date 2026-06-18
@copyright Part of the https://github.com/Tapanhaz/cykit library.

@details
Provides utilities for transferring messages between Cython and
Python execution contexts, along with native message pipes and
buffer conversion helpers.

@note
- AsyncDispatcher delivers messages to Python asyncio callbacks.
- SyncDispatcher delivers messages to Python callbacks.
- CyPipe provides direct Cython-to-Cython message transport.
- CBufferView converts Python objects into native buffer views.
- Supports fixed-size and variable-size message transport.
"""

from cykit.queue cimport QueueMode, Q_OK, BridgeQueue
from cykit.common cimport (
    Py_buffer,
    PyBUF_SIMPLE,
    PyBuffer_Release,
    PyObject_GetBuffer,
    PyUnicode_AsUTF8AndSize,
    PyBytes_AS_STRING,
    PyBytes_GET_SIZE,
    PyObject_CheckBuffer,
    PyObject,
    Py_INCREF,
    Py_DECREF,
    memory_order_acquire,
    memory_order_release,
    memory_order_seq_cst
)
from libc.errno cimport errno, EPERM, EACCES

from cpython.bytes cimport PyBytes_FromStringAndSize

import warnings
import msgspec
import threading

import asyncio
import sys

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
                    warnings.warn(
                        "SO_RCVBUFFORCE needs CAP_NET_ADMIN "
                        "(sudo or setcap). Falling back to SO_RCVBUF.",
                        RuntimeWarning
                    )
                else:
                    warnings.warn(f"SO_RCVBUFFORCE failed ({e}). Falling back.", RuntimeWarning)

                sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, recvbuf)
        else:
            sock.setsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF, recvbuf)
        
    #print(f"SO_RCVBUF= {sock.getsockopt(_socket.SOL_SOCKET, _socket.SO_RCVBUF)}")

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

        self._q = Queue(
                        slot_size= slot_size,
                        capacity= capacity,
                        mode = QueueMode.SPSC,
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
            sig_wait_begin(&self._bridge)
            if self._q.try_pop(&buf, &size) == Q_OK:
                sig_wait_end(&self._bridge)
                await self._callback(buf[:size])

                counter = (counter + 1) & 127
                if counter == 0:
                    await asyncio.sleep(0)

            else:
                await loop.sock_recv(sock, 1)
                sig_wait_end(&self._bridge)
                
    async def __reader_var(self, loop, sock):        
        cdef:
            char* buf
            size_t size 
            unsigned int counter = 0

        while self._running:
            sig_wait_begin(&self._bridge)
            if self._q.try_pop_var(&buf, &size) == Q_OK:
                sig_wait_end(&self._bridge)
                await self._callback(buf[:size])

                counter = (counter + 1) & 127
                if counter == 0:
                    await asyncio.sleep(0)

            else:
                await loop.sock_recv(sock, 1)
                sig_wait_end(&self._bridge)

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

        self._thread = None

        self._q = BridgeQueue(
                        capacity= capacity,
                        slot_size= slot_size,
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
            target = (
                self.__try_pop_var
                if self._nonblocking
                else self.__pop_var
            )
        else:
            target = (
                self.__try_pop
                if self._nonblocking
                else self.__pop
            )

        self._thread = threading.Thread(target=target, daemon= self._detach)

        self._thread.start()

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

    cdef void __try_pop(self):
        cdef:
            char* buf 
            size_t size

        while self._running.load(memory_order_acquire):
            sig_wait_begin(&self._bridge)
            if self._q.try_pop(&buf, &size) == Q_OK:
                sig_wait_end(&self._bridge)
                self._callback(PyBytes_FromStringAndSize(buf, size))
            else:
                with nogil:
                    sig_wait(&self._bridge)
                sig_wait_end(&self._bridge)
            
    cdef void __try_pop_var(self):
        cdef:
            char* buf 
            size_t size

        while self._running.load(memory_order_acquire):
            sig_wait_begin(&self._bridge)
            if self._q.try_pop_var(&buf, &size) == Q_OK:
                sig_wait_end(&self._bridge)
                self._callback(PyBytes_FromStringAndSize(buf, size))
            else:
                with nogil:
                    sig_wait(&self._bridge)
                sig_wait_end(&self._bridge)
    

    cdef void __pop(self):
        cdef:
            char*  buf
            size_t size

        while self._running.load(memory_order_acquire):
            if self._q.pop(&buf, &size) == Q_OK:
                self._callback(PyBytes_FromStringAndSize(buf, size))
        

    cdef void __pop_var(self):
        cdef:
            char*  buf
            size_t size

        while self._running.load(memory_order_acquire):
            if self._q.pop_var(&buf, &size) == Q_OK:
                self._callback(PyBytes_FromStringAndSize(buf, size))
    
    cpdef void close(self):
        self._running.store(0, memory_order_seq_cst)

        if self._q is not None:
            with nogil:
                self._q.close()         

        if self._nonblocking:
            with nogil:
                sig_notify(&self._bridge)        

        if not self._detach:
            if self._thread:     
                self._thread.join()
        
        if self._sock is not None:
            self._sock.close()
            self._sock = None               

    def __dealloc__(self):
        self.close()

# endregion


# region CyPipe (cython -> cython)

cdef class CyPipe:

    def __cinit__(self):
        self._q  = None

    def __init__(
            self,
            size_t capacity    = 16384,
            size_t slot_size   = 2048,
            bint zerocopy      = False,
            bint overwrite     = False,
            bint block_on_full = False,
            bint variable_size = False
        ):
    
        self._q = Queue(
                        slot_size= slot_size,
                        capacity= capacity,
                        mode = QueueMode.SPSC,
                        overwrite= overwrite,
                        zerocopy= zerocopy,
                        block_on_full= block_on_full
                        )

        if variable_size:
            self.push = <cc_push_fn_t>self.__push_var
            self.pop = <cc_pop_fn_t>self.__pop_var
            self.commit = <cc_commit_fn_t>self._noop_commit
        else:
            self.push = <cc_push_fn_t>self.__push
            self.pop = <cc_pop_fn_t>self.__pop
            self.commit = <cc_commit_fn_t>self._pop_commit
    
    cdef inline int __push(self, const char* data, size_t size) noexcept nogil:
        return self._q.push(data, size)

    cdef inline int __push_var(self, const char* data, size_t size) noexcept nogil:
        return self._q.push_var(data, size)
    
    cdef inline int __pop(self, char** data, size_t* size) noexcept nogil:
        return self._q.pop_borrow(data, size)

    cdef inline int __pop_var(self, char** data, size_t* size) noexcept nogil:
        return self._q.pop_var(data, size)
    
    cdef inline void _pop_commit(self) noexcept nogil:
        self._q.pop_commit()

    cdef inline void _noop_commit(self) noexcept nogil:
        pass
    

# endregion


# region CBufferView

cdef inline int buf_to_cbuf(
        object msg,
        Py_buffer* view,
        const char** data,
        size_t* size
    ) except -1:

    if PyObject_GetBuffer(<PyObject*>msg, view, PyBUF_SIMPLE) != 0:
        return -1  

    data[0] = <char*>view.buf
    size[0] = <size_t>view.len

    return 0


cdef inline int str_to_cbuf(
        object msg,
        const char** data,
        size_t* size
    ) except -1:
    cdef Py_ssize_t n

    data[0] = <char*>PyUnicode_AsUTF8AndSize(<PyObject*>msg, &n)
    if data[0] == NULL:
        return -1

    size[0] = <size_t>n
    return 0


cdef inline int obj_to_cbuf(
        object encoder,
        object msg,
        PyObject** pb,
        const char** data,
        size_t* size
    ) except -1:
    cdef object encoded

    encoded = encoder.encode(msg)

    pb[0] = <PyObject*>encoded
    Py_INCREF(pb[0])
    data[0] = PyBytes_AS_STRING(pb[0])
    size[0] = <size_t>PyBytes_GET_SIZE(pb[0])
    return 0


cdef inline int bytes_to_cbuf(
        object msg,
        const char** data,
        size_t* size    
    ) except -1:
    
    data[0] = <const char*>PyBytes_AS_STRING(<PyObject*>msg)
    size[0] = <size_t>PyBytes_GET_SIZE(<PyObject*>msg)
    return 0




cdef class CBufferView:    
    
    def __cinit__(self):
        self.data = NULL
        self.size = 0
        self._pb = NULL
        self._view.buf = NULL
    
    def __init__(self, MsgKind msg_kind=MsgKind.MIXED) -> None:    

        self._msgpack_encoder = msgspec.msgpack.Encoder()   

        if msg_kind == MsgKind.BYTES:
            self._load = <cb_load_fn_t>self._load_bytes
        elif msg_kind == MsgKind.BUF:
            self._load = <cb_load_fn_t>self._load_buf
        elif msg_kind == MsgKind.STR:
            self._load = <cb_load_fn_t>self._load_str
        elif msg_kind == MsgKind.OBJ:
            self._load = <cb_load_fn_t>self._load_obj 
        else:
            self._load = <cb_load_fn_t>self._load_mixed  

    cdef inline int load(self, object msg) except -1:
        return self._load(self, msg)  
    
    cdef inline int _load_bytes(self, object msg) except -1:
        return bytes_to_cbuf(msg, &self.data, &self.size)
    
    cdef inline int _load_buf(self, object msg) except -1:
        if self._view.buf != NULL:
            PyBuffer_Release(&self._view)

        return buf_to_cbuf(msg, &self._view, &self.data, &self.size)

    cdef inline int _load_str(self, object msg) except -1:
        return str_to_cbuf(msg, &self.data, &self.size)
    
    cdef inline int _load_obj(self, object msg) except -1:
        if self._pb != NULL:
            Py_DECREF(self._pb)
            self._pb = NULL

        return obj_to_cbuf(self._msgpack_encoder, msg, &self._pb, &self.data, &self.size)        

    cdef inline int _load_mixed(self, object msg) except -1:
        if isinstance(msg, bytes):
            return self._load_bytes(msg)
        elif isinstance(msg, str):
            return self._load_str(msg)
        elif PyObject_CheckBuffer(<PyObject*>msg):
            return self._load_buf(msg)
        else:
            return self._load_obj(msg)

    def __dealloc__(self):
        if self._view.buf != NULL:
            PyBuffer_Release(&self._view)
        if self._pb != NULL:
            Py_DECREF(self._pb)
            self._pb = NULL

# endregion



