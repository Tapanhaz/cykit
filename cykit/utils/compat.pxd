from libc.stdint cimport uint64_t


cdef extern from *:
    """
    #ifdef _WIN32
        #include <windows.h>
        #include <stdint.h>

        typedef struct { int64_t tv_sec; int64_t tv_nsec; } timespec_;

        inline int clock_gettime_(int, timespec_* ts) noexcept {
            static LARGE_INTEGER frequency = {0};
            LARGE_INTEGER counter;
            if (!frequency.QuadPart)
                QueryPerformanceFrequency(&frequency);
            QueryPerformanceCounter(&counter);
            ts->tv_sec  = counter.QuadPart / frequency.QuadPart;
            ts->tv_nsec = (int64_t)(((counter.QuadPart % frequency.QuadPart) * 1000000000LL)
                                    / frequency.QuadPart);
            return 0;
        }

        #define CLOCK_MONOTONIC_ 0

        inline void usleep_(unsigned int us) noexcept {
            LARGE_INTEGER ft;
            ft.QuadPart = -(10LL * (LONGLONG)us);
            HANDLE timer = CreateWaitableTimer(NULL, TRUE, NULL);
            if (timer) {
                SetWaitableTimer(timer, &ft, 0, NULL, NULL, 0);
                WaitForSingleObject(timer, INFINITE);
                CloseHandle(timer);
            }
        }
    #else
        #include <unistd.h>
        #include <time.h>
        typedef struct timespec timespec_;
        #define clock_gettime_ clock_gettime
        #define CLOCK_MONOTONIC_ CLOCK_MONOTONIC
        #define usleep_ usleep
    #endif

    #if defined(_WIN32)
        static inline uint64_t now_ns(void) {
            static LARGE_INTEGER freq = {0};
            LARGE_INTEGER counter;
            if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
            QueryPerformanceCounter(&counter);
            uint64_t sec = (uint64_t)(counter.QuadPart / freq.QuadPart);
            uint64_t rem = (uint64_t)(counter.QuadPart % freq.QuadPart);
            return sec * 1000000000ULL + (rem * 1000000000ULL) / (uint64_t)freq.QuadPart;
        }
    #elif defined(__APPLE__)
        static inline uint64_t now_ns(void) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
            return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
        }
    #else
        static inline uint64_t now_ns(void) {
            struct timespec ts;
        #ifdef CLOCK_MONOTONIC_RAW
            clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
        #else
            clock_gettime(CLOCK_MONOTONIC, &ts);
        #endif
            return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
        }
    #endif
    """
    ctypedef struct timespec_:
        long long tv_sec
        long long tv_nsec

    int clock_gettime_(int clock_id, timespec_* ts) noexcept nogil
    void usleep_(unsigned int us) noexcept nogil

    uint64_t now_ns() noexcept nogil

    cdef enum:
        CLOCK_MONOTONIC_