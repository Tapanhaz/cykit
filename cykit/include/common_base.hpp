#pragma once

//  common.pxd

#include <cstdint>
#include <new>
#include <thread>

#if defined(_WIN32)
    #include <windows.h>
#elif defined(__APPLE__)
    #include <pthread.h>
    #include <mach/thread_act.h>
    #include <mach/thread_policy.h>
#elif defined(__linux__)
    #include <pthread.h>
    #include <sched.h>
#endif

#if defined(_WIN32)
    #include <malloc.h>
#else
    #include <stdlib.h>
#endif

#if defined(_MSC_VER) && (defined(_M_IX86) || defined(_M_X64))
    #include <immintrin.h>
#elif defined(__i386__) || defined(__x86_64__)
    #include <immintrin.h>
#elif defined(_MSC_VER) && defined(_M_ARM64)
    #include <intrin.h>
#endif

namespace cykit {

//thread ========================================================================

inline bool set_thread_affinity(std::thread& t, int core_id) noexcept {
#if defined(_WIN32)
    DWORD_PTR mask = (DWORD_PTR)1 << core_id;
    return SetThreadAffinityMask((HANDLE)t.native_handle(), mask) != 0;
#elif defined(__APPLE__)
    thread_port_t mt = pthread_mach_thread_np(t.native_handle());
    thread_affinity_policy_data_t policy = { core_id };
    return thread_policy_set(mt, THREAD_AFFINITY_POLICY,
              (thread_policy_t)&policy, THREAD_AFFINITY_POLICY_COUNT) == KERN_SUCCESS;
#elif defined(__linux__)
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    return pthread_setaffinity_np(t.native_handle(), sizeof(cpu_set_t), &cpuset) == 0;
#else
    (void)t; (void)core_id;
    return false;
#endif
}

inline unsigned int hw_concurrency() noexcept {
    return std::thread::hardware_concurrency();
}

template <typename F, typename A>
inline std::thread make_thread(F f, A a) {
    return std::thread(f, a);
}

// spin wait ==================================================================

inline void cpu_pause() noexcept {
#if defined(_MSC_VER) && (defined(_M_IX86) || defined(_M_X64))
    _mm_pause();
#elif defined(__i386__) || defined(__x86_64__)
    __builtin_ia32_pause();
#elif defined(_MSC_VER) && defined(_M_ARM64)
    __yield();
#elif defined(__aarch64__) || defined(__arm__) || defined(__arm64__)
    __asm__ __volatile__("yield" ::: "memory");
#else
    __asm__ __volatile__("" ::: "memory");
#endif
}

//  bit ops ===================================================================

inline int builtin_ctzll(unsigned long long x) noexcept {
#ifdef _MSC_VER
    unsigned long index;
    _BitScanForward64(&index, x);
    return (int)index;
#else
    return __builtin_ctzll(x);
#endif
}

// placement construct / destroy ==============================================

template <typename T>
inline void placement_new(void* p) noexcept {
    new (p) T();
}

template <typename T>
inline void placement_destroy(void* p) noexcept {
    static_cast<T*>(p)->~T();
}

// ==========================================================================

inline void* aligned_alloc_(size_t alignment, size_t size) noexcept {
    #if defined(_WIN32)
        return _aligned_malloc(size, alignment);
    #else
        return aligned_alloc(alignment, size);
    #endif
}
    
inline void aligned_free_(void* ptr) noexcept {
    #if defined(_WIN32)
        _aligned_free(ptr);
    #else
        ::free(ptr);
    #endif
}

} // namespace cykit
