from libc.stdint  cimport uint32_t, uint16_t
from cykit.spsc_queue cimport SPSCQueue
from cykit.common cimport thread

cdef extern from *:
    """
    #ifdef _WIN32
        #include <winsock2.h>
        #include <ws2_ipdef.h>

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
                (struct sockaddr*)&b->addr, sizeof(b->addr)
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

    cdef struct in_addr:
        uint32_t s_addr

    cdef struct sockaddr_in:
        uint16_t sin_family
        uint16_t sin_port
        in_addr sin_addr    

    cdef struct NotifyBridge:
        PLATFORM_SOCKET sock
        sockaddr_in addr

    cdef void sig_notify(NotifyBridge* b) noexcept nogil
    cdef void sig_wait(NotifyBridge* b) noexcept nogil



cdef extern from "<arpa/inet.h>" nogil:
    uint32_t inet_addr(const char*)
    uint16_t htons(uint16_t)



ctypedef void (*ad_push_fn_t) (
    AsyncDispatcher,
    const char* data,
    size_t size
) noexcept nogil

ctypedef bytes (*ad_pop_fn_t) (
    AsyncDispatcher
) except +



ctypedef void (*sd_push_fn_t) (
    SyncDispatcher,
    const char* data,
    size_t size
) noexcept nogil



ctypedef void (*td_push_fn_t)(
    ThreadedDispatcher,
    const char* data,
    size_t size
) noexcept nogil



cdef class AsyncDispatcher:
    cdef:
        SPSCQueue         _q
        NotifyBridge _bridge

        ad_push_fn_t push
        ad_pop_fn_t _pop_func

        object            _callback 
        object            _sock     
        object            _task  

    cpdef void setup(self, str host=?)
    cdef void __try_push(self, const char* data, size_t size) noexcept nogil    
    cdef void __try_push_var(self, const char* data, size_t size) noexcept nogil
    cdef inline bytes _try_pop(self) noexcept
    cdef inline bytes _try_pop_var(self) noexcept


cdef class SyncDispatcher:
    cdef:
        SPSCQueue _q 
        NotifyBridge _bridge

        bint _daemon
        bint _variable_size

        sd_push_fn_t push

        object            _callback 
        object            _sock  

    cpdef void setup(self, str host=?)
    cdef void __try_push(self, const char* data, size_t size) noexcept nogil
    cdef void __try_push_var(self, const char* data, size_t size) noexcept nogil
    cpdef void _try_pop(self)
    cpdef void _try_pop_var(self)
    cdef bytes __try_pop(self)
    cdef bytes __try_pop_var(self)
    cpdef void close(self)


cdef class ThreadedDispatcher:
    cdef:
        SPSCQueue       _q
        thread          _thread
        object          _callback
        bint            _variable_size
        td_push_fn_t    push

    cdef void _push(self, const char* data, size_t size) noexcept nogil
    cdef void _push_var(self, const char* data, size_t size) noexcept nogil
    cdef void _reader(self) noexcept nogil
    cdef void _reader_var(self) noexcept nogil
    cpdef void setup(self)
    cpdef void close(self)



## Only for testing purpose ::

cdef class AsyncQueue:
    cdef:
        SPSCQueue _q

        object _loop
        object _callback 
        object _lock
        object _notify_cond 
        object _task
    
    cpdef start_dispatcher(self, object callback)