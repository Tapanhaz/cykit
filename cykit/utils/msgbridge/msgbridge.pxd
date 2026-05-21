from libc.stdint  cimport uint32_t, uint16_t
from cykit.spsc_queue cimport SPSCQueue
from cykit.common cimport thread, atomic_bool, PyObject

cdef extern from *:
    """
    #ifdef _WIN32
        #include <winsock2.h>
        #include <ws2tcpip.h>

        #pragma comment(lib, "Ws2_32.lib")

        typedef SOCKET PLATFORM_SOCKET;

    #else
        #include <sys/socket.h>
        #include <netinet/in.h>
        #include <arpa/inet.h>

        typedef int PLATFORM_SOCKET;

        #define INVALID_SOCKET -1
    #endif

    struct NotifyBridge {
        PLATFORM_SOCKET sock;
        struct sockaddr_in addr;
    };

    static inline void sig_notify(struct NotifyBridge* b) {
        if (b && b->sock != (PLATFORM_SOCKET)INVALID_SOCKET) {
            char signal = 1;

            sendto(
                b->sock,
                &signal,
                1,
                0,
                (struct sockaddr*)&b->addr,
                sizeof(b->addr)
            );
        }
    }

    static inline int sig_wait(struct NotifyBridge* b) {
        char buf;

        return recvfrom(
            b->sock,
            &buf,
            1,
            0,
            NULL,
            NULL
        );
    }
    """

    ctypedef int PLATFORM_SOCKET

    enum:
        AF_INET

    cdef struct in_addr:
        uint32_t s_addr

    cdef struct sockaddr_in:
        uint16_t sin_family
        uint16_t sin_port
        in_addr sin_addr

    cdef struct NotifyBridge:
        PLATFORM_SOCKET sock
        sockaddr_in addr

    int inet_pton(
        int af,
        const char *src,
        void *dst
    ) nogil

    uint16_t htons(uint16_t) nogil

    cdef void sig_notify(NotifyBridge* b) noexcept nogil
    cdef int sig_wait(NotifyBridge* b) noexcept nogil



ctypedef int (*ad_push_fn_t) (
    AsyncDispatcher,
    const char* data,
    size_t size
) noexcept nogil


ctypedef int (*sd_push_fn_t) (
    SyncDispatcher,
    const char* data,
    size_t size
) noexcept nogil




cdef class AsyncDispatcher:
    cdef:
        SPSCQueue         _q
        NotifyBridge _bridge

        ad_push_fn_t push

        object _callback 
        object _sock     
        object _task  
        bint   _running
        bint   _variable_size

    cpdef void setup(self, str host=?, int recvbuf= ?)
    cdef inline int __try_push(self, const char* data, size_t size) noexcept nogil    
    cdef inline int __try_push_var(self, const char* data, size_t size) noexcept nogil


cdef class SyncDispatcher:
    cdef:
        SPSCQueue _q 
        NotifyBridge _bridge

        bint _detach
        bint _variable_size

        sd_push_fn_t push

        object            _callback 
        object            _sock  
        bint            _nonblocking      
        atomic_bool _running
        thread          _thread

    cpdef void setup(self, str host=?, int recvbuf=?)

    cdef inline int __try_push(self, const char* data, size_t size) noexcept nogil
    cdef inline int __try_push_var(self, const char* data, size_t size) noexcept nogil
    
    cdef inline int __push(self, const char* data, size_t size) noexcept nogil
    cdef inline int __push_var(self, const char* data, size_t size) noexcept nogil
    
    cdef void __try_pop(self) noexcept nogil
    cdef void __try_pop_var(self) noexcept nogil
    
    cdef void __pop(self) noexcept nogil
    cdef void __pop_var(self) noexcept nogil
    
    cpdef void close(self)





ctypedef int (*cc_push_fn_t) (
    CyPipe,
    const char* data,
    size_t size
) noexcept nogil

ctypedef int (*cc_pop_fn_t) (
    CyPipe,
    char** data,
    size_t* size
) noexcept nogil

ctypedef int (*cc_commit_fn_t) (
    CyPipe
) noexcept nogil


cdef class CyPipe:
    cdef:
        SPSCQueue _q 

        cc_push_fn_t   push
        cc_pop_fn_t    pop
        cc_commit_fn_t commit
    
    cdef inline int __push(self, const char* data, size_t size) noexcept nogil
    cdef inline int __push_var(self, const char* data, size_t size) noexcept nogil
    cdef inline int __pop(self, char** data, size_t* size) noexcept nogil
    cdef inline int __pop_var(self, char** data, size_t* size) noexcept nogil
    cdef inline void _pop_commit(self) noexcept nogil
    cdef inline void _noop_commit(self) noexcept nogil





cdef enum MsgKind:
    MSG_BYTES  = 0
    MSG_STR    = 1
    MSG_BUF    = 2
    MSG_OBJ    = 3
    MSG_MIXED  = 4

ctypedef int (*cb_load_fn_t)(CBufferView, object) except -1

cdef int buf_to_cbuf(object msg, Py_buffer* view, const char** data, size_t* size) except -1
cdef int str_to_cbuf(object msg, const char** data, size_t* size) except -1
cdef int obj_to_cbuf(object msg, PyObject** pb, const char** data, size_t* size) except -1
cdef int bytes_to_cbuf(object msg, const char** data, size_t* size) except -1


cdef class CBufferView:
    cdef:
        const char* _data 
        size_t      _size 
        int         _kind

        Py_buffer   _view
        PyObject*   _pb

        cb_load_fn_t     load
        
    cdef inline int _load_bytes(self, object msg) except -1
    cdef inline int _load_buf(self, object msg) except -1
    cdef inline int _load_str(self, object msg) except -1
    cdef inline int _load_obj(self, object msg) except -1
    cdef inline int _load(self, object msg) except -1



## Only for testing purpose ::

cdef class AsyncQueue:
    cdef:
        SPSCQueue _q

        object _loop
        object _callback 
        object _lock
        object _notify_cond 
        object _task
        bint   _running
    
    cpdef start_dispatcher(self, object callback)