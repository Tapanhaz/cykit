
/**
 * @file cacheline.hpp
 * @brief Cacheline-sizing utility.
 * @date 2026-07-12
 * @copyright Part of the https://github.com/Tapanhaz/cykit library.
 *
 * @details
 * Provides a portable cache line size constant along with helper types for
 * cache line alignment and padding. These utilities are intended to reduce
 * false sharing by ensuring frequently modified objects occupy separate cache lines. 
 */

#pragma once

#include <new>
#include <atomic>
#include <cstddef>
#include <cstdint>

#if defined(__GNUC__) || defined(__clang__)
#  pragma GCC diagnostic push
//#  pragma GCC diagnostic ignored "-Winterference-size"
#  if defined(__clang__)
#    if __has_warning("-Winterference-size")
#      pragma GCC diagnostic ignored "-Winterference-size"
#    endif
#  elif defined(__GNUC__) && (__GNUC__ >= 9)
#    pragma GCC diagnostic ignored "-Winterference-size"
#  endif

#endif


namespace cykit {

#if defined(__cpp_lib_hardware_interference_size) && !defined(__APPLE__)
inline constexpr std::size_t CACHELINE = std::hardware_destructive_interference_size;
#else
#  if defined(__APPLE__) && (defined(__arm__) || defined(__aarch64__))
inline constexpr std::size_t CACHELINE = 128;
#  elif defined(__arm__) || defined(__aarch64__) || defined(_M_ARM64)
inline constexpr std::size_t CACHELINE = 128;
#  else
inline constexpr std::size_t CACHELINE = 64;
#  endif
#endif

struct alignas(CACHELINE) CachelineBoundary {};

template <typename T>
struct alignas(CACHELINE) CachelinePadded {
    T value;
private:
    static constexpr std::size_t raw_mod  = sizeof(T) % CACHELINE;
    static constexpr std::size_t pad_size = (raw_mod == 0) ? 0 : (CACHELINE - raw_mod);
    char _pad[pad_size == 0 ? 1 : pad_size];
};

struct alignas(CACHELINE) PaddedAtomicU64 : CachelinePadded<std::atomic<uint64_t>> {};

} // namespace cykit

#if defined(__GNUC__) || defined(__clang__)
#  pragma GCC diagnostic pop
#endif
