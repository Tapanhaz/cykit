
#include "spdlog_logger.hpp"


//SPDLOG_INTERNAL vvvv

// => class MaxSinkLevel vvvv

spdlog_internal::MaxSinkLevel::MaxSinkLevel(spdlog::sink_ptr sink, spdlog::level::level_enum max_level)
                    : sink_(std::move(sink)), max_level_(max_level) {}

void spdlog_internal::MaxSinkLevel::log(const spdlog::details::log_msg& msg) {
    if (msg.level <= max_level_) {
        sink_->log(msg);
    }
}

void spdlog_internal::MaxSinkLevel::flush() {
    sink_->flush();
}

void spdlog_internal::MaxSinkLevel::set_pattern(const std::string& pattern) {
    sink_->set_pattern(pattern);
}

void spdlog_internal::MaxSinkLevel::set_formatter(std::unique_ptr<spdlog::formatter> formatter) {
    sink_->set_formatter(std::move(formatter));
}

spdlog::sink_ptr spdlog_internal::MaxSinkLevel::get_sink() {
    return sink_;
}

//===========================================================================================
//===========================================================================================

// => class LoggerRegistry vvvv

void LoggerRegistry::set_default(std::shared_ptr<spdlog::logger> logger) {
    get_instance().default_logger_ = logger;
}

std::shared_ptr<spdlog::logger> LoggerRegistry::get_logger(const std::string& logger_name, bool fallback_to_default) {    
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

LoggerRegistry& LoggerRegistry::get_instance() {
    static LoggerRegistry instance;
    return instance;
}


//===========================================================================================
//===========================================================================================

// => class LoggerFactory vvvv

LoggerFactory::LoggerFactory() : g_level_(spdlog::level::trace) {}

LoggerFactory& LoggerFactory::set_level(spdlog::level::level_enum level) {
    g_level_ = static_cast<spdlog::level::level_enum>(level);
    return *this;
}

LoggerFactory& LoggerFactory::add_stdout_handler(bool color, const std::string& pattern,
    spdlog::level::level_enum level, spdlog::level::level_enum max_level) {
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

LoggerFactory& LoggerFactory::add_stderr_handler(bool color, const std::string& pattern, 
    spdlog::level::level_enum level) {
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

LoggerFactory& LoggerFactory::add_basic_console_handler(
    bool color, const std::string& pattern, spdlog::level::level_enum level) {
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

LoggerFactory& LoggerFactory::add_console_handler(bool color, const std::string& pattern,
    spdlog::level::level_enum max_stdout_level, spdlog::level::level_enum min_level) {
        add_stdout_handler(color, pattern, min_level, max_stdout_level);

        int stderr_min_level = static_cast<int>(max_stdout_level) + 1;

        if (stderr_min_level > static_cast<int>(spdlog::level::critical)) {
            stderr_min_level = static_cast<int>(spdlog::level::critical);
        }

        add_stderr_handler(color, pattern, static_cast<spdlog::level::level_enum>(stderr_min_level));

        return *this;
}        
        
LoggerFactory& LoggerFactory::add_file_handler(
    const std::string& filename, const std::string& pattern,  
    spdlog::level::level_enum level, bool overwrite) {
        
        auto file_sink = std::make_shared<spdlog::sinks::basic_file_sink_mt> (filename, overwrite);
        file_sink->set_pattern(pattern);
        file_sink->set_level(level);
        sinks_.push_back(file_sink);
        return *this;
}

LoggerFactory& LoggerFactory::add_rotating_file_handler(
    const std::string& filename, std::size_t max_size, std::size_t max_files,
    const std::string& pattern, spdlog::level::level_enum level) {
            
        auto rotating_file_sink = std::make_shared<spdlog::sinks::rotating_file_sink_mt> (filename, max_size, max_files);
        rotating_file_sink->set_pattern(pattern);
        rotating_file_sink->set_level(level);
        sinks_.push_back(rotating_file_sink);
        return *this;
}       
        
LoggerFactory& LoggerFactory::set_color(spdlog::level::level_enum level, int color) {
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
        
LoggerFactory& LoggerFactory::set_colors(int trace_color, int debug_color, int info_color, int warn_color,
    int error_color, int critical_color) {

        set_color(spdlog::level::trace, trace_color);
        set_color(spdlog::level::debug, debug_color);
        set_color(spdlog::level::info, info_color);
        set_color(spdlog::level::warn, warn_color);
        set_color(spdlog::level::err, error_color);
        set_color(spdlog::level::critical, critical_color);

        return *this;
}        

std::shared_ptr<spdlog::logger> LoggerFactory::build(const std::string& name, bool default_logger) {
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

//===========================================================================================
//===========================================================================================

// => class SpdLogger vvvv

SpdLogger::SpdLogger() : _logger(spdlog_internal::get_null_logger()) {}

SpdLogger::SpdLogger(std::shared_ptr<spdlog::logger> logger)
    : _logger(logger) {}



void SpdLogger::trace(const char* msg, ...) {
    va_list args;
    va_start (args, msg);
    std::string message= spdlog_internal::format_str(msg, args);
    va_end(args);
    _logger->trace(message);
}

void SpdLogger::trace(int color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg(spdlog::level::trace, color, msg, args);
    va_end(args); 
}

void SpdLogger::trace(int fg_color, int bg_color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::trace, fg_color, bg_color, -1, msg, args);
    va_end(args);            
}

void SpdLogger::trace(int fg_color, int bg_color, int effect, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::trace, fg_color, bg_color, effect, msg, args);
    va_end(args);            
}



void SpdLogger::debug(const char* msg, ...) {
    va_list args;
    va_start (args, msg);
    std::string message= spdlog_internal::format_str(msg, args);
    va_end(args);
    _logger->debug(message);
}

void SpdLogger::debug(int color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg(spdlog::level::debug, color, msg, args);
    va_end(args); 
}

void SpdLogger::debug(int fg_color, int bg_color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::debug, fg_color, bg_color, -1, msg, args);
    va_end(args);            
}

void SpdLogger::debug(int fg_color, int bg_color, int effect, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::debug, fg_color, bg_color, effect, msg, args);
    va_end(args);            
}



void SpdLogger::info(const char* msg, ...) {
    va_list args;
    va_start (args, msg);
    std::string message= spdlog_internal::format_str(msg, args);
    va_end(args);
    _logger->info(message);           
}

void SpdLogger::info(int color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg(spdlog::level::info, color, msg, args);
    va_end(args); 
}

void SpdLogger::info(int fg_color, int bg_color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::info, fg_color, bg_color, -1, msg, args);
    va_end(args);            
}

void SpdLogger::info(int fg_color, int bg_color, int effect, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::info, fg_color, bg_color, effect, msg, args);
    va_end(args);            
}



void SpdLogger::warn(const char* msg, ...) {
    va_list args;
    va_start (args, msg);
    std::string message= spdlog_internal::format_str(msg, args);
    va_end(args);
    _logger->warn(message);
}

void SpdLogger::warn(int color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg(spdlog::level::warn, color, msg, args);
    va_end(args); 
}

void SpdLogger::warn(int fg_color, int bg_color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::warn, fg_color, bg_color, -1, msg, args);
    va_end(args);            
}

void SpdLogger::warn(int fg_color, int bg_color, int effect, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::warn, fg_color, bg_color, effect, msg, args);
    va_end(args);            
}



void SpdLogger::error(const char* msg, ...) {
    va_list args;
    va_start (args, msg);
    std::string message= spdlog_internal::format_str(msg, args);
    va_end(args);
    _logger->error(message);
}

void SpdLogger::error(int color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg(spdlog::level::err, color, msg, args);
    va_end(args); 
}

void SpdLogger::error(int fg_color, int bg_color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::err, fg_color, bg_color, -1, msg, args);
    va_end(args);            
}

void SpdLogger::error(int fg_color, int bg_color, int effect, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::err, fg_color, bg_color, effect, msg, args);
    va_end(args);            
}



void SpdLogger::critical(const char* msg, ...) {
    va_list args;
    va_start (args, msg);
    std::string message= spdlog_internal::format_str(msg, args);
    va_end(args);
    _logger->critical(message);
}

void SpdLogger::critical(int color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg(spdlog::level::critical, color, msg, args);
    va_end(args);            
}

void SpdLogger::critical(int fg_color, int bg_color, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::critical, fg_color, bg_color, -1, msg, args);
    va_end(args);            
}

void SpdLogger::critical(int fg_color, int bg_color, int effect, const char* msg, ...) {
    va_list args;
    va_start(args, msg);
    color_msg_bg(spdlog::level::critical, fg_color, bg_color, effect, msg, args);
    va_end(args);            
}


void SpdLogger::color_msg(spdlog::level::level_enum level, int color, const char* msg, va_list args) {
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

void SpdLogger::color_msg_bg(spdlog::level::level_enum level, int fg_color, int effect, int bg_color, const char* msg, va_list args) {
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

//===========================================================================================
//===========================================================================================

