#pragma once

#include <atomic>
#include <cstdint>
#include <cacheline.hpp>
#include <atomic_wait.hpp>
#include <Python.h>

namespace cykit {

    struct alignas(CACHELINE) PublishEntry {
        std::atomic<uint64_t> seq;
        WaiterMetaBare<uint64_t> seq_wm;
    };
    static_assert(sizeof(PublishEntry) % CACHELINE == 0,
                  "PublishEntry must be a whole number of cache lines to avoid false sharing");
    static_assert(sizeof(PublishEntry) == CACHELINE,
                  "PublishEntry grew past one cache line — check seq_wm size");

    struct alignas(CACHELINE) PyQueueSlot {
        PyObject* obj;
        uint32_t  seq_id;
        uint16_t  chunk_idx;
        uint16_t  total_chunks;
    };
    static_assert(sizeof(PyQueueSlot) % CACHELINE == 0,
                  "PyQueueSlot must be a whole number of cache lines to avoid false sharing");
    static_assert(sizeof(PyQueueSlot) == CACHELINE,
                  "PyQueueSlot grew past one cache line — check field layout");

} // namespace cykit