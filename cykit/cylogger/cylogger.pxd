
from libcpp cimport bool as cbool
from libcpp.string cimport string
from libcpp.memory cimport shared_ptr

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

cdef extern from "spdlog_logger.hpp":
    pass

cdef extern from "spdlog_logger.hpp" nogil:
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


cpdef enum class Level:
    TRACE = level_enum.trace
    DEBUG = level_enum.debug
    INFO = level_enum.info
    WARN = level_enum.warn
    ERROR = level_enum.err
    CRITICAL = level_enum.critical
    OFF = level_enum.off

cdef class LogHandler:
    cdef:
        public bint color
        public str pattern
        public Level level


cdef class StdoutHandler(LogHandler):
    cdef public Level max_level


cdef class StderrHandler(LogHandler):
    pass


cdef class BasicConsoleHandler(LogHandler):
    pass


cdef class ConsoleHandler(LogHandler):
    cdef:
        public Level max_stdout_level
        public Level min_level


cdef class FileHandler(LogHandler):
    cdef:
        public str filename
        public bint overwrite


cdef class RotatingFileHandler(FileHandler):
    cdef:
        public size_t max_size
        public size_t max_files


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
    
    cdef SpdLogger get_logger(self)

    cpdef void trace(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void debug(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void info(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void warn(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void error(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void critical(self, str msg, int fg_color= *, int bg_color= *, int effect= *)


cdef class DefaultLogger:
    cpdef void trace(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void debug(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void info(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void warn(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void error(self, str msg, int fg_color= *, int bg_color= *, int effect= *)
    cpdef void critical(self, str msg, int fg_color= *, int bg_color= *, int effect= *)

cdef SpdLogger get_logger_by_name(const char* name)
cdef void get_logger_ptr(shared_ptr[logger] &logger, str name= *, bint fallback_to_default= *)
cdef void get_logger(SpdLogger &log, str name= *, bint fallback_to_default= *)

