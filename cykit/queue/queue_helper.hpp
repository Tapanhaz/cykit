# pragma once


#include <cacheline.hpp>
#include <atomic_wait.hpp>

namespace cykit {
    struct alignas(CACHELINE) PublishEntry {
        std::atomic<uint64_t> seq;
        WaiterMetaBare<uint64_t> seq_wm;
    private:
        char _pad[CACHELINE - ((sizeof(std::atomic<uint64_t>) + sizeof(WaiterMetaBare<uint64_t>)) % CACHELINE)];
    };
} // namespace cykit