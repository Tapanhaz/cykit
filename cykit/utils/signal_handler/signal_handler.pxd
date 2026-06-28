
cdef extern from *:
    """
    #include <boost/asio.hpp>
    #include <boost/system/error_code.hpp>
    #include <thread>
    #include <atomic>
    #include <vector>
    #include <mutex>
    #include <Python.h>
    #include <spdlog_logger.hpp>
    
    typedef void (*context_notify_fn)(void* ctx);
    
    struct RegisteredContext {
        void* context_ptr;             
        std::atomic<int>* running_flag;             
        context_notify_fn notify_fn;   
    };
   
    inline std::vector<RegisteredContext>& g_registered_contexts() {
        static std::vector<RegisteredContext> v;
        return v;
    }

    inline std::mutex& g_registry_mutex() {
        static std::mutex m;
        return m;
    }

    inline std::atomic<int>& g_signal_received() {
        static std::atomic<int> a{0};
        return a;
    }
    inline std::atomic<bool>& g_io_context_stopped() {
        static std::atomic<bool> a{false};
        return a;
    }

    inline boost::asio::io_context*& g_io_context() {
        static boost::asio::io_context* p = nullptr;
        return p;
    }

    inline std::atomic<int>& g_handler_refcount() {
        static std::atomic<int> a{0};
        return a;
    }

    inline std::atomic<bool>& g_init_started() {
        static std::atomic<bool> a{false};
        return a;
    }

    inline std::atomic<bool>& g_init_ok() {
        static std::atomic<bool> a{false};
        return a;
    }

    inline std::thread& g_signal_thread() {
        static std::thread t;
        return t;
    }

    static int _set_interrupt(void*) {
        PyErr_SetInterrupt();
        return 0;
    }

    #ifdef _WIN32
    inline BOOL _ctrl_handler_impl(DWORD dwCtrlType) {
        if (dwCtrlType == CTRL_CLOSE_EVENT) {
            g_signal_received().store(1, std::memory_order_release);

        std::vector<RegisteredContext> snapshot;
        {
            std::lock_guard<std::mutex> lock(g_registry_mutex());
            snapshot = g_registered_contexts();
        }
        for (auto& ctx : snapshot) {
            if (ctx.running_flag)
                ctx.running_flag->store(0, std::memory_order_release);
            if (ctx.notify_fn && ctx.context_ptr) ctx.notify_fn(ctx.context_ptr);
        }

            Py_AddPendingCall(_set_interrupt, nullptr);

            bool expected = false;
            if (g_io_context_stopped().compare_exchange_strong(
                    expected, true,
                    std::memory_order::acq_rel,
                    std::memory_order::acquire)) {
                if (g_io_context()) g_io_context()->stop();
            }
            return TRUE;
        }
        return FALSE;
    }

    static BOOL WINAPI ConsoleCtrlHandler(DWORD dwCtrlType) {
         return _ctrl_handler_impl(dwCtrlType);
    }
    #endif
    
    class SignalHandler {
    private:
        boost::asio::io_context& io;
        boost::asio::signal_set signals;
        
        void handle_signal(const boost::system::error_code& error, int signal_number) {
            if (!error) {
                INFO("[SIGNAL] Received signal %d\\n", signal_number);
                g_signal_received().store(1, std::memory_order_release);
                
                std::vector<RegisteredContext> snapshot;
                {
                    std::lock_guard<std::mutex> lock(g_registry_mutex());
                    snapshot = g_registered_contexts();
                }
    
                INFO("[SIGNAL] Stopping %zu contexts...\\n", snapshot.size());
    
                for (auto& ctx : snapshot) {
                    if (ctx.running_flag)
                        ctx.running_flag->store(0, std::memory_order_release);
                    if (ctx.notify_fn && ctx.context_ptr) ctx.notify_fn(ctx.context_ptr);
                }
                
                DEBUG("[SIGNAL] All contexts notified\\n");

                bool expected = false;
                if (g_io_context_stopped().compare_exchange_strong(
                        expected, true,
                        std::memory_order::acq_rel,
                        std::memory_order::acquire)) {
                        io.stop();
                    }
                
                Py_AddPendingCall(_set_interrupt, nullptr);
            }
        }
        
    public:
        SignalHandler(boost::asio::io_context& io_)
            : io(io_), signals(io_) {
            
            signals.add(SIGINT);
            signals.add(SIGTERM);
            
            #ifndef _WIN32
            signals.add(SIGHUP);
            signals.add(SIGTSTP);
            signals.add(SIGQUIT);
            #endif
            
            signals.async_wait(
                [this](const boost::system::error_code& ec, int sig) {
                    this->handle_signal(ec, sig);
                }
            );
        }
    };
    
    inline int init_signal_handler() {
        g_handler_refcount().fetch_add(1, std::memory_order_relaxed);

        bool expected = false;
        if (!g_init_started().compare_exchange_strong(
                expected, true,
                std::memory_order::acq_rel,
                std::memory_order::acquire)) {
            while (!g_init_ok().load(std::memory_order_acquire)) {
                std::this_thread::yield();
            }
            return 0;
        }

        try {
            g_io_context_stopped().store(false, std::memory_order_release);
            g_signal_received().store(0, std::memory_order_release);
            g_io_context() = new boost::asio::io_context();

            using work_guard_t = boost::asio::executor_work_guard
                <boost::asio::io_context::executor_type>;
            auto* work = new work_guard_t(
                boost::asio::make_work_guard(*g_io_context()));

            auto* handler = new SignalHandler(*g_io_context());

            #ifdef _WIN32
            SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
            #endif

            g_signal_thread() = std::thread([handler, work]() {
                g_io_context()->run();
                delete work;
                delete handler;
            });

            DEBUG("[SIGNAL] Handler initialized\\n");
            g_init_ok().store(true, std::memory_order_release);
            return 0;

        } catch (const std::exception& e) {
            DEBUG("[SIGNAL] init failed: %s\\n", e.what());
        } catch (...) {
            DEBUG("[SIGNAL] init failed: unknown exception\\n");
        }

        g_init_started().store(false, std::memory_order_release);
        g_handler_refcount().fetch_sub(1, std::memory_order_acq_rel);
        return -1;
    }
    
    
    inline void register_context_notify(
        void* context_ptr,
        std::atomic<int>* running_flag,
        context_notify_fn notify_fn
    ) {
        std::lock_guard<std::mutex> lock(g_registry_mutex());
        
        RegisteredContext ctx;
        ctx.context_ptr = context_ptr;
        ctx.running_flag = running_flag;
        ctx.notify_fn = notify_fn;
        
        g_registered_contexts().push_back(ctx);
        DEBUG("[SIGNAL] Registered context %p (total: %zu)\\n",
               context_ptr, g_registered_contexts().size());
    }
    
    
    inline void unregister_context_notify(void* context_ptr) {
        std::lock_guard<std::mutex> lock(g_registry_mutex());

        auto it = g_registered_contexts().begin();
        while (it != g_registered_contexts().end()) {
            if (it->context_ptr == context_ptr) {
                g_registered_contexts().erase(it);
                //INFO("[SIGNAL] Unregistered context %p (remaining: %zu)\\n",
                //       context_ptr, g_registered_contexts().size());
                return;
            }
            ++it;
        }
    }
    
    inline void cleanup_signal_handler() {
        int prev = g_handler_refcount().fetch_sub(1, std::memory_order_acq_rel);
        if (prev <= 1) {

            #ifdef _WIN32
            SetConsoleCtrlHandler(ConsoleCtrlHandler, FALSE); 
            #endif

            bool expected = false;
            if (g_io_context_stopped().compare_exchange_strong(
                    expected, true,
                    std::memory_order::acq_rel,
                    std::memory_order::acquire)) {
                if (g_io_context()) {
                    g_io_context()->stop();
                }

                if (g_signal_thread().joinable()) {
                    g_signal_thread().join();
                }

                if (g_io_context()) {
                    delete g_io_context();
                    g_io_context() = nullptr;
                }

                std::lock_guard<std::mutex> lock(g_registry_mutex());
                g_registered_contexts().clear();
            }
         g_io_context_stopped().store(false, std::memory_order_release);
         g_init_ok().store(false, std::memory_order_release);
         g_init_started().store(false, std::memory_order_release);
            
         }
    }
    """
    
    ctypedef void (*context_notify_fn)(void* ctx) noexcept nogil
    
    int init_signal_handler() noexcept nogil
    void register_context_notify(void* ctx, int* flag, context_notify_fn fn) noexcept nogil
    void unregister_context_notify(void* ctx) noexcept nogil
    void cleanup_signal_handler() noexcept nogil