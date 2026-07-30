cdef extern from *:
    r"""
    #include <cstdarg>
    #include <cstdio>
    #include <string>
    #include <stdexcept>

    namespace cykit_exception {

    inline std::string format_str(const char* fmt, va_list args) {
        va_list args_copy;
        va_copy(args_copy, args);
        int needed = std::vsnprintf(nullptr, 0, fmt, args_copy);
        va_end(args_copy);
        if (needed < 0) return std::string(fmt);

        std::string result(static_cast<size_t>(needed), '\0');
        std::vsnprintf(&result[0], needed + 1, fmt, args);
        return result;
    }

    }  // namespace cykit_exception

    #define DEFINE_THROWER(name, exc_type)                          \
        [[noreturn]] inline void name(const char* fmt, ...) {             \
            va_list args;                                                 \
            va_start(args, fmt);                                          \
            std::string msg = cykit_exception::format_str(fmt, args);           \
            va_end(args);                                                 \
            throw exc_type(msg);                                          \
        }

    DEFINE_THROWER(throw_invalid_argument, std::invalid_argument)
    DEFINE_THROWER(throw_runtime_error,    std::runtime_error)
    DEFINE_THROWER(throw_logic_error,      std::logic_error)
    DEFINE_THROWER(throw_out_of_range,     std::out_of_range)
    DEFINE_THROWER(throw_overflow_error,   std::overflow_error)
    DEFINE_THROWER(throw_underflow_error,  std::underflow_error)
    DEFINE_THROWER(throw_length_error,     std::length_error)
    """
    void throw_invalid_argument(const char* fmt, ...) except + nogil
    void throw_runtime_error(const char* fmt, ...) except + nogil
    void throw_logic_error(const char* fmt, ...) except + nogil
    void throw_out_of_range(const char* fmt, ...) except + nogil
    void throw_overflow_error(const char* fmt, ...) except + nogil
    void throw_underflow_error(const char* fmt, ...) except + nogil
    void throw_length_error(const char* fmt, ...) except + nogil