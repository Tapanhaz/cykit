
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
    """
    ctypedef struct timespec_:
        long long tv_sec
        long long tv_nsec

    int clock_gettime_(int clock_id, timespec_* ts) noexcept nogil
    void usleep_(unsigned int us) noexcept nogil

    cdef enum:
        CLOCK_MONOTONIC_