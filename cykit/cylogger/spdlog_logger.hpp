
#pragma once

#include <map>
#include <memory>
#include <vector>
#include <string>
#include <cstdarg>
#include <Python.h>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/sink.h>
#include <spdlog/sinks/null_sink.h>
#include <spdlog/sinks/stdout_sinks.h>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/sinks/rotating_file_sink.h>

#ifdef _WIN32
    #include <spdlog/sinks/ansicolor_sink.h>
    #include <spdlog/sinks/ansicolor_sink-inl.h>
#endif

#if PY_VERSION_HEX < 0x030B0000
    #include <frameobject.h>
#endif

namespace {
    static inline PyFrameObject* get_back_frame(PyFrameObject* frame) {
        #if PY_VERSION_HEX >= 0x030B0000
            return frame ? PyFrame_GetBack(frame) : nullptr;
        #else
            return frame ? frame->f_back : nullptr;
        #endif
    }

    static inline void decref_frame(PyFrameObject* frame) {
        #if PY_VERSION_HEX >= 0x030B0000
            Py_XDECREF(frame);
        #else
            (void)frame;
        #endif
    }
}

namespace spdlog_internal {

    class MaxSinkLevel : public spdlog::sinks::sink {
        public:
            MaxSinkLevel(spdlog::sink_ptr sink, spdlog::level::level_enum max_level);

            void log(const spdlog::details::log_msg& msg) override;
            void flush() override;
            void set_pattern(const std::string& pattern) override;
            void set_formatter(std::unique_ptr<spdlog::formatter> formatter) override;
            spdlog::sink_ptr get_sink();
        
        private:
            spdlog::sink_ptr sink_;
            spdlog::level::level_enum max_level_;
    }; 

    // ****************************************************************************

    inline std::shared_ptr<spdlog::logger> get_null_logger() {
        static auto _null_sink = std::make_shared<spdlog::sinks::null_sink_mt>();
        static auto _null_logger = std::make_shared<spdlog::logger>("null", _null_sink);
        _null_logger->set_level(spdlog::level::off);
        return _null_logger;
    }

    inline bool is_console(const spdlog::sink_ptr& sink) {
        if (std::dynamic_pointer_cast<spdlog::sinks::stdout_color_sink_mt>(sink) ||
            std::dynamic_pointer_cast<spdlog::sinks::stdout_sink_mt>(sink) || 
            std::dynamic_pointer_cast<spdlog::sinks::stderr_color_sink_mt>(sink) ||
            std::dynamic_pointer_cast<spdlog::sinks::stderr_sink_mt>(sink) ) {
                return true;
            }

        auto filtered_sink = std::dynamic_pointer_cast<MaxSinkLevel>(sink);

        if (filtered_sink) {
            return is_console(filtered_sink->get_sink());
        }

        return false;
    }

    inline bool is_effect(int effect) {
        return (effect >= 1 && effect <= 7) || effect == 9;
    }

    inline std::string format_str(const char* fmt_str, va_list args) {
        va_list args_copy;
        va_copy(args_copy, args);

        int size = vsnprintf(nullptr, 0, fmt_str, args_copy);

        va_end(args_copy);

        if (size < 0) {
            va_end(args);
            return {};  
        }

        std::vector<char> buffer(size + 1);

        vsnprintf(buffer.data(), buffer.size(), fmt_str, args);

        va_end(args);

        return std::string(buffer.data(), buffer.data() + size); 
    }

    inline std::string format_color(int color, const char* msg) {
        return ((color >= 30 && color <= 37) || (color >= 90 && color <= 97))
            ? fmt::format("\033[{}m{}\033[0m", color, msg)
            : (color >= 0 && color <= 255)
                ? fmt::format("\033[38;5;{}m{}\033[0m", color, msg)
                : std::string(msg);
    }

    inline std::string format_color_bg(int fg_color, int bg_color, int effect, const char* msg) {
        std::string color_codes;

        if (is_effect(effect)) {
            color_codes += std::to_string(effect);
        }

        if (fg_color >= 0 && fg_color <= 255) {
            if(!color_codes.empty()) color_codes += ";";

            if ((fg_color >= 30 && fg_color <= 37) || (fg_color >= 90 && fg_color <= 97)) {
                color_codes += std::to_string(fg_color);
            } else {
                color_codes += "38;5;" + std::to_string(fg_color);
            }        
        } 

        if (bg_color >= 0 && bg_color <= 255) {
            if (!color_codes.empty()) color_codes += ";";

            if ((bg_color >= 40 && bg_color <= 47) || (bg_color >= 100 && bg_color <= 107)) {
                color_codes += std::to_string(bg_color);
            } else {
                color_codes += "48;5;" + std::to_string(bg_color);
            }        
        }

        if(color_codes.empty()) {
            return msg;
        }

        return fmt::format("\033[{}m{}\033[0m", color_codes, msg);
    }

    inline std::string printf_format(const char* fmt_str, ...) {
        va_list args;
        va_start (args, fmt_str);
        std::string message= format_str(fmt_str, args);
        va_end(args);
        return message;
    }

    inline spdlog::source_loc py_caller_loc() {
        PyGILState_STATE gil = PyGILState_Ensure();
        
        PyFrameObject* frame = PyEval_GetFrame();
        PyFrameObject* caller = get_back_frame(frame);
        
        while (caller) {
            PyCodeObject* code = PyFrame_GetCode(caller);
            if (!code) break;

            const char* name = PyUnicode_AsUTF8(code->co_name);
            bool should_skip = (name && strcmp(name, "<module>") == 0);
            Py_DECREF(code);

            if (!should_skip) break;

            PyFrameObject* next = get_back_frame(caller);
            decref_frame(caller);
            caller = next;
        }

        if (!caller) {
            caller = get_back_frame(frame);  
            if (!caller) {
                caller = frame;  
            }
        }

        const char* filename = "<unknown>";
        const char* funcname = "<module>";
        int lineno = 0;

        if (caller) {
            PyCodeObject* code = PyFrame_GetCode(caller);
            if (code) {
                PyObject* f_obj = code->co_filename;
                if (f_obj && PyUnicode_Check(f_obj)) {
                    const char* fullpath = PyUnicode_AsUTF8(f_obj);
                    const char* slash = strrchr(fullpath, '/');
                    filename = slash ? slash + 1 : fullpath;
                }

                PyObject* fn_obj = code->co_name;
                if (fn_obj && PyUnicode_Check(fn_obj))
                    funcname = PyUnicode_AsUTF8(fn_obj);

                lineno = PyFrame_GetLineNumber(caller);
                Py_DECREF(code);
            }

            if (caller != frame) {
                decref_frame(caller); 
            }
        }

        PyGILState_Release(gil);

        return spdlog::source_loc{filename, lineno, funcname};
    }
}


class LoggerFactory {
public:
    LoggerFactory();

    LoggerFactory& set_level(spdlog::level::level_enum level);

    LoggerFactory& add_stdout_handler(
        bool color, 
        const std::string& pattern,
        spdlog::level::level_enum level = spdlog::level::trace, 
        spdlog::level::level_enum max_level = spdlog::level::info
    );

    LoggerFactory& add_stderr_handler(
        bool color, 
        const std::string& pattern, 
        spdlog::level::level_enum level = spdlog::level::warn
    );

    LoggerFactory& add_basic_console_handler(
        bool color, 
        const std::string& pattern, 
        spdlog::level::level_enum level = spdlog::level::trace
    );
    
    LoggerFactory& add_console_handler(
        bool color, 
        const std::string& pattern,
        spdlog::level::level_enum max_stdout_level = spdlog::level::info, 
        spdlog::level::level_enum min_level = spdlog::level::trace
    );

    LoggerFactory& add_file_handler(
        const std::string& filename, 
        const std::string& pattern,  
        spdlog::level::level_enum level = spdlog::level::trace, 
        bool overwrite = false
    );
    
    LoggerFactory& add_rotating_file_handler(
        const std::string& filename, 
        std::size_t max_size, 
        std::size_t max_files,
        const std::string& pattern, 
        spdlog::level::level_enum level = spdlog::level::trace
    );
    
    LoggerFactory& set_color(spdlog::level::level_enum level, int color);
    
    LoggerFactory& set_colors(
        int trace_color, 
        int debug_color, 
        int info_color, 
        int warn_color,
        int error_color, 
        int critical_color
    );

    std::shared_ptr<spdlog::logger> build(const std::string& name, bool default_logger= false);

private:
    spdlog::level::level_enum g_level_;
    std::vector<spdlog::sink_ptr> sinks_;
    
    std::vector<std::shared_ptr<spdlog::sinks::ansicolor_sink<spdlog::details::console_mutex>>> color_sinks_;
};



class SpdLogger {
public:

    SpdLogger();

    explicit SpdLogger(std::shared_ptr<spdlog::logger> logger);

    std::shared_ptr<spdlog::logger>& get_logger() { return _logger; }  
    const std::shared_ptr<spdlog::logger>& get_logger() const { return _logger; }

    void trace(const char* msg, ...);
    void trace(int color, const char* msg, ...);
    void trace(int fg_color, int bg_color, const char* msg, ...);
    void trace(int fg_color, int bg_color, int effect, const char* msg, ...);

    void debug(const char* msg, ...);
    void debug(int color, const char* msg, ...);
    void debug(int fg_color, int bg_color, const char* msg, ...);
    void debug(int fg_color, int bg_color, int effect, const char* msg, ...);

    void info(const char* msg, ...);
    void info(int color, const char* msg, ...);
    void info(int fg_color, int bg_color, const char* msg, ...);
    void info(int fg_color, int bg_color, int effect, const char* msg, ...);

    void warn(const char* msg, ...);
    void warn(int color, const char* msg, ...);
    void warn(int fg_color, int bg_color, const char* msg, ...);
    void warn(int fg_color, int bg_color, int effect, const char* msg, ...);

    void error(const char* msg, ...);
    void error(int color, const char* msg, ...);
    void error(int fg_color, int bg_color, const char* msg, ...);
    void error(int fg_color, int bg_color, int effect, const char* msg, ...);

    void critical(const char* msg, ...);
    void critical(int color, const char* msg, ...);
    void critical(int fg_color, int bg_color, const char* msg, ...);
    void critical(int fg_color, int bg_color, int effect, const char* msg, ...);


private:
    std::shared_ptr<spdlog::logger> _logger;
    
    void color_msg(spdlog::level::level_enum level, int color, const char* msg, va_list args);
    void color_msg_bg(spdlog::level::level_enum level, int fg_color, int bg_color, int effect,  const char* msg, va_list args);
};


class LoggerRegistry {
    public:
        static void set_default(std::shared_ptr<spdlog::logger> logger);
        static std::shared_ptr<spdlog::logger> get_logger(const std::string& logger_name= "", bool fallback_to_default = true);

    private:
        static LoggerRegistry& get_instance();
        std::shared_ptr<spdlog::logger> default_logger_;
};

// ==============================================================================================================

inline void registry_set_default(std::shared_ptr<spdlog::logger> logger) {
    LoggerRegistry::set_default(logger);
}

inline std::shared_ptr<spdlog::logger> registry_get_logger_ptr(const std::string& logger_name, bool fallback_to_default) {
    return LoggerRegistry::get_logger(logger_name, fallback_to_default);
}

// ==============================================================================================================

#define SPDLOG_LOG_IMPL(logger, level, fmt, ...) \
    do { \
            auto& __logger = (logger).get_logger(); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)        

#define SPDLOG_LOG_D_IMPL(level, fmt, ...) \
    do { \
        std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(); \
        if (__logger->should_log(level)) { \
            std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
            spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
            for (auto& __sink : __logger->sinks()) { \
                if (__sink->should_log(level)) { \
                    spdlog::details::log_msg __msg(__loc, __logger->name(), level, __formatted_str); \
                    __sink->log(__msg); \
                } \
            } \
        } \
    } while(0)

#define SPDLOG_LOG_M_IMPL(logger_name, level, fmt, ...) \
    do { \
        std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(logger_name, false); \
        if (__logger->should_log(level)) { \
            std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
            spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
            for (auto& __sink : __logger->sinks()) { \
                if (__sink->should_log(level)) { \
                    spdlog::details::log_msg __msg(__loc, __logger->name(), level, __formatted_str); \
                    __sink->log(__msg); \
                } \
            } \
        } \
    } while(0)


// ==============================================================================================================

#define SPDLOG_LOG_COLOR_IMPL(logger, level, color, fmt, ...) \
    do { \
            auto& __logger = (logger).get_logger(); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                std::string __colored_str = spdlog_internal::format_color(color, __formatted_str.c_str()); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)

#define SPDLOG_LOG_COLOR_D_IMPL(level, color, fmt, ...) \
    do { \
            std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                std::string __colored_str = spdlog_internal::format_color(color, __formatted_str.c_str()); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)

#define SPDLOG_LOG_COLOR_M_IMPL(logger_name, level, color, fmt, ...) \
    do { \
            std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(logger_name, false); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                std::string __colored_str = spdlog_internal::format_color(color, __formatted_str.c_str()); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)


// ==============================================================================================================

#define SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, level, fg_color, bg_color, effect, fmt, ...) \
    do { \
            auto& __logger = (logger).get_logger(); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                std::string __colored_str = spdlog_internal::format_color_bg(fg_color, bg_color, effect, __formatted_str.c_str()); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)
    
#define SPDLOG_LOG_COLOR_BG_FX_D_IMPL(level, fg_color, bg_color, effect, fmt, ...) \
    do { \
            std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                std::string __colored_str = spdlog_internal::format_color_bg(fg_color, bg_color, effect, __formatted_str.c_str()); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)
    
#define SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, level, fg_color, bg_color, effect, fmt, ...) \
    do { \
            std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(logger_name, false); \
            if (__logger->should_log(level)) { \
                std::string __formatted_str = spdlog_internal::printf_format(fmt, ##__VA_ARGS__); \
                std::string __colored_str = spdlog_internal::format_color_bg(fg_color, bg_color, effect, __formatted_str.c_str()); \
                spdlog::source_loc __loc{__FILE__, __LINE__, SPDLOG_FUNCTION}; \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __formatted_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)
    

// ==============================================================================================================

#define SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, level, fg_color, bg_color, effect, msg) \
    do { \
            auto& __logger = (logger).get_logger(); \
            std::string __plain_str = msg ? std::string(msg) : std::string(); \
            if (__logger->should_log(level)) { \
                std::string __colored_str = spdlog_internal::format_color_bg(fg_color, bg_color, effect, __plain_str.c_str()); \
                spdlog::source_loc __loc = spdlog_internal::py_caller_loc(); \
                for (auto& __sink : __logger->sinks()) { \
                    if (__sink->should_log(level)) { \
                        bool __is_console = spdlog_internal::is_console(__sink); \
                        spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __plain_str); \
                        __sink->log(__msg); \
                    } \
                } \
            } \
        } while(0)


#define SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(level, fg_color, bg_color, effect, msg) \
do { \
        std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(); \
        std::string __plain_str = msg ? std::string(msg) : std::string(); \
        if (__logger->should_log(level)) { \
            std::string __colored_str = spdlog_internal::format_color_bg(fg_color, bg_color, effect, __plain_str.c_str()); \
            spdlog::source_loc __loc = spdlog_internal::py_caller_loc(); \
            for (auto& __sink : __logger->sinks()) { \
                if (__sink->should_log(level)) { \
                    bool __is_console = spdlog_internal::is_console(__sink); \
                    spdlog::details::log_msg __msg(__loc, __logger->name(), level, __is_console ? __colored_str : __plain_str); \
                    __sink->log(__msg); \
                } \
            } \
        } \
    } while(0)

// ==============================================================================================================


#define TRACE(fmt, ...)\
    SPDLOG_LOG_D_IMPL(spdlog::level::trace, fmt, ##__VA_ARGS__)

#define DEBUG(fmt, ...)\
    SPDLOG_LOG_D_IMPL(spdlog::level::debug, fmt, ##__VA_ARGS__)

#define INFO(fmt, ...)\
    SPDLOG_LOG_D_IMPL(spdlog::level::info, fmt, ##__VA_ARGS__)

#define WARN(fmt, ...)\
    SPDLOG_LOG_D_IMPL(spdlog::level::warn, fmt, ##__VA_ARGS__)

#define ERROR(fmt, ...)\
    SPDLOG_LOG_D_IMPL(spdlog::level::err, fmt, ##__VA_ARGS__)

#define CRITICAL(fmt, ...)\
    SPDLOG_LOG_D_IMPL(spdlog::level::critical, fmt, ##__VA_ARGS__)


#define TRACE_L(logger, fmt, ...)\
    SPDLOG_LOG_IMPL(logger, spdlog::level::trace, fmt, ##__VA_ARGS__)

#define DEBUG_L(logger, fmt, ...)\
    SPDLOG_LOG_IMPL(logger, spdlog::level::debug, fmt, ##__VA_ARGS__)

#define INFO_L(logger, fmt, ...)\
    SPDLOG_LOG_IMPL(logger, spdlog::level::info, fmt, ##__VA_ARGS__)

#define WARN_L(logger, fmt, ...)\
    SPDLOG_LOG_IMPL(logger, spdlog::level::warn, fmt, ##__VA_ARGS__)

#define ERROR_L(logger, fmt, ...)\
    SPDLOG_LOG_IMPL(logger, spdlog::level::err, fmt, ##__VA_ARGS__)

#define CRITICAL_L(logger, fmt, ...)\
    SPDLOG_LOG_IMPL(logger, spdlog::level::critical, fmt, ##__VA_ARGS__)


#define TRACE_M(logger_name, fmt, ...)\
    SPDLOG_LOG_M_IMPL(logger_name, spdlog::level::trace, fmt, ##__VA_ARGS__)

#define DEBUG_M(logger_name, fmt, ...)\
    SPDLOG_LOG_M_IMPL(logger_name, spdlog::level::debug, fmt, ##__VA_ARGS__)

#define INFO_M(logger_name, fmt, ...)\
    SPDLOG_LOG_M_IMPL(logger_name, spdlog::level::info, fmt, ##__VA_ARGS__)

#define WARN_M(logger_name, fmt, ...)\
    SPDLOG_LOG_M_IMPL(logger_name, spdlog::level::warn, fmt, ##__VA_ARGS__)

#define ERROR_M(logger_name, fmt, ...)\
    SPDLOG_LOG_M_IMPL(logger_name, spdlog::level::err, fmt, ##__VA_ARGS__)

#define CRITICAL_M(logger_name, fmt, ...)\
    SPDLOG_LOG_M_IMPL(logger_name, spdlog::level::critical, fmt, ##__VA_ARGS__)

// ==============================================================================================================

#define TRACE_C(color, fmt, ...)\
    SPDLOG_LOG_COLOR_D_IMPL(spdlog::level::trace, color, fmt, ##__VA_ARGS__)

#define DEBUG_C( color, fmt, ...)\
    SPDLOG_LOG_COLOR_D_IMPL(spdlog::level::debug, color, fmt, ##__VA_ARGS__)

#define INFO_C( color, fmt, ...)\
    SPDLOG_LOG_COLOR_D_IMPL(spdlog::level::info, color, fmt, ##__VA_ARGS__)

#define WARN_C( color, fmt, ...)\
    SPDLOG_LOG_COLOR_D_IMPL(spdlog::level::warn, color, fmt, ##__VA_ARGS__)

#define ERROR_C( color, fmt, ...)\
    SPDLOG_LOG_COLOR_D_IMPL(spdlog::level::err, color, fmt, ##__VA_ARGS__)

#define CRITICAL_C( color, fmt, ...)\
    SPDLOG_LOG_COLOR_D_IMPL(spdlog::level::critical, color, fmt, ##__VA_ARGS__)



#define TRACE_CL(logger, color, fmt, ...)\
    SPDLOG_LOG_COLOR_IMPL(logger, spdlog::level::trace, color, fmt, ##__VA_ARGS__)

#define DEBUG_CL(logger, color, fmt, ...)\
    SPDLOG_LOG_COLOR_IMPL(logger, spdlog::level::debug, color, fmt, ##__VA_ARGS__)

#define INFO_CL(logger, color, fmt, ...)\
    SPDLOG_LOG_COLOR_IMPL(logger, spdlog::level::info, color, fmt, ##__VA_ARGS__)

#define WARN_CL(logger, color, fmt, ...)\
    SPDLOG_LOG_COLOR_IMPL(logger, spdlog::level::warn, color, fmt, ##__VA_ARGS__)

#define ERROR_CL(logger, color, fmt, ...)\
    SPDLOG_LOG_COLOR_IMPL(logger, spdlog::level::err, color, fmt, ##__VA_ARGS__)

#define CRITICAL_CL(logger, color, fmt, ...)\
    SPDLOG_LOG_COLOR_IMPL(logger, spdlog::level::critical, fmt, ##__VA_ARGS__)



#define TRACE_CM(logger_name, color, fmt, ...)\
    SPDLOG_LOG_COLOR_M_IMPL(logger_name, spdlog::level::trace, color, fmt, ##__VA_ARGS__)

#define DEBUG_CM(logger_name, color, fmt, ...)\
    SPDLOG_LOG_COLOR_M_IMPL(logger_name, spdlog::level::debug, color, fmt, ##__VA_ARGS__)

#define INFO_CM(logger_name, color, fmt, ...)\
    SPDLOG_LOG_COLOR_M_IMPL(logger_name, spdlog::level::info, color, fmt, ##__VA_ARGS__)

#define WARN_CM(logger_name, color, fmt, ...)\
    SPDLOG_LOG_COLOR_M_IMPL(logger_name, spdlog::level::warn, color, fmt, ##__VA_ARGS__)

#define ERROR_CM(logger_name, color, fmt, ...)\
    SPDLOG_LOG_COLOR_M_IMPL(logger_name, spdlog::level::err, color, fmt, ##__VA_ARGS__)

#define CRITICAL_CM(logger_name, color, fmt, ...)\
    SPDLOG_LOG_COLOR_M_IMPL(logger_name, spdlog::level::critical, color, fmt, ##__VA_ARGS__)

// ==============================================================================================================

#define TRACE_FX( fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_D_IMPL(spdlog::level::trace, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define DEBUG_FX( fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_D_IMPL(spdlog::level::debug, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define INFO_FX( fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_D_IMPL(spdlog::level::info, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define WARN_FX( fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_D_IMPL(spdlog::level::warn, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define ERROR_FX( fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_D_IMPL(spdlog::level::err, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define CRITICAL_FX( fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_D_IMPL(spdlog::level::critical, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)



#define TRACE_FXL(logger, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, spdlog::level::trace, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define DEBUG_FXL(logger, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, spdlog::level::debug, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define INFO_FXL(logger, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, spdlog::level::info, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define WARN_FXL(logger, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, spdlog::level::warn, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define ERROR_FXL(logger, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, spdlog::level::err, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define CRITICAL_FXL(logger, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_IMPL(logger, spdlog::level::critical, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)



#define TRACE_FXM(logger_name, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, spdlog::level::trace, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define DEBUG_FXM(logger_name, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, spdlog::level::debug, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define INFO_FXM(logger_name, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, spdlog::level::info, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define WARN_FXM(logger_name, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, spdlog::level::warn, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define ERROR_FXM(logger_name, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, spdlog::level::err, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

#define CRITICAL_FXM(logger_name, fg_color, bg_color, effect, fmt, ...)\
    SPDLOG_LOG_COLOR_BG_FX_M_IMPL(logger_name, spdlog::level::critical, fg_color, bg_color, effect, fmt, ##__VA_ARGS__)

// ==============================================================================================================

#define TRACE_PY(fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(spdlog::level::trace, fg_color, bg_color, effect, msg)

#define DEBUG_PY(fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(spdlog::level::debug, fg_color, bg_color, effect, msg)

#define INFO_PY(fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(spdlog::level::info, fg_color, bg_color, effect, msg)

#define WARN_PY(fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(spdlog::level::warn, fg_color, bg_color, effect, msg)

#define ERROR_PY(fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(spdlog::level::err, fg_color, bg_color, effect, msg)

#define CRITICAL_PY(fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_D_IMPL(spdlog::level::critical, fg_color, bg_color, effect, msg)


#define TRACE_PYL(logger, fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, spdlog::level::trace, fg_color, bg_color, effect, msg)

#define DEBUG_PYL(logger, fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, spdlog::level::debug, fg_color, bg_color, effect, msg)

#define INFO_PYL(logger, fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, spdlog::level::info, fg_color, bg_color, effect, msg)

#define WARN_PYL(logger, fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, spdlog::level::warn, fg_color, bg_color, effect, msg)

#define ERROR_PYL(logger, fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, spdlog::level::err, fg_color, bg_color, effect, msg)

#define CRITICAL_PYL(logger, fg_color, bg_color, effect, msg)\
    SPDLOG_LOG_COLOR_BG_FX_PY_IMPL(logger, spdlog::level::critical, fg_color, bg_color, effect, msg)
    