/**
 * @file atomic_wait.hpp
 * @brief Direct-park wait/notify primitives for intra-process synchronization.
 * @date 2026-07-12
 * @copyright Part of the https://github.com/Tapanhaz/cykit library.
 *
 * @details
 * [[Experimental]] Standard library implementations of C++20 `std::atomic_wait` typically
 * perform a bounded userspace spin before parking the thread on the underlying
 * kernel synchronization primitive. Under sustained contention, that spin
 * becomes unnecessary CPU overhead. This header provides platform-specific
 * wait/notify primitives that park immediately, avoiding the extra spin while
 * preserving the semantics required for efficient intra-process synchronization.
 *
 * @see https://developers.redhat.com/articles/2022/12/06/implementing-c20-atomic-waiting-libstdc#:~:text=The%20spin%20loop%20itself%20performs%20the%20following%20steps
 */


#pragma once

#include <bit>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <concepts>
#include <type_traits>
#include "cacheline.hpp"

#if defined(__linux__)
    #include <linux/futex.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    #include <cerrno>
    #include <climits>
#elif defined(_WIN32)
    #ifndef WIN32_LEAN_AND_MEAN
        #define WIN32_LEAN_AND_MEAN
    #endif
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <windows.h>
#elif defined(__APPLE__)
    #include <dlfcn.h>
#else
    #error "cykit::atomic_wait: unsupported platform (expected Linux, Windows, or Mac)"
#endif

static_assert(std::endian::native == std::endian::little,
        "cykit atomic_wait.hpp assumes a little-endian target throughout "
        "(true for all Windows/macOS/Linux x86_64 and aarch64 targets "
        "this library ships on). The Linux 64-bit futex strategy in "
        "particular relies on this for its low-32-bits addressing -- "
        "porting to a big-endian target requires revisiting that section."
    );

namespace cykit {

namespace detail {

template <typename T>
inline constexpr bool is_wait_word_v =
    std::is_integral_v<T> && (sizeof(T) == 4 || sizeof(T) == 8);

#define CYKIT_ASSERT_WAIT_WORD(T) \
    static_assert(::cykit::detail::is_wait_word_v<T>, \
                  "cykit::atomic_wait/notify requires a 4-byte or 8-byte integral atomic word")

} // namespace detail


// Dedicated wait/notify bookkeeping for exactly one caller-owned atomic field.

template <typename T>
struct alignas(CACHELINE) WaiterMetaPadded {
    std::atomic<T>        last_notified{};
    std::atomic<uint64_t> last_epoch{0};
    std::atomic<uint64_t> waiter_epoch{0};
    std::atomic<uint32_t> count{0};
    std::atomic<bool>     has_last{false};
private:
    char _pad[CACHELINE - (
                sizeof(std::atomic<T>) +
                sizeof(std::atomic<uint64_t>) * 2 +
                sizeof(std::atomic<uint32_t>) +
                sizeof(std::atomic<bool>)
            )];
};

// Same shape, no epoch dedup

template <typename T>
struct alignas(CACHELINE) WaiterMetaPaddedBare {
    std::atomic<uint32_t> count{0};
private:
    char _pad[CACHELINE - sizeof(std::atomic<uint32_t>)];
};

// Same bookkeeping but without padding. Use for high-cardinality per-element fields.

template <typename T>
struct WaiterMeta {
    std::atomic<T>        last_notified{};
    std::atomic<uint64_t> last_epoch{0};
    std::atomic<uint64_t> waiter_epoch{0};
    std::atomic<uint32_t> count{0};
    std::atomic<bool>     has_last{false};
};


template <typename T>
struct WaiterMetaBare {
    std::atomic<uint32_t> count{0};
};

template <typename T>
concept HasEpochDedup = requires(T m) {
    m.waiter_epoch;
    m.last_epoch;
    m.last_notified;
    m.has_last;
};


// ============================================================================
// Linux
// ============================================================================
#if defined(__linux__)

namespace detail {

// Valid on little-endian only.
inline uint32_t* low32_ptr(void* addr) noexcept {
    return reinterpret_cast<uint32_t*>(addr);
}

} // namespace detail

template <typename T>
inline void atomic_wait(std::atomic<T>* obj, T expected) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);

    if constexpr (sizeof(T) == 4) {
        for (;;) {
            long rc = syscall(SYS_futex, obj, FUTEX_WAIT_PRIVATE,
                               static_cast<uint32_t>(expected),
                               nullptr, nullptr, 0);
            if (rc == 0)          return;   
            if (errno == EAGAIN)  return;   
            if (errno == EINTR)   continue; 
            return;                         
        }
    } else { 
        T current = obj->load(std::memory_order_seq_cst);
        if (current != expected) return;

        uint32_t* sig = detail::low32_ptr(obj);
        uint32_t  sig_snapshot = static_cast<uint32_t>(current);

        long rc = syscall(SYS_futex, sig, FUTEX_WAIT_PRIVATE,
                           sig_snapshot, nullptr, nullptr, 0);
        (void)rc; 
                  
    }
}

template <typename T, typename Meta>
inline void atomic_wait(std::atomic<T>* obj, T expected, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);

    if constexpr (HasEpochDedup<Meta>) {
        meta->waiter_epoch.fetch_add(1, std::memory_order_relaxed);
    }

    meta->count.fetch_add(1, std::memory_order_release);

    if constexpr (sizeof(T) == 4) {
        for (;;) {
            long rc = syscall(SYS_futex, obj, FUTEX_WAIT_PRIVATE,
                               static_cast<uint32_t>(expected),
                               nullptr, nullptr, 0);
            if (rc == 0)         break;
            if (errno == EAGAIN) break;
            if (errno == EINTR)  continue;
            break;
        }
    } else {
        T current = obj->load(std::memory_order_seq_cst);
        if (current == expected) {
            uint32_t* sig = detail::low32_ptr(obj);
            uint32_t  sig_snapshot = static_cast<uint32_t>(current);
            syscall(SYS_futex, sig, FUTEX_WAIT_PRIVATE, sig_snapshot, nullptr, nullptr, 0);
        }
    }

    meta->count.fetch_sub(1, std::memory_order_relaxed);
}

template <typename T>
inline void atomic_notify_one(std::atomic<T>* obj) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if constexpr (sizeof(T) == 4) {
        syscall(SYS_futex, obj, FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
    } else {
        syscall(SYS_futex, detail::low32_ptr(obj), FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
    }
}

template <typename T, typename Meta>
inline void atomic_notify_one(std::atomic<T>* obj, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (meta->count.load(std::memory_order_acquire) == 0) return;

    if constexpr (HasEpochDedup<Meta>) {
        uint64_t epoch = meta->waiter_epoch.load(std::memory_order_relaxed);
        T cur = obj->load(std::memory_order_relaxed);
        if (meta->has_last.load(std::memory_order_relaxed) &&
            meta->last_notified.load(std::memory_order_relaxed) == cur &&
            meta->last_epoch.load(std::memory_order_relaxed) == epoch) {
            return;
        }
        meta->last_notified.store(cur, std::memory_order_relaxed);
        meta->last_epoch.store(epoch, std::memory_order_relaxed);
        meta->has_last.store(true, std::memory_order_relaxed);
    }

    if constexpr (sizeof(T) == 4) {
        syscall(SYS_futex, obj, FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
    } else {
        syscall(SYS_futex, detail::low32_ptr(obj), FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
    }
}

template <typename T>
inline void atomic_notify_all(std::atomic<T>* obj) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if constexpr (sizeof(T) == 4) {
        syscall(SYS_futex, obj, FUTEX_WAKE_PRIVATE, INT_MAX, nullptr, nullptr, 0);
    } else {
        syscall(SYS_futex, detail::low32_ptr(obj), FUTEX_WAKE_PRIVATE, INT_MAX, nullptr, nullptr, 0);
    }
}

template <typename T, typename Meta>
inline void atomic_notify_all(std::atomic<T>* obj, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (meta->count.load(std::memory_order_acquire) == 0) return;

    if constexpr (HasEpochDedup<Meta>) {
        uint64_t epoch = meta->waiter_epoch.load(std::memory_order_relaxed);
        T cur = obj->load(std::memory_order_relaxed);
        if (meta->has_last.load(std::memory_order_relaxed) &&
            meta->last_notified.load(std::memory_order_relaxed) == cur &&
            meta->last_epoch.load(std::memory_order_relaxed) == epoch) {
            return;
        }
        meta->last_notified.store(cur, std::memory_order_relaxed);
        meta->last_epoch.store(epoch, std::memory_order_relaxed);
        meta->has_last.store(true, std::memory_order_relaxed);
    }

    if constexpr (sizeof(T) == 4) {
        syscall(SYS_futex, obj, FUTEX_WAKE_PRIVATE, INT_MAX, nullptr, nullptr, 0);
    } else {
        syscall(SYS_futex, detail::low32_ptr(obj), FUTEX_WAKE_PRIVATE, INT_MAX, nullptr, nullptr, 0);
    }
}

// ============================================================================
// Windows
// ============================================================================
#elif defined(_WIN32)

namespace detail {

struct win_wait_fns {
    using wait_fn_t     = BOOL(WINAPI*)(volatile VOID*, PVOID, SIZE_T, DWORD);
    using wake_one_fn_t = VOID(WINAPI*)(PVOID);
    using wake_all_fn_t = VOID(WINAPI*)(PVOID);

    wait_fn_t     wait     = nullptr;
    wake_one_fn_t wake_one = nullptr;
    wake_all_fn_t wake_all = nullptr;

    win_wait_fns() noexcept {
        HMODULE h = GetModuleHandleW(L"kernelbase.dll");
        if (!h) {
            h = LoadLibraryW(L"api-ms-win-core-synch-l1-2-0.dll");
        }
        if (h) {
            wait     = reinterpret_cast<wait_fn_t>(GetProcAddress(h, "WaitOnAddress"));
            wake_one = reinterpret_cast<wake_one_fn_t>(GetProcAddress(h, "WakeByAddressSingle"));
            wake_all = reinterpret_cast<wake_all_fn_t>(GetProcAddress(h, "WakeByAddressAll"));
        }
    }
};

inline const win_wait_fns& win_sync() noexcept {
    static const win_wait_fns fns; 
    return fns;
}

} // namespace detail

template <typename T>
inline void atomic_wait(std::atomic<T>* obj, T expected) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (auto fn = detail::win_sync().wait) {
        T exp = expected;
        fn(obj, &exp, sizeof(exp), INFINITE);
        return;
    }
    obj->wait(expected); // < Win8 fallback
}

template <typename T, typename Meta>
inline void atomic_wait(std::atomic<T>* obj, T expected, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);

    if constexpr (HasEpochDedup<Meta>) {
        meta->waiter_epoch.fetch_add(1, std::memory_order_relaxed);
    }

    meta->count.fetch_add(1, std::memory_order_release);
    if (auto fn = detail::win_sync().wait) {
        T exp = expected;
        fn(obj, &exp, sizeof(exp), INFINITE);
    } else {
        obj->wait(expected);
    }
    meta->count.fetch_sub(1, std::memory_order_relaxed);
}

template <typename T>
inline void atomic_notify_one(std::atomic<T>* obj) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (auto fn = detail::win_sync().wake_one) { fn(obj); return; }
    obj->notify_one();
}

template <typename T, typename Meta>
inline void atomic_notify_one(std::atomic<T>* obj, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (meta->count.load(std::memory_order_acquire) == 0) return;

    if constexpr (HasEpochDedup<Meta>) {
        uint64_t epoch = meta->waiter_epoch.load(std::memory_order_relaxed);
        T cur = obj->load(std::memory_order_relaxed);
        if (meta->has_last.load(std::memory_order_relaxed) &&
            meta->last_notified.load(std::memory_order_relaxed) == cur &&
            meta->last_epoch.load(std::memory_order_relaxed) == epoch) {
            return;
        }
        meta->last_notified.store(cur, std::memory_order_relaxed);
        meta->last_epoch.store(epoch, std::memory_order_relaxed);
        meta->has_last.store(true, std::memory_order_relaxed);
    }

    if (auto fn = detail::win_sync().wake_one) { fn(obj); return; }
    obj->notify_one();
}

template <typename T>
inline void atomic_notify_all(std::atomic<T>* obj) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (auto fn = detail::win_sync().wake_all) { fn(obj); return; }
    obj->notify_all();
}

template <typename T, typename Meta>
inline void atomic_notify_all(std::atomic<T>* obj, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (meta->count.load(std::memory_order_acquire) == 0) return;

    if constexpr (HasEpochDedup<Meta>) {
        uint64_t epoch = meta->waiter_epoch.load(std::memory_order_relaxed);
        T cur = obj->load(std::memory_order_relaxed);
        if (meta->has_last.load(std::memory_order_relaxed) &&
            meta->last_notified.load(std::memory_order_relaxed) == cur &&
            meta->last_epoch.load(std::memory_order_relaxed) == epoch) {
            return;
        }
        meta->last_notified.store(cur, std::memory_order_relaxed);
        meta->last_epoch.store(epoch, std::memory_order_relaxed);
        meta->has_last.store(true, std::memory_order_relaxed);
    }

    if (auto fn = detail::win_sync().wake_all) { fn(obj); return; }
    obj->notify_all();
}

// ============================================================================
// macOS
// ============================================================================
#elif defined(__APPLE__)

namespace detail {

struct apple_sync_fns {
    using wait_fn_t     = int(*)(void*, uint64_t, size_t, uint32_t);
    using wake_one_fn_t = int(*)(void*, size_t, uint32_t);
    using wake_all_fn_t = int(*)(void*, size_t, uint32_t);

    wait_fn_t     wait     = nullptr;
    wake_one_fn_t wake_one = nullptr;
    wake_all_fn_t wake_all = nullptr;

    apple_sync_fns() noexcept {
        wait     = reinterpret_cast<wait_fn_t>(dlsym(RTLD_DEFAULT, "os_sync_wait_on_address"));
        wake_one = reinterpret_cast<wake_one_fn_t>(dlsym(RTLD_DEFAULT, "os_sync_wake_by_address_any"));
        wake_all = reinterpret_cast<wake_all_fn_t>(dlsym(RTLD_DEFAULT, "os_sync_wake_by_address_all"));
    }
};

inline const apple_sync_fns& apple_sync() noexcept {
    static const apple_sync_fns fns;
    return fns;
}

inline constexpr uint32_t apple_sync_flags_none = 0;

} // namespace detail

template <typename T>
inline void atomic_wait(std::atomic<T>* obj, T expected) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (auto fn = detail::apple_sync().wait) {
        fn(obj, static_cast<uint64_t>(expected), sizeof(T), detail::apple_sync_flags_none);
        return;
    }
    obj->wait(expected); // macOS < 14.4 fallback.
}

template <typename T, typename Meta>
inline void atomic_wait(std::atomic<T>* obj, T expected, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);

    if constexpr (HasEpochDedup<Meta>) {
        meta->waiter_epoch.fetch_add(1, std::memory_order_relaxed);
    }

    meta->count.fetch_add(1, std::memory_order_release);
    if (auto fn = detail::apple_sync().wait) {
        fn(obj, static_cast<uint64_t>(expected), sizeof(T), detail::apple_sync_flags_none);
    } else {
        obj->wait(expected);
    }
    meta->count.fetch_sub(1, std::memory_order_relaxed);
}

template <typename T>
inline void atomic_notify_one(std::atomic<T>* obj) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (auto fn = detail::apple_sync().wake_one) {
        fn(obj, sizeof(T), detail::apple_sync_flags_none);
        return;
    }
    obj->notify_one();
}

template <typename T, typename Meta>
inline void atomic_notify_one(std::atomic<T>* obj, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (meta->count.load(std::memory_order_acquire) == 0) return;

    if constexpr (HasEpochDedup<Meta>) {
        uint64_t epoch = meta->waiter_epoch.load(std::memory_order_relaxed);
        T cur = obj->load(std::memory_order_relaxed);
        if (meta->has_last.load(std::memory_order_relaxed) &&
            meta->last_notified.load(std::memory_order_relaxed) == cur &&
            meta->last_epoch.load(std::memory_order_relaxed) == epoch) {
            return;
        }
        meta->last_notified.store(cur, std::memory_order_relaxed);
        meta->last_epoch.store(epoch, std::memory_order_relaxed);
        meta->has_last.store(true, std::memory_order_relaxed);
    }

    if (auto fn = detail::apple_sync().wake_one) {
        fn(obj, sizeof(T), detail::apple_sync_flags_none);
        return;
    }
    obj->notify_one();
}

template <typename T>
inline void atomic_notify_all(std::atomic<T>* obj) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (auto fn = detail::apple_sync().wake_all) {
        fn(obj, sizeof(T), detail::apple_sync_flags_none);
        return;
    }
    obj->notify_all();
}

template <typename T, typename Meta>
inline void atomic_notify_all(std::atomic<T>* obj, Meta* meta) noexcept {
    CYKIT_ASSERT_WAIT_WORD(T);
    if (meta->count.load(std::memory_order_acquire) == 0) return;

    if constexpr (HasEpochDedup<Meta>) {
        uint64_t epoch = meta->waiter_epoch.load(std::memory_order_relaxed);
        T cur = obj->load(std::memory_order_relaxed);
        if (meta->has_last.load(std::memory_order_relaxed) &&
            meta->last_notified.load(std::memory_order_relaxed) == cur &&
            meta->last_epoch.load(std::memory_order_relaxed) == epoch) {
            return;
        }
        meta->last_notified.store(cur, std::memory_order_relaxed);
        meta->last_epoch.store(epoch, std::memory_order_relaxed);
        meta->has_last.store(true, std::memory_order_relaxed);
    }

    if (auto fn = detail::apple_sync().wake_all) {
        fn(obj, sizeof(T), detail::apple_sync_flags_none);
        return;
    }
    obj->notify_all();
}

#endif

#undef CYKIT_ASSERT_WAIT_WORD

} // namespace cykit


