"""
@file shared_memory.pxd
@brief Boost.Interprocess-backed shared memory / named semaphore wrappers.
@date 2026-07-14
@copyright Part of the https://github.com/Tapanhaz/cykit library.
"""

from libc.stdint cimport uint32_t, uint64_t


cdef extern from *:
    """
    #define MAGIC_INITIALIZED 0xDEADBEEF
    #define MAGIC_FINALIZING  0xFEEDFACE
    """
    cdef uint32_t MAGIC_INITIALIZED
    cdef uint32_t MAGIC_FINALIZING

cdef extern from "<boost/interprocess/sync/interprocess_mutex.hpp>" namespace "boost::interprocess":
    cdef cppclass interprocess_mutex:
        interprocess_mutex() except + nogil
        void lock() except + nogil
        void unlock() except + nogil
        bint try_lock() except + nogil

cdef extern from "<boost/interprocess/sync/interprocess_condition.hpp>" namespace "boost::interprocess":
    cdef cppclass interprocess_condition:
        interprocess_condition() except + nogil
        void notify_all() except + nogil
        void notify_one() except + nogil
        void wait(scoped_lock&) except + nogil

cdef extern from "<boost/interprocess/sync/scoped_lock.hpp>" namespace "boost::interprocess" nogil:
    cdef cppclass scoped_lock "boost::interprocess::scoped_lock<boost::interprocess::interprocess_mutex>":
        scoped_lock(interprocess_mutex&) except + nogil
        scoped_lock() except + nogil
        void lock() except + nogil
        void unlock() except + nogil
        bint owns() except + nogil
        interprocess_mutex* mutex() except + nogil


cdef extern from *:
    """
    #include <new>
    #include <atomic>
    #include <chrono>
    #include <boost/interprocess/sync/interprocess_mutex.hpp>
    #include <boost/interprocess/sync/interprocess_condition.hpp>

    extern "C" {
        size_t __sizeof_atomic_uint64() { return sizeof(std::atomic<uint64_t>); }
        size_t __sizeof_interprocess_mutex() { return sizeof(boost::interprocess::interprocess_mutex); }
        size_t __sizeof_interprocess_condition() { return sizeof(boost::interprocess::interprocess_condition); }
    }

    inline void init_interprocess_mutex(void* addr) {
        new (addr) boost::interprocess::interprocess_mutex();
    }

    inline void init_interprocess_condition(void* addr) {
        new (addr) boost::interprocess::interprocess_condition();
    }

    inline void init_atomic_uint32(void* addr, uint32_t v) {
        new (addr) std::atomic<uint32_t>(v);
    }

    inline void init_atomic_uint64(void* addr, uint64_t v) {
        new (addr) std::atomic<uint64_t>(v);
    }

    inline void cond_wait(boost::interprocess::interprocess_condition* cond,
                          boost::interprocess::scoped_lock<boost::interprocess::interprocess_mutex>* lock) {
        cond->wait(*lock);
    }

    inline void init_atomic_int(void* addr, int v) {
        new (addr) std::atomic<int>(v);
    }

    inline void init_atomic_bool(void* addr, bool v) {
        new (addr) std::atomic<bool>(v);
    }
    """
    size_t __sizeof_atomic_uint64()
    size_t __sizeof_interprocess_mutex()
    size_t __sizeof_interprocess_condition()
    void init_interprocess_mutex(void* addr) nogil
    void init_interprocess_condition(void* addr) nogil

    void init_atomic_uint32(void* addr, uint32_t v) nogil

    void init_atomic_uint64(void* addr, uint64_t v) nogil
    void cond_wait(interprocess_condition* cond, scoped_lock* lock) nogil

    void init_atomic_int(void* addr, int v) nogil
    void init_atomic_bool(void* addr, bint v) nogil
    

cdef extern from *:
    """
    #include <atomic>
    #include <memory>
    #include <string>
    #include <cstring>
    #include <stdexcept>
    #include <boost/interprocess/mapped_region.hpp>
    #include <boost/interprocess/shared_memory_object.hpp>
    #include <boost/interprocess/sync/named_semaphore.hpp>
    #include <boost/interprocess/sync/named_mutex.hpp>
    #include <boost/interprocess/sync/scoped_lock.hpp>

    #ifndef _WIN32
        #include <signal.h>
        #include <sys/types.h>
        #include <unistd.h>
        #include <errno.h>
    #else
        #include <windows.h>
    #endif

    #if defined(__cpp_lib_hardware_interference_size) && !defined(__APPLE__)
        static constexpr std::size_t SHM_CACHELINE = std::hardware_destructive_interference_size;
    #else
        #if (defined(__APPLE__) || defined(__arm__) || defined(__aarch64__) || defined(_M_ARM64))
            static constexpr std::size_t SHM_CACHELINE = 128;
        #else
            static constexpr std::size_t SHM_CACHELINE = 64;
        #endif
    #endif
        
    namespace bip = boost::interprocess;

    static uint32_t get_current_pid() {
    #ifdef _WIN32
        return (uint32_t)GetCurrentProcessId();
    #else
        return (uint32_t)getpid();
    #endif
    }

    #ifdef _WIN32
    static bool is_pid_alive(uint32_t pid) {
        if (pid == 0) return false;
        HANDLE h = OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!h) return false;
        DWORD code = 0;
        BOOL ok = GetExitCodeProcess(h, &code);
        CloseHandle(h);
        return ok && code == STILL_ACTIVE;
    }

    #else

    static bool is_pid_alive(uint32_t pid) {
        if (pid == 0) return false;
        int r = kill((pid_t)pid, 0);
        return (r == 0) || (errno == EPERM);
    }

    #endif
    
    struct SharedMemory {
        std::string name;
        std::unique_ptr<bip::shared_memory_object> shm_obj;
        std::unique_ptr<bip::mapped_region> region;
        bool is_creator_;
        
        struct SharedHeader {
            std::atomic<int> ref_count;
            std::atomic<int> mutex_ref_count;
            std::atomic<uint32_t> magic_number;
            std::atomic<uint32_t> init_complete;
            std::atomic<int> writer_count;
            std::atomic<int> reader_count;
            std::atomic<uint32_t> attach_count;
            enum { MAX_ATTACH = 128 };
            std::atomic<uint32_t> pids[MAX_ATTACH];
            char padding[SHM_CACHELINE - (
                sizeof(std::atomic<int>)*4 +
                sizeof(std::atomic<uint32_t>)*2
            ) % SHM_CACHELINE];
        };
        
        SharedHeader* header;

        static bool add_pid(SharedHeader* h, uint32_t pid) {
            for (size_t i = 0; i < SharedHeader::MAX_ATTACH; ++i) {
                uint32_t expected = 0;
                if (std::atomic_compare_exchange_strong(&h->pids[i], &expected, pid)) {
                    h->attach_count.fetch_add(1);
                    return true;
                }
            }
            return false;
        }

        static bool remove_pid(SharedHeader* h, uint32_t pid) {
            for (size_t i = 0; i < SharedHeader::MAX_ATTACH; ++i) {
                uint32_t expected = pid;
                if (h->pids[i].compare_exchange_strong(
                        expected, 0,
                        std::memory_order_acq_rel,
                        std::memory_order_acquire)) {
                    h->attach_count.fetch_sub(1);
                    return true;
                }
            }
            return false;
        }
        
        SharedMemory(const char* shm_name, size_t size) 
            : name(shm_name), is_creator_(false), header(nullptr) {
            
            size_t total_size = sizeof(SharedHeader) + size;
            std::string mutex_name = std::string(shm_name) + "_attmtx";

            bip::named_mutex attach_mutex(bip::open_or_create, mutex_name.c_str());
            bip::scoped_lock<bip::named_mutex> attach_lock(attach_mutex);

            bool created = false;
            
                try {
                    shm_obj = std::make_unique<bip::shared_memory_object>(
                        bip::open_only, shm_name, bip::read_write);
                    is_creator_ = false;

                } catch (const bip::interprocess_exception&) {
                    shm_obj = std::make_unique<bip::shared_memory_object>(
                        bip::create_only, shm_name, bip::read_write);
                    shm_obj->truncate(total_size);
                    is_creator_ = true;
                    created = true;
                }
            
            region = std::make_unique<bip::mapped_region>(*shm_obj, bip::read_write);
            header = static_cast<SharedHeader*>(region->get_address());
            
            if (created) {
                new (&header->ref_count) std::atomic<int>(1);
                new (&header->mutex_ref_count) std::atomic<int>(0);
                new (&header->magic_number) std::atomic<uint32_t>(0);
                new (&header->init_complete) std::atomic<uint32_t>(0);
                new (&header->writer_count) std::atomic<int>(0);
                new (&header->reader_count) std::atomic<int>(0);

                new (&header->attach_count) std::atomic<uint32_t>(0);
                for (size_t i = 0; i < SharedHeader::MAX_ATTACH; ++i) {
                    new (&header->pids[i]) std::atomic<uint32_t>(0);
                }

                std::memset(header->padding, 0, sizeof(header->padding));
                
            } else {
                int old_count = header->ref_count.fetch_add(1, std::memory_order_acq_rel);
                if (old_count <= 0) {
                    header->ref_count.fetch_sub(1, std::memory_order_acq_rel);
                    throw std::runtime_error("Shared memory ref_count <= 0 under attach mutex");
                
                }
            }

            if (!add_pid(header, get_current_pid())) {
                throw std::runtime_error("Too many processes attached to shared memory (MAX_ATTACH exceeded)");
            }
            header->mutex_ref_count.fetch_add(1, std::memory_order_acq_rel);
        }
        
        ~SharedMemory() {
            if (!header) return;

            std::string mutex_name = name + "_attmtx";
            bool removed_shm = false;
            try {                
                {
                    bip::named_mutex attach_mutex(bip::open_or_create, mutex_name.c_str());
                    bip::scoped_lock<bip::named_mutex> attach_lock(attach_mutex);

                    remove_pid(header, get_current_pid());

                    int remaining = header->ref_count.fetch_sub(
                        1, std::memory_order_acq_rel) - 1;

                    if (remaining == 0) {
                        try { bip::shared_memory_object::remove(name.c_str()); } catch (...) {}
                        removed_shm = true;
                    } else if (remaining < 0) {
                        fprintf(stderr,
                            "ERROR: Negative ref count (%d) in destructor!", remaining);
                    }

                    header->mutex_ref_count.fetch_sub(1, std::memory_order_acq_rel);

                }

            } catch (...) {}
            if (removed_shm) {
                try { bip::named_mutex::remove(mutex_name.c_str()); } catch (...) {}
            }
        }
        
        void* get_address() { 
            return static_cast<char*>(region->get_address()) + sizeof(SharedHeader); 
        }
        
        size_t get_size() { 
            return region->get_size() - sizeof(SharedHeader); 
        }
        
        bool is_creator() const { 
            return is_creator_; 
        }
        
        uint32_t get_magic() const {
            return header ? header->magic_number.load(std::memory_order_acquire) : 0;
        }
        
        void set_magic(uint32_t value) {
            if (header) {
                header->magic_number.store(value, std::memory_order_release);
            }
        }
        
        void mark_init_complete() {
            if (header) {
                header->init_complete.store(1, std::memory_order_release);
            }
        }
        
        bool is_init_complete() const {
            return header && header->init_complete.load(std::memory_order_acquire) == 1;
        }
        
        int get_ref_count() const {
            return header ? header->ref_count.load(std::memory_order_acquire) : 0;
        }

        bool has_other_live_attachers() const {
            if (!header) return false;
            uint32_t self_pid = get_current_pid();
            for (size_t i = 0; i < SharedHeader::MAX_ATTACH; ++i) {
                uint32_t pid = header->pids[i].load(std::memory_order_acquire);
                if (pid != 0 && pid != self_pid && is_pid_alive(pid)) {
                    return true;
                }
            }
            return false;
        }
        
        // SPMC :: 
        bool try_acquire_writer() {

            if (!header) return false;
            int expected = 0;
            return header->writer_count.compare_exchange_strong(
                expected, 1, std::memory_order_acq_rel
                );
        }
        
        void release_writer() {
            if (header) {
                header->writer_count.store(0, std::memory_order_release);
            }
        }
        
        // MPSC/MPMC ::
        int increment_writer_count() {
            if (!header) return 0;
            return header->writer_count.fetch_add(1, std::memory_order_acq_rel) + 1;
        }
        
        int decrement_writer_count() {
            if (!header) return 0;
            return header->writer_count.fetch_sub(1, std::memory_order_acq_rel) - 1;
        }
        
        int get_writer_count() const {
            return header ? header->writer_count.load(std::memory_order_acquire) : 0;
        }
        
        // MPSC :: 
        bool try_acquire_reader() {

            if (!header) return false;
            int expected = 0;
            return header->reader_count.compare_exchange_strong(
                expected, 1, std::memory_order_acq_rel
                );
        }
        
        void release_reader() {
            if (header) {
                header->reader_count.store(0, std::memory_order_release);
            }
        }
        
        // MPMC ::
        int increment_reader_count() {
            if (!header) return 0;
            return header->reader_count.fetch_add(1, std::memory_order_acq_rel) + 1;
        }
        
        int decrement_reader_count() {
            if (!header) return 0;
            return header->reader_count.fetch_sub(1, std::memory_order_acq_rel) - 1;
        }
        
        int get_reader_count() const {
            return header ? header->reader_count.load(std::memory_order_acquire) : 0;
        }
    };
    
    struct Semaphore {
        std::string name;
        std::unique_ptr<bip::named_semaphore> sem;
        
        struct SemRefCount {
            std::atomic<int> ref_count;
            char padding[SHM_CACHELINE - sizeof(std::atomic<int>)];
        };
        
        std::unique_ptr<bip::shared_memory_object> ref_shm_obj;
        std::unique_ptr<bip::mapped_region> ref_region;
        SemRefCount* ref_count_ptr;
        std::string ref_shm_name;
        bool is_creator_;
        
        Semaphore(const char* sem_name) 
            : name(sem_name), ref_count_ptr(nullptr), is_creator_(false) {
            
            ref_shm_name = std::string(sem_name) + "_refcount";
            std::string sem_mutex_name = std::string(sem_name) + "_semmtx";
            bip::named_mutex sem_mutex(bip::open_or_create, sem_mutex_name.c_str());
            bip::scoped_lock<bip::named_mutex> sem_lock(sem_mutex);
            
            bool created_refcount = false;
            
                try {
                    ref_shm_obj = std::make_unique<bip::shared_memory_object>(
                        bip::open_only, ref_shm_name.c_str(), bip::read_write);

                } catch (const bip::interprocess_exception&) {
                    try {
                        ref_shm_obj = std::make_unique<bip::shared_memory_object>(
                            bip::create_only, ref_shm_name.c_str(), bip::read_write);
                        ref_shm_obj->truncate(sizeof(SemRefCount));
                        created_refcount = true;
                    } catch (const bip::interprocess_exception&) {
                        ref_shm_obj = std::make_unique<bip::shared_memory_object>(
                            bip::open_only, ref_shm_name.c_str(), bip::read_write);
                    }
                }
            
            ref_region = std::make_unique<bip::mapped_region>(*ref_shm_obj, bip::read_write);
            ref_count_ptr = static_cast<SemRefCount*>(ref_region->get_address());
            
            if (created_refcount) {
                new (&ref_count_ptr->ref_count) std::atomic<int>(1);
                std::memset(ref_count_ptr->padding, 0, sizeof(ref_count_ptr->padding));
            } else {
                ref_count_ptr->ref_count.fetch_add(1, std::memory_order_acq_rel);
            }
            
            try {
                sem = std::make_unique<bip::named_semaphore>(
                    bip::open_only, sem_name);
                is_creator_ = false;
                    
            } catch (const bip::interprocess_exception&) {
                try {
                    sem = std::make_unique<bip::named_semaphore>(
                        bip::create_only, sem_name, 0);
                    is_creator_ = true;
                } catch (const bip::interprocess_exception&) {
                    sem = std::make_unique<bip::named_semaphore>(
                        bip::open_only, sem_name);
                    is_creator_ = false;
                }
            }
        }
        
        ~Semaphore() {
            if (!ref_count_ptr) return;
            
            int remaining = ref_count_ptr->ref_count.fetch_sub(1, std::memory_order_acq_rel) - 1;
            
            if (remaining == 0) {
                try {
                    bip::named_semaphore::remove(name.c_str());
                    bip::shared_memory_object::remove(ref_shm_name.c_str());
                    bip::named_mutex::remove((name + "_semmtx").c_str());
                } catch (...) {}
            }
        }
        
        void post() { 
            if (sem) sem->post(); 
        }
        
        void wait() { 
            if (sem) sem->wait(); 
        }
        
        bool try_wait() { 
            return sem ? sem->try_wait() : false; 
        }
        
        int get_ref_count() const {
            return ref_count_ptr ? ref_count_ptr->ref_count.load(std::memory_order_acquire) : 0;
        }
    };
    
    inline SharedMemory* create_shared_memory(
        const char* name, size_t size) {
        return new SharedMemory(name, size);
    }
    
    inline Semaphore* create_semaphore(const char* name) {
        return new Semaphore(name);
    }

    inline int cleanup_orphan_memory(const char* shm_name, const char* sem_name) {
        std::string sem_mutex_name = std::string(sem_name) + "_semmtx";
        bip::named_mutex sem_mutex(bip::open_or_create, sem_mutex_name.c_str());

        {
            bool shm_exists = false;
            bip::scoped_lock<bip::named_mutex> sem_lock(sem_mutex);
            try {
                bip::shared_memory_object sh(bip::open_only, shm_name, bip::read_write);
                shm_exists = true;
            } catch (...) {}

            if (!shm_exists) {
                try { bip::named_semaphore::remove(sem_name); } catch (...) {}
                try {
                    bip::shared_memory_object::remove(
                        (std::string(sem_name) + "_refcount").c_str());
                } catch (...) {}

                try { bip::named_mutex::remove(sem_mutex_name.c_str()); } catch (...) {}
            }
        }

        try {
            std::string mutex_name = std::string(shm_name) + "_attmtx";
            bip::named_mutex attach_mutex(bip::open_or_create, mutex_name.c_str());

            bool any_alive = false;
            {
                bip::scoped_lock<bip::named_mutex> attach_lock(attach_mutex);

                bip::shared_memory_object sh(bip::open_only, shm_name, bip::read_write);
                bip::mapped_region region(sh, bip::read_write);
                SharedMemory::SharedHeader* hdr = reinterpret_cast<SharedMemory::SharedHeader*>(region.get_address());
    
                for (size_t i = 0; i < SharedMemory::SharedHeader::MAX_ATTACH; ++i) {
                    uint32_t pid = hdr->pids[i].load(std::memory_order_acquire);
                    if (pid != 0 && is_pid_alive(pid)) {
                        any_alive = true;
                        break;
                    }
                }
            }


            if (!any_alive) {
                try { bip::shared_memory_object::remove(shm_name); } catch (...) {}
                try { bip::named_semaphore::remove(sem_name); } catch (...) {}
                try {
                    bip::shared_memory_object::remove(
                        (std::string(sem_name) + "_refcount").c_str());
                } catch (...) {}
                try { bip::named_mutex::remove(mutex_name.c_str()); } catch (...) {}
                return 1;
            }
        } catch (...) {}
        return 0;
    }
    """
    cppclass SharedMemory:
        void* get_address() nogil
        size_t get_size() nogil
        bint is_creator() nogil
        uint32_t get_magic() nogil
        void set_magic(uint32_t value) nogil
        void mark_init_complete() nogil
        bint is_init_complete() nogil
        int get_ref_count() nogil
        bint has_other_live_attachers() except + nogil
        
        # SPMC :: 
        bint try_acquire_writer() nogil
        void release_writer() nogil
        
        # MPSC/MPMC :: 
        int increment_writer_count() nogil
        int decrement_writer_count() nogil
        int get_writer_count() nogil
        
        # MPSC ::
        bint try_acquire_reader() nogil
        void release_reader() nogil
        
        # MPMC ::
        int increment_reader_count() nogil
        int decrement_reader_count() nogil
        int get_reader_count() nogil
    
    cppclass Semaphore:
        void post() nogil
        void wait() nogil
        bint try_wait() nogil
        int get_ref_count() nogil
    
    SharedMemory* create_shared_memory(const char* name, size_t size) except+ nogil
    Semaphore* create_semaphore(const char* name) except+ nogil

    int cleanup_orphan_memory(const char* shm_name, const char* sem_name) nogil
    

