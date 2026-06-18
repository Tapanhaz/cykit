
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
        int* running_flag;             
        context_notify_fn notify_fn;   
    };
    
    static std::vector<RegisteredContext> g_registered_contexts;
    static std::mutex g_registry_mutex;
    static std::atomic<int> g_signal_received{0};
    static boost::asio::io_context* g_io_context = nullptr;
    static std::thread* g_signal_thread = nullptr;
    static std::atomic<int> g_handler_refcount{0};

    #ifdef _WIN32
    static BOOL WINAPI ConsoleCtrlHandler(DWORD dwCtrlType) {
        if (dwCtrlType == CTRL_CLOSE_EVENT) {
            g_signal_received.store(1, std::memory_order_release);

            std::lock_guard<std::mutex> lock(g_registry_mutex);
            for (auto& ctx : g_registered_contexts) {
                if (ctx.running_flag) *ctx.running_flag = 0;
                if (ctx.notify_fn && ctx.context_ptr) ctx.notify_fn(ctx.context_ptr);
            }

            PyErr_SetInterrupt();

            if (g_io_context) g_io_context->stop();
            return TRUE;
        }
        return FALSE;
    }
    #endif
    
    class SignalHandler {
    private:
        boost::asio::io_context& io;
        boost::asio::signal_set signals;
        
        void handle_signal(const boost::system::error_code& error, int signal_number) {
            if (!error) {
                INFO("[SIGNAL] Received signal %d\\n", signal_number);
                g_signal_received.store(1, std::memory_order_release);
                
                {
                    std::lock_guard<std::mutex> lock(g_registry_mutex);
                    INFO("[SIGNAL] Stopping %zu contexts...\\n", g_registered_contexts.size());
                    
                    for (size_t i = 0; i < g_registered_contexts.size(); i++) {
                        auto& ctx = g_registered_contexts[i];
                        
                        if (ctx.running_flag) {
                            *ctx.running_flag = 0;
                        }
                        
                        if (ctx.notify_fn && ctx.context_ptr) {
                            ctx.notify_fn(ctx.context_ptr);
                        }
                    }
                }
                
                DEBUG("[SIGNAL] All contexts notified\\n");
                
                io.stop();
                
                PyErr_SetInterrupt();
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
        g_handler_refcount.fetch_add(1, std::memory_order_relaxed);

        static std::once_flag g_init_once;
        static bool           g_init_ok = false;

        std::call_once(g_init_once, []() {
            try {
                g_io_context = new boost::asio::io_context();

                using work_guard_t = boost::asio::executor_work_guard
                    <boost::asio::io_context::executor_type>;
                auto* work = new work_guard_t(
                    boost::asio::make_work_guard(*g_io_context));

                auto* handler = new SignalHandler(*g_io_context);

                #ifdef _WIN32
                SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
                #endif

                g_signal_thread = new std::thread([handler, work]() {
                    g_io_context->run();
                    delete work;
                    delete handler;
                });

                g_signal_thread->detach();

                delete g_signal_thread;
                g_signal_thread = nullptr;

                DEBUG("[SIGNAL] Handler initialized\\n");
                g_init_ok = true;

            } catch (...) {}
        });

        return g_init_ok ? 0 : -1;
    }
    
    
    inline void register_context_notify(
        void* context_ptr,
        int* running_flag,
        context_notify_fn notify_fn
    ) {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        
        RegisteredContext ctx;
        ctx.context_ptr = context_ptr;
        ctx.running_flag = running_flag;
        ctx.notify_fn = notify_fn;
        
        g_registered_contexts.push_back(ctx);
        
        DEBUG("[SIGNAL] Registered context %p (total: %zu)\\n", 
               context_ptr, g_registered_contexts.size());
    }
    
    
    inline void unregister_context_notify(void* context_ptr) {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        
        auto it = g_registered_contexts.begin();
        while (it != g_registered_contexts.end()) {
            if (it->context_ptr == context_ptr) {
                g_registered_contexts.erase(it);
                //INFO("[SIGNAL] Unregistered context %p (remaining: %zu)\\n",
                //       context_ptr, g_registered_contexts.size());
                return;
            }
            ++it;
        }
    }
    
    inline void cleanup_signal_handler() {
        int prev = g_handler_refcount.fetch_sub(1, std::memory_order_acq_rel);
        if (prev <= 1) {

            #ifdef _WIN32
            SetConsoleCtrlHandler(ConsoleCtrlHandler, FALSE);
            #endif
        
            std::lock_guard<std::mutex> lock(g_registry_mutex);
            g_registered_contexts.clear();
        }
    }
    """
    
    ctypedef void (*context_notify_fn)(void* ctx) noexcept nogil
    
    int init_signal_handler() noexcept nogil
    void register_context_notify(void* ctx, int* flag, context_notify_fn fn) noexcept nogil
    void unregister_context_notify(void* ctx) noexcept nogil
    void cleanup_signal_handler() noexcept nogil