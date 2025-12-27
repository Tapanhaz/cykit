

cdef extern from *:
    """
    #ifdef _WIN32
        #include <windows.h>
        
        typedef struct {
            long tv_sec;
            long tv_nsec;
        } timespec_;
        
        inline int clock_gettime_(int clock_id, timespec_* ts) {
            static LARGE_INTEGER frequency = {0};
            LARGE_INTEGER counter;
            
            if (frequency.QuadPart == 0) {
                QueryPerformanceFrequency(&frequency);
            }
            
            QueryPerformanceCounter(&counter);
            
            ts->tv_sec = (long)(counter.QuadPart / frequency.QuadPart);
            ts->tv_nsec = (long)(((counter.QuadPart % frequency.QuadPart) * 1000000000LL) / frequency.QuadPart);
            
            return 0;
        }
        
        #define CLOCK_MONOTONIC_ 0

        inline void usleep_(unsigned int us) {
            HANDLE timer;
            LARGE_INTEGER ft;

            ft.QuadPart = -(10 * (LONGLONG)us); 
            timer = CreateWaitableTimer(NULL, TRUE, NULL);
            
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
        long tv_sec
        long tv_nsec
    
    int clock_gettime_(int clock_id, timespec_* ts) nogil
    void usleep_(unsigned int us) nogil
    
    cdef enum:
        CLOCK_MONOTONIC_