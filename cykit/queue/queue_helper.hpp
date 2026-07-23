# pragma once


#include <cacheline.hpp>
#include <atomic_wait.hpp>
#include <Python.h>

namespace cykit {
    struct alignas(CACHELINE) PublishEntry {
        std::atomic<uint64_t> seq;
        WaiterMetaBare<uint64_t> seq_wm;
    private:
        char _pad[CACHELINE - ((sizeof(std::atomic<uint64_t>) + sizeof(WaiterMetaBare<uint64_t>)) % CACHELINE)];
    };

    struct alignas(CACHELINE) PyQueueSlot {
            PyObject*    obj;    
            uint32_t seq_id;
            uint16_t chunk_idx;
            uint16_t total_chunks;
        private:
            char _pad[CACHELINE - (sizeof(void*) + sizeof(uint32_t) + sizeof(uint16_t) + sizeof(uint16_t)) % CACHELINE];
        };
} // namespace cykit