
/**
 * @file spdlog_logger.hpp
 * @brief Header for interfacing with spdlog
 * @date 2025-12-27 22:55:42 +0530
 * @copyright Part of the https://github.com/Tapanhaz/cykit library.
 */


#pragma once

#ifndef SPDLOG_HEADER_ONLY
    #define SPDLOG_HEADER_ONLY
#endif

#ifndef FMT_HEADER_ONLY
    #define FMT_HEADER_ONLY
#endif

#include <map>
#include <mutex>
#include <memory>
#include <vector>
#include <string>
#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <Python.h>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/sink.h>
#include <spdlog/sinks/base_sink.h>
#include <spdlog/details/log_msg.h>
#include <spdlog/sinks/null_sink.h>
#include <spdlog/details/fmt_helper.h>
#include <spdlog/sinks/stdout_sinks.h>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/daily_file_sink.h>
#include <spdlog/sinks/stdout_color_sinks.h>
#include <spdlog/sinks/rotating_file_sink.h>


#ifdef _WIN32
    #include <spdlog/sinks/ansicolor_sink.h>
    #include <spdlog/sinks/ansicolor_sink-inl.h>
#endif

#if PY_VERSION_HEX < 0x030B0000
    #include <frameobject.h>
#endif

#ifdef _WIN32
    #ifdef ERROR
        #undef ERROR
    #endif
#endif


enum class SinkOverflowPolicy : uint8_t {
    DROP_OLDEST = 0,
    DROP_NEWEST = 1,
    BLOCK       = 2
};


typedef int  (*SinkPushFn) (const char* data, size_t len, void* userdata);
typedef void (*SinkFlushFn)(void* userdata);



namespace sink_adapter {

    class SinkAdapter final : public spdlog::sinks::base_sink<std::mutex> {
    public:
        SinkAdapter(
            SinkPushFn          push_fn,
            SinkFlushFn         flush_fn,
            void*               userdata,
            SinkOverflowPolicy  overflow_policy
        ) : push_fn_(push_fn), flush_fn_(flush_fn),
            userdata_(userdata), overflow_policy_(overflow_policy) {}
    
        ~SinkAdapter() = default;
    
    protected:
        void sink_it_(const spdlog::details::log_msg& msg) override {
            fmt_buf_.clear();
            formatter_->format(msg, fmt_buf_);
            //fmt_buf_.push_back('\0');
    
            //int ret = push_fn_(fmt_buf_.data(), fmt_buf_.size() - 1, userdata_);
            int ret = push_fn_(fmt_buf_.data(), fmt_buf_.size(), userdata_);
    
            if (ret == -2) {
                if (overflow_policy_ == SinkOverflowPolicy::DROP_NEWEST) {
                    return; 
                }
                
            }
            (void)ret;
        }
    
        void flush_() override {
            if (flush_fn_) flush_fn_(userdata_);
        }
    
    private:
        SinkPushFn          push_fn_;
        SinkFlushFn         flush_fn_;
        void*               userdata_;
        SinkOverflowPolicy  overflow_policy_;
        spdlog::memory_buf_t fmt_buf_;
    };
    
}



namespace spdlog_internal {

    class MaxSinkLevel : public spdlog::sinks::sink {
        public:
            MaxSinkLevel(spdlog::sink_ptr sink, spdlog::level::level_enum max_level)
                    : sink_(std::move(sink)), max_level_(max_level) {}

            void log(const spdlog::details::log_msg& msg) override {
                if (msg.level <= max_level_) {
                    sink_->log(msg);
                }
            }
            
            void flush() override {
                sink_->flush();
            }

            void set_pattern(const std::string& pattern) override {
                sink_->set_pattern(pattern);
            } 
            void set_formatter(std::unique_ptr<spdlog::formatter> formatter) override {
                sink_->set_formatter(std::move(formatter));
            }
            
            spdlog::sink_ptr get_sink() {
                return sink_;
            }
        
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

    inline std::shared_ptr<spdlog::sinks::stdout_color_sink_mt> get_console_sink() {
        static auto sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
        sink->set_level(spdlog::level::trace); 
        return sink;
    }

    inline spdlog::source_loc py_caller_loc() {
        PyGILState_STATE gil = PyGILState_Ensure();
        PyFrameObject* frame = PyEval_GetFrame();
        PyFrameObject* caller = nullptr;

        if (frame) {
        #if PY_VERSION_HEX >= 0x030B0000
                caller = PyFrame_GetBack(frame);
                while (caller) {
                    PyCodeObject* code = PyFrame_GetCode(caller);
                    if (!code) break;
                    const char* name = PyUnicode_AsUTF8(code->co_name);
                    Py_DECREF(code); 
                    if (name && strcmp(name, "<module>") != 0) break;
                    caller = PyFrame_GetBack(caller);
                }
        #else
                caller = frame->f_back;
                while (caller) {
                    PyCodeObject* code = caller->f_code;
                    if (!code) break;
                    const char* name = PyUnicode_AsUTF8(code->co_name);
                    if (name && strcmp(name, "<module>") != 0) break;
                    caller = caller->f_back;
                }
        #endif
            }

            if (!caller) caller = frame;

            const char* filename = "<unknown>";
            const char* funcname = "<module>";
            int lineno = 0;

            if (caller) {
        #if PY_VERSION_HEX >= 0x030B0000
                PyCodeObject* code = PyFrame_GetCode(caller);
        #else
                PyCodeObject* code = caller->f_code;
        #endif
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

        #if PY_VERSION_HEX >= 0x030B0000
                    Py_DECREF(code); 
        #endif
                }
            }

        PyGILState_Release(gil);

        return spdlog::source_loc{filename, lineno, funcname};
    }    
    

    inline spdlog::source_loc pylog_caller_loc() {
        PyGILState_STATE gil = PyGILState_Ensure();
        PyFrameObject* frame = PyEval_GetFrame();
        PyFrameObject* caller = nullptr;
        
        if (frame) {
    #if PY_VERSION_HEX >= 0x030B0000
            caller = PyFrame_GetBack(frame);
            
            while (caller) {
                PyCodeObject* code = PyFrame_GetCode(caller);
                if (!code) break;
                
                PyObject* f_obj = code->co_filename;
                const char* filename = "";
                if (f_obj && PyUnicode_Check(f_obj)) {
                    filename = PyUnicode_AsUTF8(f_obj);
                }
                                
                bool is_logging = (strstr(filename, "logging") != nullptr && 
                                  strstr(filename, "__init__.py") != nullptr);
                
                Py_DECREF(code);
                
                if (!is_logging) break; 
                
                caller = PyFrame_GetBack(caller);
            }
            
            while (caller) {
                PyCodeObject* code = PyFrame_GetCode(caller);
                if (!code) break;
                const char* name = PyUnicode_AsUTF8(code->co_name);
                Py_DECREF(code);
                if (name && strcmp(name, "<module>") != 0) break;
                caller = PyFrame_GetBack(caller);
            }
    #else
            caller = frame->f_back;
            while (caller) {
                PyCodeObject* code = caller->f_code;
                if (!code) break;
                
                PyObject* f_obj = code->co_filename;
                const char* filename = "";
                if (f_obj && PyUnicode_Check(f_obj)) {
                    filename = PyUnicode_AsUTF8(f_obj);
                }
                
                bool is_logging = (strstr(filename, "logging") != nullptr && 
                                  strstr(filename, "__init__.py") != nullptr);
                
                if (!is_logging) break;
                
                caller = caller->f_back;
            }
            
            while (caller) {
                PyCodeObject* code = caller->f_code;
                if (!code) break;
                const char* name = PyUnicode_AsUTF8(code->co_name);
                if (name && strcmp(name, "<module>") != 0) break;
                caller = caller->f_back;
            }
    #endif
        }
        
        if (!caller) caller = frame;
        
        const char* filename = "<unknown>";
        const char* funcname = "<module>";
        int lineno = 0;
        
        if (caller) {
    #if PY_VERSION_HEX >= 0x030B0000
            PyCodeObject* code = PyFrame_GetCode(caller);
    #else
            PyCodeObject* code = caller->f_code;
    #endif
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
    #if PY_VERSION_HEX >= 0x030B0000
                Py_DECREF(code); 
    #endif
            }
        }
        
        PyGILState_Release(gil);
        return spdlog::source_loc{filename, lineno, funcname};
    }
}

// ==============================================================================================================

class LoggerRegistry {
    public:
        static void set_default(std::shared_ptr<spdlog::logger> logger) {
            get_instance().default_logger_ = logger;
        }

        static std::shared_ptr<spdlog::logger> get_logger(const std::string& logger_name= "", bool fallback_to_default = true) {    
            std::shared_ptr<spdlog::logger> logger_;
            if (!logger_name.empty()) {
                logger_ = spdlog::get(logger_name);
        
                if(!logger_ && !fallback_to_default) {
                    return spdlog_internal::get_null_logger();
                }
            } else {
                logger_ = get_instance().default_logger_;
            }
        
            if (!logger_) {
                return spdlog_internal::get_null_logger();
            }
        
            return logger_;
        }

    private:
        static LoggerRegistry& get_instance() {
            static LoggerRegistry instance;
            return instance;
        }


        std::shared_ptr<spdlog::logger> default_logger_;
};

// ==============================================================================================================

class LoggerFactory {
    public:
        LoggerFactory() : g_level_(spdlog::level::trace) {}

        LoggerFactory& set_level(spdlog::level::level_enum level) {
            g_level_ = static_cast<spdlog::level::level_enum>(level);
            return *this;
        }

        LoggerFactory& add_stdout_handler(
            bool color, 
            const std::string& pattern,
            spdlog::level::level_enum level = spdlog::level::trace, 
            spdlog::level::level_enum max_level = spdlog::level::info
        ) {
            spdlog::sink_ptr sink;
            if (color){
                //auto stdout_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
                auto stdout_sink = std::make_shared<spdlog::sinks::ansicolor_stdout_sink_mt>();
                color_sinks_.push_back(stdout_sink);
                sink = stdout_sink;
            } else {
                sink = std::make_shared<spdlog::sinks::stdout_sink_mt>();
            }

            sink->set_pattern(pattern);
            sink->set_level(level);

            auto filtered_sink = std::make_shared<spdlog_internal::MaxSinkLevel>(sink, max_level);
            sinks_.push_back(filtered_sink);
            return *this;
        } 

        LoggerFactory& add_stderr_handler(
            bool color, 
            const std::string& pattern, 
            spdlog::level::level_enum level = spdlog::level::warn
        ) {
            spdlog::sink_ptr sink;

            if (color) {
                //auto err_sink = std::make_shared<spdlog::sinks::stderr_color_sink_mt>();
                auto err_sink = std::make_shared<spdlog::sinks::ansicolor_stdout_sink_mt>();
                color_sinks_.push_back(err_sink);
                sink = err_sink;
            } else {
                sink = std::make_shared<spdlog::sinks::stderr_sink_mt>();
            }

            sink->set_pattern(pattern);
            sink->set_level(level);

            sinks_.push_back(sink); 
            return *this;  
        } 

        LoggerFactory& add_basic_console_handler(
            bool color, 
            const std::string& pattern, 
            spdlog::level::level_enum level = spdlog::level::trace
        ) {
            spdlog::sink_ptr sink;
            if(color) {
                //auto console_sink = std::make_shared<spdlog::sinks::stdout_color_sink_mt>();
                auto console_sink = std::make_shared<spdlog::sinks::ansicolor_stdout_sink_mt>();
                color_sinks_.push_back(console_sink);
                sink = console_sink;
            } else {
                sink = std::make_shared<spdlog::sinks::stdout_sink_mt>();
            }

            sink->set_pattern(pattern);
            sink->set_level(level);

            sinks_.push_back(sink); 
            return *this;           
        }

        LoggerFactory& add_console_handler(
            bool color, 
            const std::string& pattern,
            spdlog::level::level_enum max_stdout_level = spdlog::level::info, 
            spdlog::level::level_enum min_level = spdlog::level::trace
        ) {
            add_stdout_handler(color, pattern, min_level, max_stdout_level);

            int stderr_min_level = static_cast<int>(max_stdout_level) + 1;

            if (stderr_min_level > static_cast<int>(spdlog::level::critical)) {
                stderr_min_level = static_cast<int>(spdlog::level::critical);
            }

            add_stderr_handler(color, pattern, static_cast<spdlog::level::level_enum>(stderr_min_level));

            return *this;
        }

        LoggerFactory& add_file_handler(
            const std::string& filename, 
            const std::string& pattern,  
            spdlog::level::level_enum level = spdlog::level::trace, 
            bool overwrite = false
        ) {

            auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt> (filename, overwrite);
            file_sink->set_pattern(pattern);
            file_sink->set_level(level);
            sinks_.push_back(file_sink);
            return *this;
        }

        LoggerFactory& add_rotating_file_handler(
            const std::string& filename, 
            std::size_t max_size, 
            std::size_t max_files,
            const std::string& pattern, 
            spdlog::level::level_enum level = spdlog::level::trace
        ) {

            auto rotating_file_sink = std::make_shared<spdlog::sinks::rotating_file_sink_mt> (filename, max_size, max_files);
            rotating_file_sink->set_pattern(pattern);
            rotating_file_sink->set_level(level);
            sinks_.push_back(rotating_file_sink);
            return *this;
        }

        LoggerFactory& add_daily_file_handler(
            const std::string& filename,
            int rotation_hour,
            int rotation_minute,
            const std::string& pattern,
            spdlog::level::level_enum level = spdlog::level::trace,
            bool truncate = false,
            uint16_t max_files = 0
        ) {

            auto daily_sink = std::make_shared<spdlog::sinks::daily_file_sink_mt>(
                filename, rotation_hour, rotation_minute, truncate, max_files
            );
            daily_sink->set_pattern(pattern);
            daily_sink->set_level(level);
            sinks_.push_back(daily_sink);
            return *this;
        }

        LoggerFactory& add_custom_sink_handler(
            SinkPushFn          push_fn,
            SinkFlushFn         flush_fn,
            void*               userdata,
            SinkOverflowPolicy  overflow_policy,
            spdlog::level::level_enum level,
            const std::string&  pattern
        ) {

            auto sink = std::make_shared<sink_adapter::SinkAdapter>(
                push_fn, flush_fn, userdata, overflow_policy
            );
            sink->set_level(level);
            sink->set_pattern(pattern);
            sinks_.push_back(sink);
            return *this;
        }

        LoggerFactory& set_color(spdlog::level::level_enum level, int color) {
            std::string color_code;
        
            if ((color >= 30 && color <= 37) || (color >= 90 && color <= 97)) {
                color_code = std::string("\033[") + std::to_string(color) + "m";
            } else if (color >= 0 && color <= 255) {
                color_code = std::string("\033[38;5;") + std::to_string(color) + "m";
            } else {
                return *this;
            }
        
            for (auto& color_sink : color_sinks_) {
                color_sink->set_color(level, color_code);
            }
        
            return *this;
        }

        LoggerFactory& set_colors(
            int trace_color, 
            int debug_color, 
            int info_color, 
            int warn_color,
            int error_color, 
            int critical_color
        ) {

            set_color(spdlog::level::trace, trace_color);
            set_color(spdlog::level::debug, debug_color);
            set_color(spdlog::level::info, info_color);
            set_color(spdlog::level::warn, warn_color);
            set_color(spdlog::level::err, error_color);
            set_color(spdlog::level::critical, critical_color);

            return *this;
        }

        std::shared_ptr<spdlog::logger> build(const std::string& name, bool default_logger= false) {
            auto logger = std::make_shared<spdlog::logger>(name, sinks_[0]);
        
            for (size_t i= 1; i < sinks_.size(); i++) {
                logger->sinks().push_back(sinks_[i]);
            }

            logger->set_level(static_cast<spdlog::level::level_enum>(g_level_));
            spdlog::register_logger(logger);
        
            if (default_logger) {
                //spdlog::set_default_logger(logger);
                LoggerRegistry::set_default(logger);
            }
            return logger;
        }

    private:
        spdlog::level::level_enum g_level_;
        std::vector<spdlog::sink_ptr> sinks_;

        std::vector<std::shared_ptr<spdlog::sinks::ansicolor_sink<spdlog::details::console_mutex>>> color_sinks_;
};

// ==============================================================================================================

class SpdLogger {
public:

    SpdLogger() : _logger(spdlog_internal::get_null_logger()) {}

    explicit SpdLogger(std::shared_ptr<spdlog::logger> logger)
                    : _logger(logger) {}

    std::shared_ptr<spdlog::logger>& get_logger() { return _logger; }  
    const std::shared_ptr<spdlog::logger>& get_logger() const { return _logger; }

    void trace(const char* msg, ...) {
        va_list args;
        va_start (args, msg);
        std::string message= spdlog_internal::format_str(msg, args);
        va_end(args);
        _logger->trace(message);
    }
    
    void trace(int color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg(spdlog::level::trace, color, msg, args);
        va_end(args); 
    }

    void trace(int fg_color, int bg_color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::trace, fg_color, bg_color, -1, msg, args);
        va_end(args);            
    }

    void trace(int fg_color, int bg_color, int effect, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::trace, fg_color, bg_color, effect, msg, args);
        va_end(args);            
    }


    void debug(const char* msg, ...) {
        va_list args;
        va_start (args, msg);
        std::string message= spdlog_internal::format_str(msg, args);
        va_end(args);
        _logger->debug(message);
    }

    void debug(int color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg(spdlog::level::debug, color, msg, args);
        va_end(args); 
    }

    void debug(int fg_color, int bg_color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::debug, fg_color, bg_color, -1, msg, args);
        va_end(args);            
    }

    void debug(int fg_color, int bg_color, int effect, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::debug, fg_color, bg_color, effect, msg, args);
        va_end(args);            
    }


    void info(const char* msg, ...) {
        va_list args;
        va_start (args, msg);
        std::string message= spdlog_internal::format_str(msg, args);
        va_end(args);
        _logger->info(message);           
    }

    void info(int color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg(spdlog::level::info, color, msg, args);
        va_end(args); 
    }

    void info(int fg_color, int bg_color, const char* msg, ...)  {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::info, fg_color, bg_color, -1, msg, args);
        va_end(args);            
    }

    void info(int fg_color, int bg_color, int effect, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::info, fg_color, bg_color, effect, msg, args);
        va_end(args);            
    }


    void warn(const char* msg, ...) {
        va_list args;
        va_start (args, msg);
        std::string message= spdlog_internal::format_str(msg, args);
        va_end(args);
        _logger->warn(message);
    }

    void warn(int color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg(spdlog::level::warn, color, msg, args);
        va_end(args); 
    }

    void warn(int fg_color, int bg_color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::warn, fg_color, bg_color, -1, msg, args);
        va_end(args);            
    }

    void warn(int fg_color, int bg_color, int effect, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::warn, fg_color, bg_color, effect, msg, args);
        va_end(args);            
    }


    void error(const char* msg, ...) {
        va_list args;
        va_start (args, msg);
        std::string message= spdlog_internal::format_str(msg, args);
        va_end(args);
        _logger->error(message);
    }

    void error(int color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg(spdlog::level::err, color, msg, args);
        va_end(args); 
    }

    void error(int fg_color, int bg_color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::err, fg_color, bg_color, -1, msg, args);
        va_end(args);            
    }

    void error(int fg_color, int bg_color, int effect, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::err, fg_color, bg_color, effect, msg, args);
        va_end(args);            
    }


    void critical(const char* msg, ...) {
        va_list args;
        va_start (args, msg);
        std::string message= spdlog_internal::format_str(msg, args);
        va_end(args);
        _logger->critical(message);
    }

    void critical(int color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg(spdlog::level::critical, color, msg, args);
        va_end(args);            
    }

    void critical(int fg_color, int bg_color, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::critical, fg_color, bg_color, -1, msg, args);
        va_end(args);            
    }

    void critical(int fg_color, int bg_color, int effect, const char* msg, ...) {
        va_list args;
        va_start(args, msg);
        color_msg_bg(spdlog::level::critical, fg_color, bg_color, effect, msg, args);
        va_end(args);            
    }


private:
    std::shared_ptr<spdlog::logger> _logger;
    
    void color_msg(spdlog::level::level_enum level, int color, const char* msg, va_list args) {
        std::string _msg = spdlog_internal::format_str(msg, args);
        std::string _colored_msg = spdlog_internal::format_color(color, _msg.c_str());
    
        spdlog::details::log_msg console_msg(_logger->name(), level, _colored_msg);
        spdlog::details::log_msg file_msg(_logger->name(), level, _msg);
    
        for (auto sink : _logger->sinks()) {
            if (sink->should_log(level)) {
                if (spdlog_internal::is_console(sink)) {
                    sink->log(console_msg);
                } else {
                    sink->log(file_msg);
                }
            }
        }
    }

    void color_msg_bg(spdlog::level::level_enum level, int fg_color, int bg_color, int effect,  const char* msg, va_list args) {
        std::string _msg = spdlog_internal::format_str(msg, args);
        std::string _colored_msg = spdlog_internal::format_color_bg(fg_color, bg_color, effect,  _msg.c_str());
    
        spdlog::details::log_msg console_msg(_logger->name(), level, _colored_msg);
        spdlog::details::log_msg file_msg(_logger->name(), level, _msg);
    
        for (auto sink : _logger->sinks()) {  
            if (sink->should_log(level)) {              
                if (spdlog_internal::is_console(sink)) {
                    sink->log(console_msg);
                } else {
                    sink->log(file_msg);
                }
            }               
            
        }
    }
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

#define SPDLOG_LOG_PY_LOGGER_D_IMPL(level, msg) \
do { \
        std::shared_ptr<spdlog::logger> __logger = LoggerRegistry::get_logger(); \
        std::string __plain_str = msg ? std::string(msg) : std::string(); \
        if (__logger->should_log(level)) { \
            spdlog::source_loc __loc = spdlog_internal::pylog_caller_loc(); \
            for (auto& __sink : __logger->sinks()) { \
                if (__sink->should_log(level)) { \
                    spdlog::details::log_msg __msg(__loc, __logger->name(), level, __plain_str); \
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


#define TRACE_PY_LOG(msg)\
    SPDLOG_LOG_PY_LOGGER_D_IMPL(spdlog::level::trace, msg)

#define DEBUG_PY_LOG(msg)\
    SPDLOG_LOG_PY_LOGGER_D_IMPL(spdlog::level::debug, msg)

#define INFO_PY_LOG(msg)\
    SPDLOG_LOG_PY_LOGGER_D_IMPL(spdlog::level::info, msg)

#define WARN_PY_LOG(msg)\
    SPDLOG_LOG_PY_LOGGER_D_IMPL(spdlog::level::warn, msg)

#define ERROR_PY_LOG(msg)\
    SPDLOG_LOG_PY_LOGGER_D_IMPL(spdlog::level::err, msg)

#define CRITICAL_PY_LOG(msg)\
    SPDLOG_LOG_PY_LOGGER_D_IMPL(spdlog::level::critical, msg)


// ==============================================================================================================
    
