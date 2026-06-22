"""
@file cylogger.pyx
@brief High-performance structured logging framework with synchronous sinks.
@date 2026-06-18
@copyright Part of the https://github.com/Tapanhaz/cykit library.

@details
Provides a Cython wrapper around the underlying C++ spdlog logging backend,
including console, file, rotating file, daily file, TCP, UDP, HTTP,
and SMTP sinks. Supports custom formatting, colorized output, Python
stdlib logging interception, and network delivery.

@note
- All network-backed handlers use lock-free queues internally.
- TCP, UDP, HTTP, and SMTP handlers run dedicated worker threads.
- TCP and UDP handlers do not use spdlog's built-in sinks.
- HTTP and SMTP handlers are provided by cylogger.
- Python's standard logging module can be redirected via
  intercept_stdlib_logging=True.
- Diagnostic logging (`diag=True`) is global to the process.
  Only one internal diagnostic logger can be registered at a time,
  as logger names are globally unique within spdlog.
"""

import traceback
import logging as py_logging
from cykit.common cimport (
    PyObject,
    Py_DECREF,
    PyObject_Str, 
    PyErr_WarnEx,
    PyExc_TypeError,
    PyExc_ValueError,
    PyErr_SetString,
    PyUnicode_Format,
    PyUnicode_AsUTF8,
    PyExc_RuntimeWarning,
    memory_order_acquire,
    memory_order_relaxed,
    memory_order_seq_cst,
    make_thread,
    Py_DECREF
)
from libcpp cimport bool as cbool
from libc.stdint cimport uint8_t, uint16_t


cdef bint _diag_initialized = False


cpdef enum class SmtpAuthMethod:
    NONE = <int>SmtpAuth.Off
    PLAIN = <int>SmtpAuth.Plain
    LOGIN = <int>SmtpAuth.Login
    XOAUTH2 = <int>SmtpAuth.XOAuth2

cpdef enum class SmtpSecurityMode:
    PLAIN = <int>SmtpMode.Plain
    STARTTLS = <int>SmtpMode.StartTls
    SMTPS = <int>SmtpMode.Smtps

cpdef enum class SmtpErrorCategory:
    NONE = <int>SmtpErrorClass.NoErr
    TRANSIENT = <int>SmtpErrorClass.Transient
    PERMANENT = <int>SmtpErrorClass.Permanent
    SERVICE_DOWN = <int>SmtpErrorClass.ServiceDown

# =========================================================================
# ======================      TRAMPOLINES       ===========================
# =========================================================================

cdef int _tcp_push_fn(const char* data, size_t length, void* ud) noexcept nogil:
    return (<TcpSocketHandler>ud)._queue.push_var(data, length)

cdef void _tcp_flush_fn(void* ud) noexcept nogil:
    pass

cdef int _udp_push_fn(const char* data, size_t length, void* ud) noexcept nogil:
    return (<UdpSocketHandler>ud)._queue.push_var(data, length)

cdef void _udp_flush_fn(void* ud) noexcept nogil:
    pass

cdef int _http_push_fn(const char* data, size_t length, void* ud) noexcept nogil:
    return (<HttpHandler>ud)._queue.push_var(data, length)

cdef void _http_flush_fn(void* ud) noexcept nogil:
    pass

cdef int _smtp_push_fn(const char* data, size_t length, void* ud) noexcept nogil:
    return (<SmtpHandler>ud)._queue.push_var(data, length)

cdef void _smtp_flush_fn(void* ud) noexcept nogil:
    pass


ctypedef void (*worker_fn_t)(void*) noexcept nogil


cdef void _tcp_worker_fn(void* arg) noexcept nogil:
    (<TcpSocketHandler>arg)._tcp_loop()

cdef void _udp_worker_fn(void* arg) noexcept nogil:
    (<UdpSocketHandler>arg)._udp_loop()

cdef void _http_worker_fn(void* arg) noexcept nogil:
    (<HttpHandler>arg)._http_loop()

cdef void _smtp_worker_fn(void* arg) noexcept nogil:
    (<SmtpHandler>arg)._smtp_loop()

# ===================================================================================

cdef inline const char* _format_msg(
            PyObject* fmt, 
            PyObject* args, 
            PyObject** out
        ) except NULL:

    cdef PyObject* result = NULL
    if args == NULL:
        result = PyObject_Str(fmt)
    else:
        result = PyUnicode_Format(fmt, args)
    if result == NULL:
        out[0] = NULL
        return NULL
    out[0] = result
    return PyUnicode_AsUTF8(result)

# =========================================================================
# =========================      HANDLERS       ===========================
# =========================================================================

cdef class LogHandler:

    def __init__(
        self,  
        bint color=True, 
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.TRACE
            ):
        self.color = color
        self.pattern = pattern
        self.level = level


cdef class UserSinkBase(LogHandler):
    def __init__(
        self,
        str            pattern,
        LogLevel          level,
        size_t         queue_capacity,
        size_t         max_msg_size,
        OverflowPolicy overflow_policy,    
        long           close_timeout_ms = -1,    
        bint           detach= False
    ):
    
        cdef bint overwrite      = (overflow_policy == OverflowPolicy.DROP_OLDEST)
        cdef bint block_on_full  = (overflow_policy == OverflowPolicy.BLOCK)

        super().__init__(False, pattern, level)

        self._queue_capacity  = queue_capacity
        self._max_msg_size    = max_msg_size
        self._overflow_policy = overflow_policy
        self._detach          = detach
        self._running.store(True, memory_order_relaxed)

        self._queue_close_delay_ms = close_timeout_ms

        self._queue = Queue(
            slot_size     = max_msg_size,
            capacity      = queue_capacity,
            mode          = QueueMode.SPSC,
            overwrite     = overwrite,
            zerocopy      = False,
            block_on_full = block_on_full,
        )
        

    cdef void _start_worker(self, worker_fn_t fn) noexcept nogil:
        self._thread = make_thread(fn, <void*>self)
        if self._detach:
            self._thread.detach()
        
    cpdef void stop(self):
        if self._running.load(memory_order_acquire):
            self._queue.close(self._queue_close_delay_ms)

            self._running.store(False, memory_order_seq_cst)   
            
            if not self._detach:
                if self._thread.joinable():
                    self._thread.join()
                

    def __dealloc__(self):
        self.stop()
        


cdef class StdoutHandler(LogHandler):
    def __init__(        
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.TRACE, 
        LogLevel max_level=LogLevel.INFO
            ):
        super().__init__(color, pattern, level)
        self.max_level = max_level

cdef class StderrHandler(LogHandler):
    def __init__(
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.WARN
            ):
        super().__init__(color, pattern, level)

cdef class BasicConsoleHandler(LogHandler):
    def __init__(
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.TRACE
            ):
        super().__init__(color, pattern, level)


cdef class ConsoleHandler(LogHandler):
    
    def __init__(
        self,  
        bint color=True,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel max_stdout_level=LogLevel.INFO, 
        LogLevel min_level=LogLevel.TRACE
            ):
        super().__init__(color, pattern, LogLevel.TRACE)
        self.max_stdout_level = max_stdout_level
        self.min_level = min_level


cdef class FileHandler(LogHandler):
    
    def __init__(
        self, 
        str filename, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.TRACE, 
        bint overwrite=False
            ):
        super().__init__(color, pattern, level)
        self.filename = filename
        self.overwrite = overwrite


cdef class RotatingFileHandler(FileHandler):
    
    def __init__(
        self, 
        str filename, 
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.TRACE, 
        size_t max_size=1048576, 
        size_t max_files=3
            ):
        super().__init__(filename, pattern, level, False)
        self.max_size = max_size
        self.max_files = max_files


cdef class DailyFileHandler(FileHandler):

    def __init__(
        self,
        str filename,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel level=LogLevel.TRACE,
        int rotation_hour=0,
        int rotation_minute=0,
        bint truncate=False,
        uint16_t max_files=0
            ):
        super().__init__(filename, pattern=pattern, level=level, overwrite=False)
        self.rotation_hour = rotation_hour
        self.rotation_minute = rotation_minute
        self.truncate = truncate
        self.max_files = max_files



# =========================     NETWORK HANDLERS      ==============================


cdef class TcpSocketHandler(UserSinkBase):

    def __init__(
        self,
        str            host,
        uint16_t       port,
        str            pattern              = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel          level                = LogLevel.TRACE,
        size_t         queue_capacity       = 4096,
        size_t         max_msg_size         = 4096,
        OverflowPolicy overflow_policy      = OverflowPolicy.DROP_OLDEST,
        bint           keepalive            = True,
        bint           reconnect_on_failure = True,
        double         connect_timeout      = 5.0,
        double         read_timeout         = 5.0,
        double         write_timeout        = 5.0,
        long           close_timeout_ms     = -1,    
        bint           detach               = False

    ):
        super().__init__(pattern, level, queue_capacity,
                         max_msg_size, overflow_policy,
                         close_timeout_ms, detach)
        self._host_bytes         = host.encode()
        self._host_str             = string(<const char*>self._host_bytes)
        self._port               = port
        self._keepalive          = keepalive
        self._reconnect_on_failure = reconnect_on_failure
        self._sock               = new TcpSocket()

        self._timeouts.connect_sec = connect_timeout
        self._timeouts.read_sec    = read_timeout
        self._timeouts.write_sec   = write_timeout

        with nogil:
            self._start_worker(_tcp_worker_fn)

    cpdef void close(self):
        self.stop()
        self._cancel_src.cancel() 
        if self._sock != NULL:
            self._sock.close()
            del self._sock
            self._sock = NULL

    def __dealloc__(self):
        self.close()

    cdef void _tcp_loop(self) noexcept nogil:
        cdef:
            char*       buf  = NULL
            size_t      size = 0
            int         ret
            CancelToken tok  = self._cancel_src.token()
            cbool       ka   = self._keepalive

        if ka:
            self._try_connect(tok)

        while self._running.load(memory_order_acquire):
            if self._queue.pop_var(&buf, &size) == Q_OK:
                if ka:
                    if not self._sock.is_open():
                        if self._reconnect_on_failure:
                            self._try_connect(tok)
                        else:
                            continue

                    if self._sock.is_open():
                        if not self._send(buf, size, tok):
                            self._sock.close()
                            if self._reconnect_on_failure:
                                self._try_connect(tok)
                                if self._sock.is_open():
                                    self._send(buf, size, tok)
                else:
                    self._try_connect(tok)
                    if self._sock.is_open():
                        self._send(buf, size, tok)
                        self._sock.close()

    cdef inline void _try_connect(self, CancelToken tok) noexcept nogil:
        #self._sock.close()
        self._sock.connect(
            self._host_str, self._port,
            self._timeouts, self._keepalive, tok)

    cdef inline cbool _send(
            self,
            const char* buf,
            size_t size,
            CancelToken tok
    ) noexcept nogil:
        cdef string data = string(buf, size)
        self._sock.send_all(data)
        return True



cdef class UdpSocketHandler(UserSinkBase):

    def __init__(
        self,
        str            host,
        uint16_t       port,
        str            pattern         = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel          level           = LogLevel.TRACE,
        size_t         queue_capacity  = 4096,
        size_t         max_msg_size    = 4096,
        OverflowPolicy overflow_policy = OverflowPolicy.DROP_OLDEST,
        double         recv_timeout_sec = 5.0,
        double         send_timeout_sec = 5.0,
        long           close_timeout_ms     = -1,    
        bint           detach               = False
    ):
        super().__init__(pattern, level, queue_capacity,
                         max_msg_size, overflow_policy,
                         close_timeout_ms, detach)
        self._host_bytes = host.encode()
        self._host_str     = string(<const char*>self._host_bytes)
        self._port       = port

        self._sock       = new UdpSocket()
        self._sock.create_client(self._host_str, self._port,
                                 recv_timeout_sec, False, send_timeout_sec)
        with nogil:
            self._start_worker(_udp_worker_fn)

    def __dealloc__(self):
        self.close()

    cpdef void close(self):
        self.stop()

        if self._sock != NULL:
            self._sock.close()
            del self._sock
            self._sock = NULL

    cdef void _udp_loop(self) noexcept nogil:
        cdef:
            char*   buf  = NULL
            size_t  size = 0
            int     ret

        if not self._sock.is_open():
            return
        
        while self._running.load(memory_order_acquire):
            ret = self._queue.pop_var(&buf, &size) 
            if ret != Q_OK:
                break
            
            self._sock.sendto(string(buf, size))


cdef class HttpHandler(UserSinkBase):

    def __init__(
        self,
        str            host,
        uint16_t       port                 = 80,
        str            path                 = "/",
        str            content_type         = "text/plain",
        str            pattern              = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel          level                = LogLevel.WARN,
        size_t         queue_capacity       = 512,
        size_t         max_msg_size         = 65536,
        OverflowPolicy overflow_policy      = OverflowPolicy.DROP_OLDEST,
        bint           keepalive            = False,
        bint           use_tls              = False,

        double         connect_timeout      = 10.0,
        double         tls_timeout          = 10.0,
        double         write_timeout        = 30.0,
        double         read_timeout         = 30.0,
        double         body_timeout         = 60.0,
        double         total_timeout        = 0,
        double         pool_idle_timeout    = 0,
        
        bint           verify_tls           = True,
        bint           verify_hostname      = True,
        str            ca_file              = "",
        str            ca_path              = "",
        str            cert_file            = "",
        str            key_file             = "",
        str            key_password         = "",
        int            min_tls_version      = 0,
        bint           allow_http2          = False,
        
        int            retry_max_attempts   = 3,
        double         retry_initial_delay  = 1.0,
        double         retry_backoff        = 2.0,
        double         retry_max_delay      = 30.0,
        double         retry_jitter         = 0.1,
        
        int            ka_idle_sec          = 60,
        int            ka_interval_sec      = 10,
        int            ka_probe_count       = 5,
        int            ka_max_requests      = 1000,
        double         ka_max_age_sec       = 300.0,
        
        str            user_agent           = "cylogger",
        int            max_redirects        = 10,

        long           close_timeout_ms     = -1,    
        bint           detach               = False
    ):
        super().__init__(pattern, level, queue_capacity,
                         max_msg_size, overflow_policy,
                         close_timeout_ms, detach)
        self._host_bytes         = host.encode()
        self._path_bytes         = path.encode()
        self._content_type_bytes = content_type.encode()
        self._ca_file_bytes      = ca_file.encode()
        self._ca_path_bytes      = ca_path.encode()
        self._cert_file_bytes    = cert_file.encode()
        self._key_file_bytes     = key_file.encode()
        self._key_pwd_bytes     = key_password.encode()
        self._user_agent_bytes  = user_agent.encode()

        self._port               = port
        self._keepalive          = keepalive
        self._client             = NULL
        self._session            = NULL

        self.host_str = string(<const char*>self._host_bytes)
        self.path_str = string(<const char*>self._path_bytes)
        self.content_type_str = string(<const char*>self._content_type_bytes)
        
        if keepalive:
            self._session = make_http_session(
                self.host_str, port,
                self.path_str,
                self.content_type_str,
                use_tls, connect_timeout, tls_timeout,
                write_timeout, read_timeout, body_timeout,
                total_timeout, pool_idle_timeout,
                verify_tls, verify_hostname,
                self._ca_file_bytes, self._ca_path_bytes,
                self._cert_file_bytes, self._key_file_bytes, self._key_pwd_bytes,
                min_tls_version, allow_http2,
                retry_max_attempts, retry_initial_delay, retry_backoff,
                retry_max_delay, retry_jitter,
                IdempotencyClass.Idempotent,
                True, ka_idle_sec, ka_interval_sec,
                ka_probe_count, ka_max_requests, ka_max_age_sec,
                self._user_agent_bytes,
                HeaderList(), max_redirects)
        else:
            _scheme = "https://" if use_tls else "http://"
            _full_url = (_scheme + host + ":" + str(port) + path).encode()
            self._host_bytes = _full_url      
            self.host_str = string(<const char*>self._host_bytes)

            self._client = make_http_client(
                connect_timeout, tls_timeout,
                write_timeout, read_timeout, body_timeout,
                total_timeout, pool_idle_timeout, max_redirects,
                verify_tls, verify_hostname,
                self._ca_file_bytes, self._ca_path_bytes,
                self._cert_file_bytes, self._key_file_bytes, self._key_pwd_bytes,
                min_tls_version, allow_http2,
                retry_max_attempts, retry_initial_delay, retry_backoff,
                retry_max_delay, retry_jitter,
                IdempotencyClass.Idempotent,
                False, 0, 0, 0, 0, 0.0, 
                self._user_agent_bytes)


        with nogil:
            self._start_worker(_http_worker_fn)

    cpdef void close(self):
        if self._session != NULL:
            self._session.force_close()
            
        self.stop()
        
        if self._session != NULL:
            self._session.disconnect()
            del self._session
            self._session = NULL
        if self._client != NULL:
            del self._client
            self._client = NULL

    def __dealloc__(self):        
        self.close()
                

    cdef void _http_loop(self) noexcept nogil:
        cdef:
            char*          buf  = NULL
            size_t         size = 0
            int            ret
            RequestOptions opts
            string         _body
            HttpResponse   res

        while self._running.load(memory_order_acquire):
            
            ret = self._queue.pop_var(&buf, &size)
            if ret != Q_OK:
                break                

            _body = string(buf, size)
            
            if self._keepalive:
                res = self._session[0].post(
                    self.path_str,
                    _body,
                    self.content_type_str,
                    opts)
                self._log_msg(res)

            else:
                res = self._client[0].post(
                    self.host_str,
                    _body,
                    self.content_type_str,
                    opts)
                self._log_msg(res)
    
    cdef inline void _log_msg(self, HttpResponse res) noexcept nogil:
        if not res.ok():
            DEBUG_M(
                b"cylogger_internal",
                b"HTTP status=%d reason=%s bytes=%zu body=%s",
                res.status,
                res.reason.c_str(),
                res.bytes_received,
                res.body.c_str()
            )
        else:
            DEBUG_M(
                b"cylogger_internal",
                b"HTTP status=%d reason=%s bytes=%zu",
                res.status,
                res.reason.c_str(),
                res.bytes_received
            )

                    

cdef class SmtpHandler(UserSinkBase):

    def __init__(
        self,
        str               smtp_host,
        uint16_t          smtp_port           = 587,
        str               client_name         = "localhost",
        str               from_addr           = "",
        str               to_addr             = "",
        str               subject             = "Log Alert",
        str               username            = "",
        str               password            = "",
        str               pattern             = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        LogLevel             level               = LogLevel.ERROR,
        size_t            queue_capacity      = 128,
        size_t            max_msg_size        = 65536,
        OverflowPolicy    overflow_policy     = OverflowPolicy.DROP_OLDEST,
        
        bint              keepalive           = False,
        
        SmtpSecurityMode  smtp_mode           = SmtpSecurityMode.STARTTLS,  
        SmtpAuthMethod    smtp_auth           = SmtpAuthMethod.LOGIN,
        
        int               max_send_attempts   = 3,
        
        double            connect_timeout     = 5.0,
        double            tls_timeout         = 5.0,
        double            banner_timeout      = 5.0,
        double            command_timeout     = 5.0,
        double            data_timeout        = 10.0,
        double            response_timeout    = 5.0,

        str               oauth2_client_id    = "",
        str               oauth2_secret       = "",
        str               oauth2_refresh      = "",
        str               oauth2_endpoint     = "",
        
        long           close_timeout_ms     = -1,    
        bint           detach               = False
    ):
        super().__init__(pattern, level, queue_capacity,
                         max_msg_size, overflow_policy,
                         close_timeout_ms, detach)


        self._host_bytes        = smtp_host.encode()
        self._from_bytes        = from_addr.encode()
        self._to_bytes          = to_addr.encode()
        self._subject_bytes     = subject.encode()
        self._username_bytes    = username.encode()
        self._password_bytes    = password.encode()
        self._client_name_bytes = client_name.encode()
        self._oauth2_id_bytes   = oauth2_client_id.encode()
        self._oauth2_sec_bytes  = oauth2_secret.encode()
        self._oauth2_ref_bytes  = oauth2_refresh.encode()
        self._oauth2_ep_bytes   = oauth2_endpoint.encode()
        self._port              = smtp_port
        self._keepalive         = keepalive
        self._max_send_attempts = max_send_attempts
        self._client            = NULL

        self._connect_timeout   = connect_timeout
        self._tls_timeout       = tls_timeout
        self._banner_timeout    = banner_timeout
        self._command_timeout   = command_timeout
        self._data_timeout      = data_timeout
        self._response_timeout  = response_timeout

        self.host_str = string(self._host_bytes)
        self.from_addr_str = string(self._from_bytes)
        self.to_addr_str = string(self._to_bytes)
        self.subject_str = string(self._subject_bytes)
        self.username_str = string(self._username_bytes)
        self.password_str = string(self._password_bytes)
        self.client_name_str = string(self._client_name_bytes)
        self.oauth2_id_str = string(self._oauth2_id_bytes)
        self.oauth2_sec_str = string(self._oauth2_sec_bytes)
        self.oauth2_ref_str = string(self._oauth2_ref_bytes)
        self.oauth2_ep_str = string(self._oauth2_ep_bytes)

        self._mode = <SmtpMode>smtp_mode
        self._auth = <SmtpAuth>smtp_auth

        if smtp_auth == SmtpAuthMethod.XOAUTH2:
            self._oauth2.client_id = self.oauth2_id_str
            self._oauth2.client_secret = self.oauth2_sec_str
            self._oauth2.refresh_token = self.oauth2_ref_str
            self._oauth2.set_refresh_provider(self.oauth2_ep_str)

        
        self._client = self._make_client()

        with nogil:
            self._start_worker(_smtp_worker_fn)

    cdef inline SmtpClient* _make_client(self) except NULL nogil:
        return make_smtp_client(
            self.host_str, self._port,
            username          = self.username_str,
            password          = self.password_str,
            client_name       = self.client_name_str,
            mode              = self._mode,
            auth_mech         = self._auth,
            oauth2            = self._oauth2,
            max_send_attempts = self._max_send_attempts,
            connect_timeout   = self._connect_timeout, 
            tls_timeout       = self._tls_timeout, 
            banner_timeout    = self._banner_timeout, 
            command_timeout   = self._command_timeout, 
            data_timeout      = self._data_timeout, 
            response_timeout  = self._response_timeout)

    cdef inline SmtpMessage _build_msg(
            self, const char* buf, size_t size) noexcept nogil:
        cdef SmtpMessage msg
        msg.set_from(self.from_addr_str)
        msg.add_to(self.to_addr_str)
        msg.set_subject(self.subject_str)
        msg.set_body_text(string(buf, size))
        return msg

    cpdef void close(self):
        self.stop()

        if self._client != NULL:
            del self._client
            self._client = NULL

    def __dealloc__(self):
        self.close()

    cdef void _smtp_loop(self) noexcept nogil:
        cdef:
            char*          buf  = NULL
            size_t         size = 0
            int            ret
            SmtpMessage    msg
            SmtpSendResult res
        
        while self._running.load(memory_order_acquire):
            ret = self._queue.pop_var(&buf, &size)
            if ret != Q_OK:
                break

            msg = self._build_msg(buf, size)

            if self._keepalive:
                res = self._client[0].send(msg, False)
                self._log_msg(res)
            else:
                res = self._client[0].send(msg, True)  
                self._log_msg(res)
    
    cdef inline void _log_msg(self, SmtpSendResult res) noexcept nogil:
        if res.ok != 1:
            DEBUG_M(
                b"cylogger_internal",
                b"SMTP ok=%d  code=%d  error=%s msg=%s ", 
                res.ok, 
                res.smtp_code, 
                smtp_error_class_str(res.error_class), 
                res.smtp_message.c_str()
            )
        else:
            DEBUG_M(
                b"cylogger_internal",
                b"SMTP ok=%d  code=%d  msg=%s ", 
                res.ok, 
                res.smtp_code, 
                res.smtp_message.c_str()
            )

# =========================================================================
# =========================      HELPERS        ===========================
# =========================================================================

cdef class ColorScheme:
    
    def __init__(
        self, 
        int trace_color=-1, 
        int debug_color=-1, 
        int info_color=-1,
        int warn_color=-1, 
        int error_color=-1, 
        int critical_color=-1
            ):
        self.trace_color = trace_color
        self.debug_color = debug_color
        self.info_color = info_color
        self.warn_color = warn_color
        self.error_color = error_color
        self.critical_color = critical_color



class PyLogHandler(py_logging.Handler):    

    def __init__(self, int level) -> None:
        super().__init__(level)

        self._debug = py_logging.DEBUG
        self._info = py_logging.INFO
        self._warn = py_logging.WARN
        self._error = py_logging.ERROR
        self._critical = py_logging.CRITICAL

    
    def emit(self, object record):
        cdef:
            bytes msg = record.getMessage().encode()
            int lvl = record.levelno
            object exc_info = record.exc_info
            object stack_info = record.stack_info
        
        if exc_info is not None:
            msg += b"\n"
            msg += "".join(traceback.format_exception(*exc_info)).encode()
        
        if stack_info is not None:
            msg += b"\n"
            msg += str(stack_info).encode()
        
        if lvl >= self._critical:
            CRITICAL_PY_LOG(msg=msg)
        elif lvl >= self._error:
            ERROR_PY_LOG(msg=msg)
        elif lvl >= self._warn:
            WARN_PY_LOG(msg=msg)
        elif lvl >= self._info:
            INFO_PY_LOG(msg=msg)
        elif lvl >= self._debug:
            DEBUG_PY_LOG(msg=msg)
        else:
            TRACE_PY_LOG(msg=msg)

cdef void redirect_pylog():
    cdef object root = py_logging.getLogger()
    root.handlers.clear()
    root.setLevel(py_logging.DEBUG)
    root.addHandler(PyLogHandler(py_logging.DEBUG))


# =========================================================================
# =========================      LOGGER CLASS       =======================
# =========================================================================


cdef class Logger:
    
    def __init__(
            self, 
            str name, 
            LogLevel level=  LogLevel.TRACE,
            str pattern= "[%d-%m-%Y %H:%M:%S.%f] [%n] [%^%l%$] %v",
            list handlers = [],
            ColorScheme color_scheme= None,
            bint set_default = False,
            bint intercept_stdlib_logging = True,
            bint diag = False
            ):
        global _diag_initialized
        self._handlers = handlers
        self.factory.set_level(<level_enum>level)

        if name == "cylogger_internal":
            PyErr_SetString(
                PyExc_ValueError,
                b"'cylogger_internal' is reserved for internal use"
            )
            return

        if diag:
            if not _diag_initialized:
                enable_internal_logger(
                    b"cylogger_internal",
                    <level_enum>level,
                    pattern.encode()
                )
                _diag_initialized = True
            else:
                PyErr_WarnEx(
                    PyExc_RuntimeWarning,
                    b"Diagnostic logging can be enabled only once per process. ",
                    1
                )

        if handlers:
            for h in handlers:
                if isinstance(h, StdoutHandler):
                    self.factory.add_stdout_handler(
                        h.color,
                        h.pattern.encode(),
                        <level_enum>h.level,
                        <level_enum>h.max_level
                    )

                elif isinstance(h, StderrHandler):
                    self.factory.add_stderr_handler(
                        h.color,
                        h.pattern.encode(),
                        <level_enum>h.level
                    )

                elif isinstance(h, ConsoleHandler):
                    self.factory.add_console_handler(
                        h.color,
                        h.pattern.encode(),
                        <level_enum>h.max_stdout_level,
                        <level_enum>h.min_level
                    )

                elif isinstance(h, BasicConsoleHandler):
                    self.factory.add_basic_console_handler(
                        h.color,
                        h.pattern.encode(),
                        <level_enum>h.level
                    )

                elif isinstance(h, FileHandler):
                    self.factory.add_file_handler(
                        h.filename.encode(),
                        h.pattern.encode(),
                        <level_enum>h.level,
                        h.overwrite
                    )

                elif isinstance(h, RotatingFileHandler):
                    self.factory.add_rotating_file_handler(
                        h.filename.encode(),
                        h.max_size,
                        h.max_files,
                        h.pattern.encode(),
                        <level_enum>h.level
                    )

                elif isinstance(h, DailyFileHandler):
                    self.factory.add_daily_file_handler(
                        h.filename.encode(),
                        h.rotation_hour,
                        h.rotation_minute,
                        h.pattern.encode(),
                        <level_enum>h.level,
                        h.truncate,
                        h.max_files
                    )
                
                elif isinstance(h, TcpSocketHandler):
                    self.factory.add_custom_sink_handler(
                        _tcp_push_fn,
                        _tcp_flush_fn,
                        <void*>h,
                        <SinkOverflowPolicy><uint8_t>h._overflow_policy,
                        <level_enum>h.level,
                        h.pattern.encode()
                    )

                elif isinstance(h, UdpSocketHandler):
                    self.factory.add_custom_sink_handler(
                        _udp_push_fn,
                        _udp_flush_fn,
                        <void*>h,
                        <SinkOverflowPolicy><uint8_t>h._overflow_policy,
                        <level_enum>h.level,
                        h.pattern.encode()
                    )

                elif isinstance(h, HttpHandler):
                    self.factory.add_custom_sink_handler(
                        _http_push_fn,
                        _http_flush_fn,
                        <void*>h,
                        <SinkOverflowPolicy><uint8_t>h._overflow_policy,
                        <level_enum>h.level,
                        h.pattern.encode()
                    )

                elif isinstance(h, SmtpHandler):
                    self.factory.add_custom_sink_handler(
                        _smtp_push_fn,
                        _smtp_flush_fn,
                        <void*>h,
                        <SinkOverflowPolicy><uint8_t>h._overflow_policy,
                        <level_enum>h.level,
                        h.pattern.encode()
                    )
                    
                else:
                    PyErr_SetString(PyExc_TypeError, b"Unknown handler type")
        else:
            self.factory.add_basic_console_handler(
                    True,
                    pattern.encode(),
                    <level_enum>level
                )

        if color_scheme is not None:
            self.factory.set_colors(
                color_scheme.trace_color,
                color_scheme.debug_color,
                color_scheme.info_color,
                color_scheme.warn_color,
                color_scheme.error_color,
                color_scheme.critical_color
            )

        self._logger_ptr = self.factory.build(name.encode(), False)

        if set_default:
            registry_set_default(self._logger_ptr)
        #self._logger = new SpdLogger(self._logger_ptr)
        self._logger = SpdLogger(self._logger_ptr)

        if (set_default and intercept_stdlib_logging):
            redirect_pylog()
        
    def __dealloc__(self):
        self._logger_ptr.reset()
        
    cdef SpdLogger get_logger(self):
        return self._logger    
    
    cpdef void trace(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            TRACE_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg) 

            Py_DECREF(holder)

        
    cpdef void debug(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            DEBUG_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)
        
    cpdef void info(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            INFO_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)
    
    cpdef void warn(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            WARN_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)
    
    cpdef void error(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            ERROR_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)

    cpdef void critical(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            CRITICAL_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)   

            Py_DECREF(holder)


cdef class DefaultLogger:
    cpdef void trace(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            TRACE_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)        

            Py_DECREF(holder)
        
    cpdef void debug(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            DEBUG_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)
        
    cpdef void info(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            INFO_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)
    
    cpdef void warn(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            WARN_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)
    
    cpdef void error(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            ERROR_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)

            Py_DECREF(holder)

    cpdef void critical(self, object msg, object args= None, int fg_color= -1, int bg_color= -1, int effect= -1):
        cdef:
            PyObject* fmt = <PyObject*>msg
            PyObject* args_ = <PyObject*>args if args else NULL
            PyObject* holder = NULL 
            const char* c_msg = _format_msg(fmt, args_, &holder)
        
        if c_msg != NULL:
            CRITICAL_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = c_msg)      

            Py_DECREF(holder)


cdef SpdLogger get_logger_by_name(const char* name):
    cdef shared_ptr[logger] logger_ptr = get(name)
    cdef SpdLogger logger = SpdLogger(logger_ptr)
    return logger    

#cdef void get_logger_ptr(shared_ptr[logger] &logger, str name= "", bint fallback_to_default= False):
#    logger = registry_get_logger_ptr(name, fallback_to_default)
cdef shared_ptr[logger] get_logger_ptr(str name="", bint fallback_to_default=False):
    return registry_get_logger_ptr(name, fallback_to_default)

cdef void get_logger(SpdLogger &log, str name= "", bint fallback_to_default= False):
    cdef shared_ptr[logger] logger_ptr = registry_get_logger_ptr(name.encode(), fallback_to_default)
    log.get_logger().swap(logger_ptr )
 