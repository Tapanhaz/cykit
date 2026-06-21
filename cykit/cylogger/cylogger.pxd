
from libc.stdint cimport uint16_t
from libcpp cimport bool as cbool
from libcpp.string cimport string
from libcpp.memory cimport shared_ptr
from cykit.queue cimport Queue, QueueMode, Q_OK
from cykit.common cimport (
    atomic_bool,
    thread,

)

from cykit.utils.transport cimport (
    UdpSocket,
    make_http_client,
    make_http_session,
    make_smtp_client, CancelToken,
    TcpSocket, TcpTimeouts, CancellationSource,
    TcpTimeouts, HttpClient, HttpResponse, HttpSession,
    SmtpClient, SmtpMessage, SmtpAuth, SmtpMode, 
    SmtpSendResult, OAuth2Config, SmtpErrorClass,
    IdempotencyClass, HeaderList, RequestOptions,
    smtp_error_class_str
)


cdef extern from "<spdlog/spdlog.h>" namespace "spdlog":
    cdef cppclass logger:
        pass
    
    shared_ptr[logger] get(const char* name) except + nogil

cdef extern from "spdlog/common.h" namespace "spdlog::level":
    cdef enum level_enum:
        trace
        debug
        info
        warn
        err
        critical
        off

cdef extern from "spdlog_logger.hpp" nogil:
    cdef enum SinkOverflowPolicy:
        DROP_OLDEST
        DROP_NEWEST
        BLOCK

    ctypedef int  (*SinkPushFn) (const char* data, size_t len, void* userdata)
    ctypedef void (*SinkFlushFn)(void* userdata)


    cdef cppclass LoggerFactory:
        LoggerFactory() except + nogil

        LoggerFactory& set_level(level_enum level) except + nogil

        LoggerFactory& add_stdout_handler(
            cbool color,
            const string& pattern,
            level_enum level,
            level_enum max_level
        ) except + nogil

        LoggerFactory& add_stderr_handler(
            cbool color,
            const string& pattern,
            level_enum level
        ) except + nogil

        LoggerFactory& add_basic_console_handler(
            cbool color,
            const string& pattern,
            level_enum level
        ) except + nogil

        LoggerFactory& add_console_handler(
            cbool color,
            const string& pattern,
            level_enum max_stdout_level,
            level_enum min_level
        ) except + nogil

        LoggerFactory& add_file_handler(
            const string& filename,
            const string& pattern,
            level_enum level,
            cbool overwrite
        ) except + nogil

        LoggerFactory& add_rotating_file_handler(
            const string& filename,
            size_t max_size,
            size_t max_files,
            const string& pattern,
            level_enum level
        ) except + nogil

        LoggerFactory& add_daily_file_handler(
            const string& filename,
            int rotation_hour,
            int rotation_minute,
            const string& pattern,
            level_enum level,
            cbool truncate,
            uint16_t max_files
        ) except + nogil


        LoggerFactory& add_custom_sink_handler(
            SinkPushFn push_fn,
            SinkFlushFn flush_fn,
            void* userdata,
            SinkOverflowPolicy overflow_policy,
            level_enum level,
            const string& pattern
        ) except +

        LoggerFactory& set_color(
            level_enum level,
            int color
        ) except + nogil

        LoggerFactory& set_colors(
            int trace_color,
            int debug_color,
            int info_color,
            int warn_color,
            int error_color,
            int critical_color
        ) except + nogil

        shared_ptr[logger] build(const string& name, cbool set_default) except + nogil

    cdef cppclass SpdLogger:
        SpdLogger()
        SpdLogger(shared_ptr[logger]) except + nogil
        shared_ptr[logger]& get_logger() except + nogil

        void trace(const char* msg, ...) except + nogil
        void trace(int color, const char* msg, ...) except + nogil
        void trace(int fg_color, int bg_color, const char* msg, ...) except + nogil
        void trace(int fg_color, int bg_color, int effect, const char* msg, ...) except + nogil

        void debug(const char* msg, ...) except + nogil
        void debug(int color, const char* msg, ...) except + nogil
        void debug(int fg_color, int bg_color, const char* msg, ...) except + nogil
        void debug(int fg_color, int bg_color, int effect, const char* msg, ...) except + nogil

        void info(const char* msg, ...) except + nogil
        void info(int color, const char* msg, ...) except + nogil
        void info(int fg_color, int bg_color, const char* msg, ...) except + nogil
        void info(int fg_color, int bg_color, int effect, const char* msg, ...) except + nogil

        void warn(const char* msg, ...) except + nogil
        void warn(int color, const char* msg, ...) except + nogil
        void warn(int fg_color, int bg_color, const char* msg, ...) except + nogil
        void warn(int fg_color, int bg_color, int effect, const char* msg, ...) except + nogil

        void error(const char* msg, ...) except + nogil
        void error(int color, const char* msg, ...) except + nogil
        void error(int fg_color, int bg_color, const char* msg, ...) except + nogil
        void error(int fg_color, int bg_color, int effect, const char* msg, ...) except + nogil

        void critical(const char* msg, ...) except + nogil
        void critical(int color, const char* msg, ...) except + nogil
        void critical(int fg_color, int bg_color, const char* msg, ...) except + nogil
        void critical(int fg_color, int bg_color, int effect, const char* msg, ...) except + nogil


    void registry_set_default(shared_ptr[logger] logger)
    shared_ptr[logger] registry_get_logger_ptr(const string &name, bool fallback_to_default)  

    ##### FOR INTERNAL LOGGGING ########################################
    void enable_internal_logger(const string& name, level_enum level, const string& pattern)
    void disable_internal_logger()
    #####################################################################

    void TRACE(const char* fmt, ...)
    void DEBUG(const char* fmt, ...)
    void INFO(const char* fmt, ...)
    void WARN(const char* fmt, ...)
    void ERROR(const char* fmt, ...)
    void CRITICAL(const char* fmt, ...)

    void TRACE_L(SpdLogger logger, const char* fmt, ...)
    void DEBUG_L(SpdLogger logger, const char* fmt, ...)
    void INFO_L(SpdLogger logger, const char* fmt, ...)
    void WARN_L(SpdLogger logger, const char* fmt, ...)
    void ERROR_L(SpdLogger logger, const char* fmt, ...)
    void CRITICAL_L(SpdLogger logger, const char* fmt, ...)

    void TRACE_M(const char* logger_name, const char* fmt, ...)
    void DEBUG_M(const char* logger_name, const char* fmt, ...)
    void INFO_M(const char* logger_name, const char* fmt, ...)
    void WARN_M(const char* logger_name, const char* fmt, ...)
    void ERROR_M(const char* logger_name, const char* fmt, ...)
    void CRITICAL_M(const char* logger_name, const char* fmt, ...)

    void TRACE_C(int color, const char* fmt, ...)
    void DEBUG_C(int color, const char* fmt, ...)
    void INFO_C(int color, const char* fmt, ...)
    void WARN_C(int color, const char* fmt, ...)
    void ERROR_C(int color, const char* fmt, ...)
    void CRITICAL_C(int color, const char* fmt, ...)

    void TRACE_CL(SpdLogger logger, int color, const char* fmt, ...)
    void DEBUG_CL(SpdLogger logger, int color, const char* fmt, ...)
    void INFO_CL(SpdLogger logger, int color, const char* fmt, ...)
    void WARN_CL(SpdLogger logger, int color, const char* fmt, ...)
    void ERROR_CL(SpdLogger logger, int color, const char* fmt, ...)
    void CRITICAL_CL(SpdLogger logger, int color, const char* fmt, ...)

    void TRACE_CM(const char* logger_name, int color, const char* fmt, ...)
    void DEBUG_CM(const char* logger_name, int color, const char* fmt, ...)
    void INFO_CM(const char* logger_name, int color, const char* fmt, ...)
    void WARN_CM(const char* logger_name, int color, const char* fmt, ...)
    void ERROR_CM(const char* logger_name, int color, const char* fmt, ...)
    void CRITICAL_CM(const char* logger_name, int color, const char* fmt, ...)

    void TRACE_FX(int fg_color, int bg_color, int effect, const char* fmt, ...)
    void DEBUG_FX(int fg_color, int bg_color, int effect, const char* fmt, ...)
    void INFO_FX(int fg_color, int bg_color, int effect, const char* fmt, ...)
    void WARN_FX(int fg_color, int bg_color, int effect, const char* fmt, ...)
    void ERROR_FX(int fg_color, int bg_color, int effect, const char* fmt, ...)
    void CRITICAL_FX(int fg_color, int bg_color, int effect, const char* fmt, ...)

    void TRACE_FXL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void DEBUG_FXL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void INFO_FXL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void WARN_FXL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void ERROR_FXL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void CRITICAL_FXL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* fmt, ...)

    void TRACE_FXM(const char* logger_name, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void DEBUG_FXM(const char* logger_name, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void INFO_FXM(const char* logger_name, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void WARN_FXM(const char* logger_name, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void ERROR_FXM(const char* logger_name, int fg_color, int bg_color, int effect, const char* fmt, ...)
    void CRITICAL_FXM(const char* logger_name, int fg_color, int bg_color, int effect, const char* fmt, ...)

    void TRACE_PY(int fg_color, int bg_color, int effect, const char* msg)
    void DEBUG_PY(int fg_color, int bg_color, int effect, const char* msg)
    void INFO_PY(int fg_color, int bg_color, int effect, const char* msg)
    void WARN_PY(int fg_color, int bg_color, int effect, const char* msg)
    void ERROR_PY(int fg_color, int bg_color, int effect, const char* msg)
    void CRITICAL_PY(int fg_color, int bg_color, int effect, const char* msg)

    void TRACE_PYL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* msg)
    void DEBUG_PYL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* msg)
    void INFO_PYL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* msg)
    void WARN_PYL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* msg)
    void ERROR_PYL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* msg)
    void CRITICAL_PYL(SpdLogger logger, int fg_color, int bg_color, int effect, const char* msg)

    void TRACE_PY_LOG(const char* msg)
    void DEBUG_PY_LOG(const char* msg)
    void INFO_PY_LOG(const char* msg)
    void WARN_PY_LOG(const char* msg)
    void ERROR_PY_LOG(const char* msg)
    void CRITICAL_PY_LOG(const char* msg)


cpdef enum class LogLevel:
    TRACE = level_enum.trace
    DEBUG = level_enum.debug
    INFO = level_enum.info
    WARN = level_enum.warn
    ERROR = level_enum.err
    CRITICAL = level_enum.critical
    OFF = level_enum.off

cpdef enum class OverflowPolicy:
    DROP_OLDEST = 0
    DROP_NEWEST = 1
    BLOCK       = 2


cdef class LogHandler:
    cdef:
        public bint color
        public str pattern
        public LogLevel level


cdef class UserSinkBase(LogHandler):
    cdef:
        Queue    _queue
        thread       _thread
        atomic_bool  _running
        size_t       _queue_capacity
        size_t       _max_msg_size
        public OverflowPolicy _overflow_policy
        public bytes _host_bytes_ref
        bint  _detach
        long  _queue_close_delay_ms

    cdef void _start_worker(self, void (*fn)(void*) noexcept nogil) noexcept nogil
    cpdef void stop(self)


cdef class StdoutHandler(LogHandler):
    cdef public LogLevel max_level


cdef class StderrHandler(LogHandler):
    pass


cdef class BasicConsoleHandler(LogHandler):
    pass


cdef class ConsoleHandler(LogHandler):
    cdef:
        public LogLevel max_stdout_level
        public LogLevel min_level


cdef class FileHandler(LogHandler):
    cdef:
        public str filename
        public bint overwrite


cdef class RotatingFileHandler(FileHandler):
    cdef:
        public size_t max_size
        public size_t max_files


cdef class DailyFileHandler(FileHandler):
    cdef:
        public int rotation_hour
        public int rotation_minute
        public bint truncate
        public uint16_t max_files


cdef class TcpSocketHandler(UserSinkBase):
    cdef:
        bytes              _host_bytes
        string             _host_str
        uint16_t           _port
        bint               _keepalive
        bint               _reconnect_on_failure
        TcpSocket *         _sock
        TcpTimeouts         _timeouts
        CancellationSource _cancel_src
    
    cpdef void close(self)
    cdef void _tcp_loop(self) noexcept nogil
    cdef inline void _try_connect(self, CancelToken tok) noexcept nogil
    cdef inline cbool _send(self, const char * buf, size_t size, CancelToken tok) noexcept nogil


cdef class UdpSocketHandler(UserSinkBase):

    cdef:
        bytes         _host_bytes
        string        _host_str
        uint16_t      _port
        UdpSocket*    _sock

    cpdef void close(self)
    cdef void _udp_loop(self) noexcept nogil


cdef class HttpHandler(UserSinkBase):

    cdef:
        bytes         _host_bytes
        bytes         _path_bytes
        bytes         _content_type_bytes
        bytes         _ca_file_bytes
        bytes         _ca_path_bytes
        bytes         _cert_file_bytes
        bytes         _key_file_bytes
        bytes         _key_pwd_bytes
        bytes         _user_agent_bytes
        uint16_t      _port
        bint          _keepalive
        HttpClient*   _client
        HttpSession*  _session

        string host_str
        string path_str
        string content_type_str

    cpdef void close(self)
    cdef void _http_loop(self) noexcept nogil
    cdef void _log_msg(self, HttpResponse res) noexcept nogil


cdef class SmtpHandler(UserSinkBase):

    cdef:
        OAuth2Config _oauth2 
        SmtpMode     _mode 
        SmtpAuth     _auth

        bytes        _host_bytes
        bytes        _from_bytes
        bytes        _to_bytes
        bytes        _subject_bytes
        bytes        _username_bytes
        bytes        _password_bytes
        bytes        _client_name_bytes
        bytes        _oauth2_id_bytes
        bytes        _oauth2_sec_bytes
        bytes        _oauth2_ref_bytes
        bytes        _oauth2_ep_bytes
        uint16_t     _port
        bint         _keepalive
        int          _max_send_attempts
        SmtpClient*  _client

        double       _connect_timeout 
        double       _tls_timeout     
        double       _banner_timeout  
        double       _command_timeout 
        double       _data_timeout    
        double       _response_timeout

        string host_str
        string from_addr_str
        string to_addr_str
        string subject_str
        string username_str
        string password_str
        string client_name_str
        string oauth2_id_str
        string oauth2_sec_str
        string oauth2_ref_str
        string oauth2_ep_str

    cpdef void close(self)
    cdef SmtpClient* _make_client(self) except NULL nogil
    cdef inline SmtpMessage _build_msg(
            self, const char* buf, size_t size) noexcept nogil
    cdef void _smtp_loop(self) noexcept nogil
    cdef void _log_msg(self, SmtpSendResult res) noexcept nogil
    


cdef class ColorScheme:
    cdef:
        public int trace_color
        public int debug_color
        public int info_color
        public int warn_color
        public int error_color
        public int critical_color
        



cdef class Logger:
    cdef:
        LoggerFactory factory
        #SpdLogger* _logger
        SpdLogger _logger
        shared_ptr[logger] _logger_ptr

        list _handlers
    
    cdef SpdLogger get_logger(self)
#    cpdef void close(self)

    cpdef void trace(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void debug(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void info(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void warn(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void error(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void critical(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)


cdef class DefaultLogger:
    cpdef void trace(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void debug(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void info(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void warn(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void error(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void critical(self, object msg, object args= *, int fg_color= *, int bg_color= *, int effect= *)

cdef SpdLogger get_logger_by_name(const char* name)
#cdef void get_logger_ptr(shared_ptr[logger] &logger, str name= *, bint fallback_to_default= *)
cdef shared_ptr[logger]& get_logger_ptr(str name= *, bint fallback_to_default= *)
cdef void get_logger(SpdLogger &log, str name= *, bint fallback_to_default= *)






cdef void _tcp_worker_fn  (void* arg) noexcept nogil
cdef void _udp_worker_fn  (void* arg) noexcept nogil
cdef void _http_worker_fn (void* arg) noexcept nogil
cdef void _smtp_worker_fn (void* arg) noexcept nogil


cdef int  _tcp_push_fn  (const char* data, size_t len, void* ud) noexcept nogil
cdef void _tcp_flush_fn (void* ud) noexcept nogil
cdef int  _udp_push_fn  (const char* data, size_t len, void* ud) noexcept nogil
cdef void _udp_flush_fn (void* ud) noexcept nogil
cdef int  _http_push_fn (const char* data, size_t len, void* ud) noexcept nogil
cdef void _http_flush_fn(void* ud) noexcept nogil
cdef int  _smtp_push_fn (const char* data, size_t len, void* ud) noexcept nogil
cdef void _smtp_flush_fn(void* ud) noexcept nogil
