
cdef extern from *:
    """
    #include <boost/asio.hpp>
    #include <boost/system/error_code.hpp>
    #include <thread>
    #include <atomic>
    #include <vector>
    #include <mutex>
    #include <Python.h>
    
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
                printf("[SIGNAL] Received signal %d\\n", signal_number);
                g_signal_received.store(1, std::memory_order_release);
                
                {
                    std::lock_guard<std::mutex> lock(g_registry_mutex);
                    printf("[SIGNAL] Stopping %zu contexts...\\n", g_registered_contexts.size());
                    
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
                
                printf("[SIGNAL] All contexts notified\\n");
                
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
        static std::atomic<int> initialized{0};
        
        int expected = 0;
        if (!initialized.compare_exchange_strong(expected, 1, 
                                                 std::memory_order_acq_rel)) {
            return 0;
        }
        
        try {
            g_io_context = new boost::asio::io_context();
            
            auto* handler = new SignalHandler(*g_io_context);

            #ifdef _WIN32
            SetConsoleCtrlHandler(ConsoleCtrlHandler, TRUE);
            #endif
            
            g_signal_thread = new std::thread([handler]() {
                g_io_context->run();
                delete handler;
            });
            
            g_signal_thread->detach();
            
            printf("[SIGNAL] Handler initialized\\n");
            return 0;
            
        } catch (...) {
            initialized.store(0, std::memory_order_release);
            return -1;
        }
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
        
        printf("[SIGNAL] Registered context %p (total: %zu)\\n", 
               context_ptr, g_registered_contexts.size());
    }
    
    
    inline void unregister_context_notify(void* context_ptr) {
        std::lock_guard<std::mutex> lock(g_registry_mutex);
        
        auto it = g_registered_contexts.begin();
        while (it != g_registered_contexts.end()) {
            if (it->context_ptr == context_ptr) {
                g_registered_contexts.erase(it);
                printf("[SIGNAL] Unregistered context %p (remaining: %zu)\\n",
                       context_ptr, g_registered_contexts.size());
                return;
            }
            ++it;
        }
    }
    
    inline void cleanup_signal_handler() {
        #ifdef _WIN32
        SetConsoleCtrlHandler(ConsoleCtrlHandler, FALSE);
        #endif
        
        if (g_io_context) {
            g_io_context->stop();
        }
        
        {
            std::lock_guard<std::mutex> lock(g_registry_mutex);
            g_registered_contexts.clear();
        }
        
        if (g_io_context) {
            delete g_io_context;
            g_io_context = nullptr;
        }
    }
    """
    
    ctypedef void (*context_notify_fn)(void* ctx) noexcept nogil
    
    int init_signal_handler() noexcept nogil
    void register_context_notify(void* ctx, int* flag, context_notify_fn fn) noexcept nogil
    void unregister_context_notify(void* ctx) noexcept nogil
    void cleanup_signal_handler() noexcept nogil