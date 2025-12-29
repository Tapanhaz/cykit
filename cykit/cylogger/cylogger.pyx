
from cpython.bytes cimport PyBytes_AsString 
from cykit.common cimport PyErr_SetString, PyExc_TypeError

cdef class LogHandler:

    def __init__(
        self,  
        bint color=True, 
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        str level="trace"
            ):
        self.color = color
        self.pattern = pattern
        self.level = level


cdef class StdoutHandler(LogHandler):

    def __init__(        
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        str level="trace", 
        str max_level="info"
            ):
        super().__init__(color, pattern, level)
        self.max_level = max_level

cdef class StderrHandler(LogHandler):
    def __init__(
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        str level="warn"
            ):
        super().__init__(color, pattern, level)

cdef class BasicConsoleHandler(LogHandler):
    def __init__(
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        str level="trace"
            ):
        super().__init__(color, pattern, level)


cdef class ConsoleHandler(LogHandler):
    
    def __init__(
        self,  
        bint color=True,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        str max_stdout_level="info", 
        str min_level="trace"
            ):
        super().__init__(color, pattern, "trace")
        self.max_stdout_level = max_stdout_level
        self.min_level = min_level


cdef class FileHandler(LogHandler):
    
    def __init__(
        self, 
        str filename, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        str level="trace", 
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
        str level="trace", 
        size_t max_size=1048576, 
        size_t max_files=3
            ):
        super().__init__(filename, pattern, level, False)
        self.max_size = max_size
        self.max_files = max_files


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


cdef class Logger:
    
    def __cinit__(
            self, 
            str name, 
            str level=  "trace",
            str pattern= "[%d-%m-%Y %H:%M:%S.%f] [%n] [%^%l%$] %v",
            list handlers = [],
            ColorScheme color_scheme= None,
            bint set_default = False
            ):

        self.factory.set_level(self._str_to_level(level))

        if handlers:
            for h in handlers:
                if isinstance(h, StdoutHandler):
                    self.factory.add_stdout_handler(
                        h.color,
                        h.pattern.encode(),
                        self._str_to_level(h.level),
                        self._str_to_level(h.max_level)
                    )

                elif isinstance(h, StderrHandler):
                    self.factory.add_stderr_handler(
                        h.color,
                        h.pattern.encode(),
                        self._str_to_level(h.level)
                    )

                elif isinstance(h, ConsoleHandler):
                    self.factory.add_console_handler(
                        h.color,
                        h.pattern.encode(),
                        self._str_to_level(h.max_stdout_level),
                        self._str_to_level(h.min_level)
                    )

                elif isinstance(h, BasicConsoleHandler):
                    self.factory.add_basic_console_handler(
                        h.color,
                        h.pattern.encode(),
                        self._str_to_level(h.level)
                    )

                elif isinstance(h, FileHandler):
                    self.factory.add_file_handler(
                        h.filename.encode(),
                        h.pattern.encode(),
                        self._str_to_level(h.level),
                        h.overwrite
                    )

                elif isinstance(h, RotatingFileHandler):
                    self.factory.add_rotating_file_handler(
                        h.filename.encode(),
                        h.max_size,
                        h.max_files,
                        h.pattern.encode(),
                        self._str_to_level(h.level)
                    )
                else:
                    PyErr_SetString(PyExc_TypeError, b"Unknown handler type")
        else:
            self.factory.add_basic_console_handler(
                    True,
                    pattern.encode(),
                    self._str_to_level(level)
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

    #def __dealloc__(self):
    #    if self._logger != NULL:
    #        del self._logger
    
    cdef inline level_enum _str_to_level(self, str level):
        if level.lower() == "trace":
            return level_enum.trace
        elif level.lower() == "debug":
            return level_enum.debug
        elif level.lower() == "info":
            return level_enum.info
        elif level.lower() == "warn":
            return level_enum.warn
        elif level.lower() == "error":
            return level_enum.err
        elif level.lower() == "critical":
            return level_enum.critical
        elif level.lower() == "off":
            return level_enum.off
        else:
            raise ValueError(f"{level} is not a valid level.")
    
    cdef SpdLogger get_logger(self):
        return self._logger    
    
    cpdef void trace(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        TRACE_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())        
        
    cpdef void debug(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        DEBUG_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())
        
    cpdef void info(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        INFO_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())
    
    cpdef void warn(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        WARN_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())
    
    cpdef void error(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        ERROR_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())

    cpdef void critical(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        CRITICAL_PYL(self._logger, fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())   


cdef class DefaultLogger:
    cpdef void trace(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        TRACE_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())        
        
    cpdef void debug(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        DEBUG_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())
        
    cpdef void info(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        INFO_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())
    
    cpdef void warn(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        WARN_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())
    
    cpdef void error(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        ERROR_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())

    cpdef void critical(self, str msg, int fg_color= -1, int bg_color= -1, int effect= -1):
        CRITICAL_PY(fg_color=fg_color, bg_color=bg_color, effect=effect, msg = msg.encode())      


cdef SpdLogger get_logger_by_name(const char* name):
    cdef shared_ptr[logger] logger_ptr = get(name)
    cdef SpdLogger logger = SpdLogger(logger_ptr)
    return logger    

cdef void get_logger_ptr(shared_ptr[logger] &logger, str name= "", bint fallback_to_default= False):
    logger = registry_get_logger_ptr(name, fallback_to_default)

cdef void get_logger(SpdLogger &log, str name= "", bint fallback_to_default= False):
    cdef shared_ptr[logger] logger_ptr = registry_get_logger_ptr(name.encode(), fallback_to_default)
    log = SpdLogger(logger_ptr)
 