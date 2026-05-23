

import traceback
import logging as py_logging
from cykit.common cimport (
    PyObject,
    Py_DECREF,
    PyObject_Str,
    PyExc_TypeError,
    PyErr_SetString, 
    PyUnicode_Format,
    PyUnicode_AsUTF8,
)


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



cdef class LogHandler:

    def __init__(
        self,  
        bint color=True, 
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        Level level=Level.TRACE
            ):
        self.color = color
        self.pattern = pattern
        self.level = level


cdef class StdoutHandler(LogHandler):

    def __init__(        
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        Level level=Level.TRACE, 
        Level max_level=Level.INFO
            ):
        super().__init__(color, pattern, level)
        self.max_level = max_level

cdef class StderrHandler(LogHandler):
    def __init__(
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        Level level=Level.WARN
            ):
        super().__init__(color, pattern, level)

cdef class BasicConsoleHandler(LogHandler):
    def __init__(
        self, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        Level level=Level.TRACE
            ):
        super().__init__(color, pattern, level)


cdef class ConsoleHandler(LogHandler):
    
    def __init__(
        self,  
        bint color=True,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        Level max_stdout_level=Level.INFO, 
        Level min_level=Level.TRACE
            ):
        super().__init__(color, pattern, Level.TRACE)
        self.max_stdout_level = max_stdout_level
        self.min_level = min_level


cdef class FileHandler(LogHandler):
    
    def __init__(
        self, 
        str filename, 
        bint color=False,
        str pattern="[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        Level level=Level.TRACE, 
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
        Level level=Level.TRACE, 
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


cdef class Logger:
    
    def __init__(
            self, 
            str name, 
            Level level=  Level.TRACE,
            str pattern= "[%d-%m-%Y %H:%M:%S.%f] [%n] [%^%l%$] %v",
            list handlers = [],
            ColorScheme color_scheme= None,
            bint set_default = False,
            bint intercept_stdlib_logging = True,
            ):

        self.factory.set_level(<level_enum>level)

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

    #def __dealloc__(self):
    #    if self._logger != NULL:
    #        del self._logger
        
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
 