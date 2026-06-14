
/**
 * @file base_transport.hpp
 * @brief Minimal transport base containing UDP, TCP, HTTP, and SMTP clients.
 * @date 2026-06-04
 * @copyright Part of the https://github.com/Tapanhaz/cykit library.
 *
 * @note All calls are blocking. HTTP is 1.1 only. UDP is best-effort.
 *       SMTP is outbound only. No proxy, WebSocket, or async support.
 */


#pragma once

#ifndef BOOST_SYSTEM_NO_LIB
    #define BOOST_SYSTEM_NO_LIB
#endif


#include <set>
#include <mutex>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>
#include <cstring>
#include <sstream>
#include <utility>
#include <charconv>
#include <optional>
#include <algorithm>
#include <stdexcept>
#include <functional>
#include <shared_mutex>
#include <system_error>
#include <unordered_map>
#include <boost/asio.hpp>
#include <boost/beast.hpp>
#include <boost/asio/ssl.hpp>
#include <boost/beast/ssl.hpp>

#ifdef _MSC_VER
    #include <string.h>
    #define strcasecmp(a,b) _stricmp((a),(b))
#endif


namespace transport {

namespace asio = boost::asio;
namespace beast = boost::beast;
namespace http = beast::http;
namespace ssl = asio::ssl;
using tcp = asio::ip::tcp;


#ifdef _MSC_VER
#  define DIAG_PUSH            __pragma(warning(push))
#  define DIAG_UNUSED_VAR      __pragma(warning(disable:4101))
#  define DIAG_CONST_COND      __pragma(warning(disable:4127))
#  define DIAG_POP             __pragma(warning(pop))
#elif defined(__clang__)
#  define DIAG_PUSH            _Pragma("clang diagnostic push")
#  define DIAG_UNUSED_VAR      _Pragma("clang diagnostic ignored \"-Wunused-variable\"")
#  define DIAG_CONST_COND      
#  define DIAG_POP             _Pragma("clang diagnostic pop")
#else
#  define DIAG_PUSH            _Pragma("GCC diagnostic push")
#  define DIAG_UNUSED_VAR      _Pragma("GCC diagnostic ignored \"-Wunused-variable\"")
#  define DIAG_CONST_COND      
#  define DIAG_POP             _Pragma("GCC diagnostic pop")
#endif

#ifdef _WIN32
#  define SET_SOCK_TIMEOUT_RECV(fd, secs) \
do \
    { \
       DWORD ms_ = static_cast<DWORD>((secs) * 1000); \
       setsockopt((fd), SOL_SOCKET, SO_RCVTIMEO, \
                  reinterpret_cast<const char*>(&ms_), sizeof(ms_)); \
   } while(0)
#  define SET_SOCK_TIMEOUT_SEND(fd, secs) \
do \
    { \
       DWORD ms_ = static_cast<DWORD>((secs) * 1000); \
       setsockopt((fd), SOL_SOCKET, SO_SNDTIMEO, \
                  reinterpret_cast<const char*>(&ms_), sizeof(ms_)); \
   } while(0)
#else
#  define SET_SOCK_TIMEOUT_RECV(fd, secs) \
do \
    { \
       struct timeval tv_ { static_cast<long>(secs), \
           static_cast<long>(((secs) - static_cast<long>(secs)) * 1e6) }; \
       setsockopt((fd), SOL_SOCKET, SO_RCVTIMEO, &tv_, sizeof(tv_)); \
   } while(0)
#  define SET_SOCK_TIMEOUT_SEND(fd, secs) \
do \
    { \
       struct timeval tv_ { static_cast<long>(secs), \
           static_cast<long>(((secs) - static_cast<long>(secs)) * 1e6) }; \
       setsockopt((fd), SOL_SOCKET, SO_SNDTIMEO, &tv_, sizeof(tv_)); \
   } while(0)
#endif

#define SET_SOCK_TIMEOUT(fd, secs) \
    do \
        { \
            SET_SOCK_TIMEOUT_RECV(fd, secs); \
            SET_SOCK_TIMEOUT_SEND(fd, secs); \
        } while(0)


enum class TransportErrorKind : uint8_t {
    None = 0,
    Timeout,
    Dns,
    Connect,
    Tls,
    Protocol,
    Auth,
    Remote,
    Cancelled,
    Local
};


class TransportError : public std::exception {
    public:
        TransportErrorKind kind   = TransportErrorKind::None;
        int               code   = 0;   
        std::string       message;
        std::string       url;          
        int               http_status = 0;
    
        TransportError() = default;
        
        explicit TransportError(std::string msg,
                                TransportErrorKind k = TransportErrorKind::Local,
                                int c = 0)
            : kind(k), code(c), message(std::move(msg)) {}    
            
        TransportError(TransportErrorKind k, std::string msg,
                       int c = 0, std::string u = {})
            : kind(k), code(c), message(std::move(msg)), url(std::move(u)) {}
            
        const char* what() const noexcept override { return message.c_str(); }
    
        explicit operator bool() const noexcept {
            return kind != TransportErrorKind::None;
        }
        
        static TransportError timeout(const std::string& url = {}) {
            return { TransportErrorKind::Timeout, "Request timed out", 0, url };
        }
        static TransportError cancelled(const std::string& url = {}) {
            return { TransportErrorKind::Cancelled, "Request cancelled", 0, url };
        }
        static TransportError tls(const std::string& detail, int c = 0) {
            return { TransportErrorKind::Tls, detail, c };
        }
        static TransportError dns(const std::string& host) {
            return { TransportErrorKind::Dns,
                     "DNS resolution failed for: " + host };
        }
        static TransportError remote(int http_code, const std::string& reason) {
            TransportError e{ TransportErrorKind::Remote, reason, http_code };
            e.http_status = http_code;
            return e;
        }
};


class CancellationSource {
    public:
        CancellationSource() : flag_(std::make_shared<std::atomic<bool>>(false)) {}
    
        void cancel() noexcept { flag_->store(true, std::memory_order_release); }
        void reset()  noexcept { flag_->store(false, std::memory_order_release); }
        bool is_cancelled() const noexcept {
            return flag_->load(std::memory_order_acquire);
        }
        
        struct Token {
            std::shared_ptr<const std::atomic<bool>> flag;
            bool is_cancelled() const noexcept {
                return flag && flag->load(std::memory_order_acquire);
            }
            void throw_if_cancelled() const {
                if (is_cancelled())
                    throw TransportError::cancelled();
            }
        };
    
        Token token() const {
            return Token{ std::const_pointer_cast<const std::atomic<bool>>(flag_) };
        }
    
    private:
        std::shared_ptr<std::atomic<bool>> flag_;
};
    
using CancelToken = CancellationSource::Token; 

using HeaderList = std::vector<std::pair<std::string, std::string>>;


struct IHeaderLess {
    bool operator()(const std::string& a, const std::string& b) const noexcept {
        return std::lexicographical_compare(
            a.begin(), a.end(), b.begin(), b.end(),
            [](char x, char y){ return std::tolower((unsigned char)x)
                                      < std::tolower((unsigned char)y); });
    }    
};

template<typename Body>
inline void apply_header_list(http::request<Body>& req,
                              const HeaderList& headers) {
    for (const auto& [k, v] : headers)
        req.set(k, v);  
}

template<typename Body>
inline void apply_header_list_insert(http::request<Body>& req,
                                     const HeaderList& headers) {
    for (const auto& [k, v] : headers)
        req.insert(k, v);
}

template<typename Body>
inline void apply_user_agent_rule(http::request<Body>& req,
                                  const std::string& explicit_ua,
                                  const std::string& default_ua = "CykitTransport/1.0") {
                                    
    if (!explicit_ua.empty())
        req.set(http::field::user_agent, explicit_ua);
    else if (req[http::field::user_agent].empty())
        req.set(http::field::user_agent, default_ua);
        
}




struct CookieEntry {
    std::string name;
    std::string value;
    std::string domain;     
    std::string path = "/";
    std::string same_site;  
    std::chrono::system_clock::time_point expires; 
    bool secure     = false;
    bool http_only  = false;
    bool persistent = false;

    bool is_expired() const noexcept {
        return persistent &&
               expires < std::chrono::system_clock::now();
    }
    
    bool domain_matches(const std::string& host) const noexcept {
        if (domain.empty()) return true;
        if (domain[0] == '.') {            
            return host.size() >= domain.size() &&
                   host.compare(host.size() - domain.size() + 1,
                                domain.size() - 1, domain, 1) == 0;
        }
        return host == domain;
    }
    bool path_matches(const std::string& req_path) const noexcept {
        return req_path.substr(0, path.size()) == path;
    }
    bool secure_ok(bool is_https) const noexcept {
        return !secure || is_https;
    }
};

class CookieJar {
public:

    void parse_and_insert(const std::string& set_cookie_header,
                          const std::string& request_domain,
                          const std::string& request_path) {
        std::lock_guard<std::mutex> lk(mtx_);
        CookieEntry e = parse_set_cookie(set_cookie_header,
                                         request_domain, request_path);
        evict_expired_locked();
        insert_or_replace_locked(std::move(e));
    }
    
    std::string cookie_header(const std::string& domain,
                               const std::string& path,
                               bool is_https) const {
        std::lock_guard<std::mutex> lk(mtx_);
        std::string hdr;
        for (const auto& e : jar_) {
            if (e.is_expired()) continue;
            if (!e.domain_matches(domain)) continue;
            if (!e.path_matches(path)) continue;
            if (!e.secure_ok(is_https)) continue;
            if (!hdr.empty()) hdr += "; ";
            hdr += e.name + "=" + e.value;
        }
        return hdr;
    }
    
    std::vector<CookieEntry> snapshot() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return jar_;
    }

    void clear() {
        std::lock_guard<std::mutex> lk(mtx_);
        jar_.clear();
    }
    
    void evict_expired() {
        std::lock_guard<std::mutex> lk(mtx_);
        evict_expired_locked();
    }

private:
    static std::string trim(const std::string& s) {
        size_t a = s.find_first_not_of(" \t");
        size_t b = s.find_last_not_of(" \t");
        return (a == std::string::npos) ? "" : s.substr(a, b - a + 1);
    }
    static std::string to_lower(std::string s) {
        for (char& c : s) c = static_cast<char>(std::tolower((unsigned char)c));
        return s;
    }

    static CookieEntry parse_set_cookie(const std::string& header,
                                         const std::string& domain,
                                         const std::string& path) {
        CookieEntry e;
        e.domain = domain;
        e.path   = path;

        std::istringstream ss(header);
        std::string token;
        bool first = true;
        while (std::getline(ss, token, ';')) {
            token = trim(token);
            if (token.empty()) continue;
            auto eq = token.find('=');
            std::string key   = (eq == std::string::npos) ? token
                                                           : trim(token.substr(0, eq));
            std::string value = (eq == std::string::npos) ? ""
                                                          : trim(token.substr(eq + 1));
            if (first) {
                e.name  = key;
                e.value = value;
                first   = false;
                continue;
            }
            std::string lk = to_lower(key);
            if (lk == "domain")   { e.domain = value.empty() ? domain : value; }
            else if (lk == "path")      { e.path = value.empty() ? "/" : value; }
            else if (lk == "secure")    { e.secure = true; }
            else if (lk == "httponly")  { e.http_only = true; }
            else if (lk == "samesite")  { e.same_site = value; }
            else if (lk == "max-age") {
                long secs = 0;
                std::from_chars(value.data(), value.data() + value.size(), secs);
                e.expires = std::chrono::system_clock::now()
                          + std::chrono::seconds(secs);
                e.persistent = true;
            } else if (lk == "expires") {
                
#if defined(_MSC_VER)
        struct tm tm_ = {};
                
        {        
            std::string v = value;
            auto comma = v.find(',');
            if (comma != std::string::npos)
                v = v.substr(comma + 2);   
        
            std::istringstream iss(v);
            std::string mon_str;
            int dy = 0, yr = 0, hr = 0, mn = 0, sc = 0;
            
            char colon1 = 0, colon2 = 0;
            if (iss >> dy >> mon_str >> yr
                    >> hr >> colon1 >> mn >> colon2 >> sc) {
                static const std::array<std::string_view, 12> mons = {
                    "Jan","Feb","Mar","Apr","May","Jun",
                    "Jul","Aug","Sep","Oct","Nov","Dec"
                };
                auto it = std::find(mons.begin(), mons.end(),
                                    std::string_view(mon_str));
                if (it != mons.end()) {
                    tm_.tm_mon   = static_cast<int>(it - mons.begin());
                    tm_.tm_mday  = dy;
                    tm_.tm_year  = yr - 1900;
                    tm_.tm_hour  = hr;
                    tm_.tm_min   = mn;
                    tm_.tm_sec   = sc;
                    tm_.tm_isdst = 0;
                    e.expires    = std::chrono::system_clock::from_time_t(
                                       _mkgmtime(&tm_));
                    e.persistent = true;
                }
            }
        }
#else
            struct tm tm_ = {};
            if (strptime(value.c_str(), "%a, %d %b %Y %H:%M:%S %Z", &tm_)) {
                e.expires = std::chrono::system_clock::from_time_t(timegm(&tm_));
                e.persistent = true;
            }
#endif
            }
        }
        return e;
    }

    void evict_expired_locked() {
        jar_.erase(std::remove_if(jar_.begin(), jar_.end(),
                       [](const CookieEntry& e){ return e.is_expired(); }),
                   jar_.end());
    }

    void insert_or_replace_locked(CookieEntry e) {
        
        for (auto& existing : jar_) {
            if (existing.name   == e.name   &&
                existing.domain == e.domain &&
                existing.path   == e.path) {
                existing = std::move(e);
                return;
            }
        }
        jar_.push_back(std::move(e));
    }

    mutable std::mutex mtx_;
    std::vector<CookieEntry> jar_;
};


    
struct TlsPolicy {
    bool        verify_peer      = true;
    bool        verify_hostname  = true;
    std::string ca_file;          
    std::string ca_path;          
    std::string cert_file;        
    std::string key_file;         
    std::string key_password;     
    int         min_tls_version  = TLS1_2_VERSION;  
    bool        allow_http2      = false; 
    
    static TlsPolicy strict() {
        TlsPolicy p;
        p.min_tls_version = TLS1_3_VERSION;
        return p;
    }
    
    static TlsPolicy insecure() {
        TlsPolicy p;
        p.verify_peer     = false;
        p.verify_hostname = false;
        return p;
    }
};

inline std::mutex& ssl_ctx_init_mutex() {
    static std::mutex m;
    return m;
}
    
inline ssl::context create_ssl_context(const TlsPolicy& policy = TlsPolicy{}) {
    ssl::context ctx(ssl::context::tls_client);
    std::lock_guard<std::mutex> lock(ssl_ctx_init_mutex());
    
    long opts = ssl::context::no_sslv2 | ssl::context::no_sslv3
              | ssl::context::no_tlsv1 | ssl::context::no_tlsv1_1;
    if (policy.min_tls_version >= TLS1_3_VERSION)
        opts |= SSL_OP_NO_TLSv1_2;
    ctx.set_options(opts);
    
    if (policy.verify_peer) {
        ctx.set_verify_mode(ssl::verify_peer | ssl::verify_fail_if_no_peer_cert);
        if (!policy.ca_file.empty())
            ctx.load_verify_file(policy.ca_file);
        else if (!policy.ca_path.empty())
            ctx.add_verify_path(policy.ca_path);
        else
            ctx.set_default_verify_paths();
    } else {
        ctx.set_verify_mode(ssl::verify_none);
    }
    
    if (!policy.cert_file.empty()) {
        ctx.use_certificate_chain_file(policy.cert_file);
        if (!policy.key_password.empty()) {
            ctx.set_password_callback(
                [pw = policy.key_password](size_t, ssl::context::password_purpose) {
                    return pw;
                });
        }
        ctx.use_private_key_file(policy.key_file, ssl::context::pem);
    }
    
    if (policy.allow_http2) {
        
        static const unsigned char alpn[] = "\x02h2\x08http/1.1";
        SSL_CTX_set_alpn_protos(ctx.native_handle(), alpn, sizeof(alpn) - 1);
    }

    return ctx;
}


struct TransportHooks {
    
    std::function<void(HeaderList& /*req_headers*/)> on_before_request;

    std::function<void(int /*status*/, const HeaderList& /*resp_headers*/)>
        on_response_header;
        
    std::function<bool(const char* /*data*/, size_t /*len*/)> on_body_chunk;
    
    std::function<bool(int /*status*/, const std::string& /*location*/)>
        on_redirect;
        
    std::function<void(int /*attempt*/, const TransportError&)> on_retry;
    
    std::function<void(const TransportError& /*err_or_none*/)> on_complete;
};

using BodyChunkCallback  = std::function<bool(const char*, size_t)>;
using UploadChunkCallback = std::function<size_t(char* /*buf*/, size_t /*max*/)>;



enum class IdempotencyClass : uint8_t {
    Idempotent,    
    NonIdempotent, 
    Force          
};

struct RetryPolicy {
    int    max_attempts      = 1;        
    double initial_delay_sec = 1.0;      
    double backoff_factor    = 2.0;      
    double max_delay_sec     = 30.0;     
    double jitter_factor     = 0.1;      

    std::set<int> retryable_statuses = { 429, 500, 502, 503, 504 };
    
    std::set<TransportErrorKind> retryable_kinds = {
        TransportErrorKind::Timeout,
        TransportErrorKind::Connect,
        TransportErrorKind::Remote,
        TransportErrorKind::Local,
    };

    IdempotencyClass idempotency = IdempotencyClass::Idempotent;    

    bool should_retry_error(const TransportError& e) const noexcept {
        return retryable_kinds.count(e.kind) > 0;
    }
    bool should_retry_status(int s) const noexcept {
        return retryable_statuses.count(s) > 0;
    }
};

struct KeepAliveConfig {
    bool   enabled        = true;
    int    idle_sec       = 60;   
    int    interval_sec   = 10;   
    int    probe_count    = 5;    
    int    max_requests   = 1000; 
    double max_age_sec    = 300;  
    
    void apply(intptr_t fd) const {
#if defined(SO_KEEPALIVE)
        int ka = enabled ? 1 : 0;
        setsockopt(static_cast<int>(fd), SOL_SOCKET, SO_KEEPALIVE,
                   reinterpret_cast<const char*>(&ka), sizeof(ka));
#endif
#if defined(TCP_KEEPIDLE) && !defined(_WIN32)
        if (enabled) {
            int idle = idle_sec, cnt = probe_count, intvl = interval_sec;
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE,  &idle,  sizeof(idle));
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,   &cnt,   sizeof(cnt));
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
        }
#endif
    }
};

inline auto duration_from_seconds(double secs) {
    return std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double>(secs));
}

struct TransportTimeouts {
    double connect_sec   = 10.0;  
    double tls_sec       = 10.0;  
    double write_sec     = 30.0;  
    double read_sec      = 30.0;  
    double body_sec      = 60.0;  
    double total_sec     = 0.0;   
                                  
    double pool_idle_sec = 0.0;   
                                  
    explicit TransportTimeouts(double all) noexcept
        : connect_sec(all), tls_sec(all), write_sec(all)
        , read_sec(all), body_sec(all), total_sec(0.0) {}

    TransportTimeouts() = default;

    auto connect_dur() const { return duration_from_seconds(connect_sec > 0 ? connect_sec : read_sec); }
    auto tls_dur()     const { return duration_from_seconds(tls_sec     > 0 ? tls_sec     : read_sec); }
    auto write_dur()   const { return duration_from_seconds(write_sec   > 0 ? write_sec   : read_sec); }
    auto read_dur()    const { return duration_from_seconds(read_sec); }
    auto body_dur()    const { return duration_from_seconds(body_sec    > 0 ? body_sec    : read_sec); }
};

struct SmtpTimeouts {
    double connect_sec   = 10.0;  
    double tls_sec       = 10.0;  
    double banner_sec    = 10.0;  
    double command_sec   = 30.0;  
    double data_sec      = 60.0;  
    double response_sec  = 30.0;  
    
    explicit SmtpTimeouts(double all) noexcept
        : connect_sec(all), tls_sec(all), banner_sec(all)
        , command_sec(all), data_sec(all), response_sec(all) {}

    SmtpTimeouts() = default;
};

struct TcpTimeouts {
    double connect_sec = 10.0;  
    double read_sec    = 30.0;  
    double write_sec   = 30.0;  

    explicit TcpTimeouts(double all) noexcept
        : connect_sec(all), read_sec(all), write_sec(all) {}

    TcpTimeouts() = default;
};


inline double jitter_factor_sample(double base_delay, double factor) noexcept {
    thread_local std::mt19937_64 eng{std::random_device{}()};
    std::uniform_real_distribution<double> dist(-1.0, 1.0);
    return base_delay * factor * dist(eng);
}

//************************************************************************************************
//************************************    TCP     ************************************************
//************************************************************************************************

class TcpSocket {
private:
    using RAW_SOCKET = intptr_t;
    static constexpr RAW_SOCKET INVALID_RAW_SOCKET = static_cast<RAW_SOCKET>(-1);
public:
    TcpSocket() : fd_(INVALID_RAW_SOCKET) {}

    ~TcpSocket() { close(); }
    
    TcpSocket(const TcpSocket&) = delete;
    TcpSocket& operator=(const TcpSocket&) = delete;
    
    TcpSocket(TcpSocket&& other) noexcept : fd_(other.fd_) {
        other.fd_ = INVALID_RAW_SOCKET;
    }
    TcpSocket& operator=(TcpSocket&& other) noexcept {
        if (this != &other) {
            close();
            fd_ = other.fd_;
            other.fd_ = INVALID_RAW_SOCKET;
        }
        return *this;
    }
    
    void connect(const std::string& host, uint16_t port, TcpTimeouts timeouts, bool keepalive, CancelToken token = {}) {
        close();
#ifdef _WIN32

        static struct WsaInit {
            WsaInit() {
                WSADATA wsa;
                WSAStartup(MAKEWORD(2, 2), &wsa);
            }
        } wsa_init;
#endif

        char port_str[8];
        snprintf(port_str, sizeof(port_str), "%u", static_cast<unsigned>(port));
        struct addrinfo hints = {}, *res = nullptr, *rp = nullptr;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;

        if (getaddrinfo(host.c_str(), port_str, &hints, &res) != 0 || !res) {
            throw TransportError("getaddrinfo failed for " + host + ":" + std::to_string(port));
        }

        RAW_SOCKET fd = INVALID_RAW_SOCKET;
        for (rp = res; rp; rp = rp->ai_next) {
            fd = ::socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (fd == INVALID_RAW_SOCKET) continue;
            
#ifdef _WIN32
            u_long nb = 1;
            ioctlsocket(fd, FIONBIO, &nb);
#else
            int flags = fcntl(fd, F_GETFL, 0);
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif

            int r = ::connect(fd, rp->ai_addr, static_cast<socklen_t>(rp->ai_addrlen));
#ifdef _WIN32
            bool in_progress = (r == SOCKET_ERROR && WSAGetLastError() == WSAEWOULDBLOCK);
#else
            bool in_progress = (r < 0 && errno == EINPROGRESS);
#endif

            if (r == 0 || in_progress) {
                fd_set wset;
                FD_ZERO(&wset);
                FD_SET(fd, &wset);
                long tv_sec = static_cast<long>(timeouts.connect_sec);
                long tv_usec = static_cast<long>((timeouts.connect_sec - tv_sec) * 1e6);
                struct timeval tv { tv_sec, tv_usec };

                int sel;
#ifdef _WIN32
                sel = select(static_cast<int>(fd) + 1,
                             nullptr, &wset, nullptr, &tv);
#else
                do {
                    sel = select(static_cast<int>(fd) + 1,
                                 nullptr, &wset, nullptr, &tv);
                } while (sel < 0 && errno == EINTR);
#endif
                if (sel > 0) {
                    token.throw_if_cancelled();
                    int err = 0;
                    socklen_t elen = sizeof(err);
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &elen);
                    if (err == 0) {
                        
#ifdef _WIN32
                        u_long nb0 = 0;
                        ioctlsocket(fd, FIONBIO, &nb0);
#else
                        fcntl(fd, F_SETFL, flags);
#endif
                        if (keepalive) {
                            int ka = 1;
                            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE,
                                       reinterpret_cast<const char*>(&ka), sizeof(ka));
                            token.throw_if_cancelled(); 
#if defined(TCP_KEEPIDLE) && !defined(_WIN32)
                            int idle = 60, cnt = 5, intvl = 10;
                            setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
                            setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
                            setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
#endif
                        }
                        SET_SOCK_TIMEOUT_RECV(fd, timeouts.read_sec);
                        SET_SOCK_TIMEOUT_SEND(fd, timeouts.write_sec);

#if defined(__APPLE__)
                        int nosigpipe = 1;
                        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                                   &nosigpipe, sizeof(nosigpipe));
#endif

                        fd_ = fd;
                        freeaddrinfo(res);
                        return;
                    }
                }
            }
        #ifdef _WIN32
            ::closesocket(fd);
        #else
            ::close(fd);
        #endif
            fd = INVALID_RAW_SOCKET;
        }
        freeaddrinfo(res);
        throw TransportError("TCP connect failed to " + host + ":" + std::to_string(port));
    }

    void close() {
        if (fd_ != INVALID_RAW_SOCKET) {
#ifdef _WIN32
            ::closesocket(fd_);
#else
            ::close(fd_);
#endif
            fd_ = INVALID_RAW_SOCKET;
        }
    }

    void shutdown() {
        if (fd_ != INVALID_RAW_SOCKET) {
#ifdef _WIN32
            ::shutdown(fd_, SD_BOTH);
#else
            ::shutdown(fd_, SHUT_RDWR);
#endif
        }
    }

    RAW_SOCKET native_handle() const { return fd_; }
    
    void send_all(const std::string& data) {
        size_t sent = 0;
        while (sent < data.size()) {
            int n = ::send(fd_, data.data() + sent,
                           static_cast<int>(data.size() - sent),
#if defined(_WIN32)
                           0          
#elif defined(__APPLE__)
                           0          
                                      
#else
                           MSG_NOSIGNAL 
#endif
            );
            if (n <= 0) throw TransportError("TCP send failed", TransportErrorKind::Local);
            sent += static_cast<size_t>(n);
        }
    }

    std::string recv(size_t max_size) {
        std::string buf(max_size, '\0');
        int n = ::recv(fd_, buf.data(), static_cast<int>(max_size), 0);
        if (n < 0) throw TransportError("TCP recv failed", TransportErrorKind::Local);
        if (n == 0) throw TransportError("TCP recv: connection closed", TransportErrorKind::Remote);
        buf.resize(static_cast<size_t>(n));
        return buf;
    }

    std::string recv_exactly(size_t need) {
        std::string buf(need, '\0');
        size_t got = 0;
        while (got < need) {
            int n = ::recv(fd_, buf.data() + got, static_cast<int>(need - got), 0);
            if (n <= 0) throw TransportError("TCP recv_exactly failed", TransportErrorKind::Local);
            got += static_cast<size_t>(n);
        }
        return buf;
    }

    std::string peek(size_t max_size) {
        std::string buf(max_size, '\0');
        int n = ::recv(fd_, buf.data(), static_cast<int>(max_size), MSG_PEEK);
        if (n < 0) throw TransportError("TCP peek failed");
        buf.resize(static_cast<size_t>(n));
        return buf;
    }

    bool is_open() const noexcept { return fd_ != INVALID_RAW_SOCKET; }

private:
    RAW_SOCKET fd_;
};

//************************************************************************************************
//************************************    UDP     ************************************************
//************************************************************************************************

class UdpSocket {
public:
    UdpSocket() : fd_(INVALID_RAW_SOCKET) {}

    ~UdpSocket() { close(); }

    UdpSocket(const UdpSocket&) = delete;
    UdpSocket& operator=(const UdpSocket&) = delete;
    UdpSocket(UdpSocket&& other) noexcept : fd_(other.fd_), addr_(other.addr_), addrlen_(other.addrlen_) {
        other.fd_ = INVALID_RAW_SOCKET;
    }
    UdpSocket& operator=(UdpSocket&& other) noexcept {
        if (this != &other) {
            close();
            fd_ = other.fd_;
            addr_ = other.addr_;
            addrlen_ = other.addrlen_;
            other.fd_ = INVALID_RAW_SOCKET;
        }
        return *this;
    }

    void create_client(const std::string& host, uint16_t port, double recv_timeout_sec, bool broadcast, double send_timeout_sec= 5.0) {
        close();
#ifdef _WIN32
        static struct WsaInit { WsaInit() { WSADATA w; WSAStartup(MAKEWORD(2,2), &w); } } wsa_init;
#endif
        char port_str[8];
        snprintf(port_str, sizeof(port_str), "%u", static_cast<unsigned>(port));
        struct addrinfo hints = {}, *res = nullptr;
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(host.c_str(), port_str, &hints, &res) != 0 || !res)
            throw TransportError("UDP getaddrinfo failed");
        fd_ = ::socket(res->ai_family, res->ai_socktype, res->ai_protocol);
        if (fd_ == INVALID_RAW_SOCKET) {
            freeaddrinfo(res);
            throw TransportError("UDP socket creation failed");
        }
        memcpy(&addr_, res->ai_addr, res->ai_addrlen);
        addrlen_ = static_cast<socklen_t>(res->ai_addrlen);
        freeaddrinfo(res);

        SET_SOCK_TIMEOUT_RECV(fd_, recv_timeout_sec);
        SET_SOCK_TIMEOUT_SEND(fd_, send_timeout_sec);

        if (broadcast) {
            int bc = 1;
            setsockopt(fd_, SOL_SOCKET, SO_BROADCAST,
                       reinterpret_cast<const char*>(&bc), sizeof(bc));
        }
    }
    
    void create_server(uint16_t port, bool reuse_addr, double timeout_sec) {
        close();
#ifdef _WIN32
        static struct WsaInit { WsaInit() { WSADATA w; WSAStartup(MAKEWORD(2,2), &w); } } wsa_init;
#endif
        fd_ = ::socket(AF_INET6, SOCK_DGRAM, 0);
        if (fd_ == INVALID_RAW_SOCKET) {
            fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        }
        if (fd_ == INVALID_RAW_SOCKET)
            throw TransportError("UDP server socket creation failed");
        if (reuse_addr) {
            int opt = 1;
            setsockopt(fd_, SOL_SOCKET, SO_REUSEADDR,
                       reinterpret_cast<const char*>(&opt), sizeof(opt));
        }
        struct sockaddr_in6 addr = {};
        addr.sin6_family = AF_INET6;
        addr.sin6_addr = in6addr_any;
        addr.sin6_port = htons(port);
        if (::bind(fd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) != 0) {
            close();
            throw TransportError("UDP bind failed on port " + std::to_string(port));
        }
        SET_SOCK_TIMEOUT_RECV(fd_, timeout_sec);
    }

    void sendto(const std::string& data) {
        int n = ::sendto(fd_, data.data(), static_cast<int>(data.size()), 0,
                         reinterpret_cast<struct sockaddr*>(&addr_), addrlen_);
        if (n < 0 || static_cast<size_t>(n) != data.size())
            throw TransportError("UDP sendto failed");
    }

    std::pair<std::string, sockaddr_storage> recvfrom(size_t max_size = 65535) {
        std::string buf(max_size, '\0');
        sockaddr_storage src_addr;
        socklen_t src_len = sizeof(src_addr);
        int n = ::recvfrom(fd_, buf.data(), static_cast<int>(max_size), 0,
                           reinterpret_cast<struct sockaddr*>(&src_addr), &src_len);
        if (n < 0) throw TransportError("UDP recvfrom failed");
        buf.resize(static_cast<size_t>(n));
        return {buf, src_addr};
    }

    void close() {
        if (fd_ != INVALID_RAW_SOCKET) {
#ifdef _WIN32
            ::closesocket(fd_);
#else
            ::close(fd_);
#endif
            fd_ = INVALID_RAW_SOCKET;
        }
    }

    bool is_open() const noexcept { return fd_ != INVALID_RAW_SOCKET; }

private:
    using RAW_SOCKET = intptr_t;
    static constexpr RAW_SOCKET INVALID_RAW_SOCKET = -1;
    RAW_SOCKET fd_ = INVALID_RAW_SOCKET;
    sockaddr_storage addr_ = {};
    socklen_t addrlen_ = 0;
};

//************************************************************************************************
//************************************    HTTP    ************************************************
//************************************************************************************************

inline std::string base64_encode(const std::string& src) {
    static const char T[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string dst;
    int v = 0, b = -6;
    for (unsigned char c : src) {
        v = (v << 8) + c;
        b += 8;
        while (b >= 0) {
            dst.push_back(T[(v >> b) & 63]);
            b -= 6;
        }
    }
    if (b > -6) dst.push_back(T[((v << 8) >> (b + 8)) & 63]);
    while (dst.size() % 4) dst.push_back('=');
    return dst;
}

struct HttpResponse {
    int         status  = -1;
    std::string body;
    std::string reason;
    
    HeaderList  headers;
    
    std::string header(const std::string& name) const {
        for (const auto& [k, v] : headers)
            if (strcasecmp(k.c_str(), name.c_str()) == 0) return v;
        return {};
    }
    
    std::vector<std::string> header_all(const std::string& name) const {
        std::vector<std::string> out;
        for (const auto& [k, v] : headers)
            if (strcasecmp(k.c_str(), name.c_str()) == 0)
                out.push_back(v);
        return out;
    }

    bool ok() const noexcept { return status >= 200 && status < 300; }
    bool is_redirect() const noexcept {
        return status == 301 || status == 302 || status == 303
            || status == 307 || status == 308;
    }
    std::string location() const { return header("Location"); }
    
    bool http2 = false;
    
    size_t bytes_received = 0;
};


struct RequestOptions {    
    HeaderList  headers;
    
    HeaderList  extra_cookies;
    
    std::string user_agent;
    
    double timeout_sec   = 0.0;
    TransportTimeouts  timeouts; 

    size_t expect_continue_threshold = 0;
    
    std::optional<TlsPolicy> tls_policy;
    
    std::optional<RetryPolicy> retry_policy;
    
    CancelToken cancel_token;
    
    BodyChunkCallback body_chunk_cb;
    
    UploadChunkCallback upload_chunk_cb;
    size_t upload_chunk_size = 65536; 
    
    std::optional<TransportHooks> hooks;
    
    int max_redirects = -1;
    
    bool forward_auth_on_redirect = false;
};


//************************************************************************************************
//*********************************    HTTP CLIENT    ********************************************
//************************************************************************************************

class HttpClient {
    public:
        explicit HttpClient(TlsPolicy    tls_policy    = {},
                            RetryPolicy  retry_policy  = {},
                            KeepAliveConfig ka_cfg     = {},
                            TransportHooks  hooks      = {},
                            HeaderList   persistent_headers = {},
                            std::string  user_agent    = "CykitTransport/1.0",
                            TransportTimeouts timeouts = {},
                            int          max_redirects = 10,
                            std::shared_ptr<CookieJar> cookie_jar = nullptr)
            : tls_policy_(std::move(tls_policy)), 
              retry_policy_(std::move(retry_policy)),
              ka_cfg_(std::move(ka_cfg)),
              hooks_(std::move(hooks)),
              persistent_headers_(std::move(persistent_headers)),
              user_agent_(std::move(user_agent)),
              timeouts_(std::move(timeouts)),
              max_redirects_(max_redirects),
              cookie_jar_(cookie_jar
                           ? std::move(cookie_jar)
                           : std::make_shared<CookieJar>()) {}
                           
        CookieJar& cookie_jar() noexcept { return *cookie_jar_; }
        const CookieJar& cookie_jar() const noexcept { return *cookie_jar_; }
        
        HeaderList& persistent_headers() noexcept { return persistent_headers_; }
        const HeaderList& persistent_headers() const noexcept { return persistent_headers_; }
        
        HttpResponse request(const std::string& method,
                             const std::string& url,        
                             const std::string& body   = {},
                             const std::string& content_type = {},
                             RequestOptions     opts   = {}) {
            return do_request_with_redirect(method, url, body, content_type,
                                            std::move(opts), 0);
        }
        
        HttpResponse get(const std::string& url, RequestOptions opts = {}) {
            return request("GET", url, {}, {}, std::move(opts));
        }
        HttpResponse post(const std::string& url, const std::string& body,
                          const std::string& ct = "application/json",
                          RequestOptions opts = {}) {
            return request("POST", url, body, ct, std::move(opts));
        }
        HttpResponse put(const std::string& url, const std::string& body,
                         const std::string& ct = "application/json",
                         RequestOptions opts = {}) {
            return request("PUT", url, body, ct, std::move(opts));
        }
        HttpResponse patch(const std::string& url, const std::string& body,
                           const std::string& ct = "application/json",
                           RequestOptions opts = {}) {
            return request("PATCH", url, body, ct, std::move(opts));
        }
        HttpResponse del(const std::string& url, RequestOptions opts = {}) {
            return request("DELETE", url, {}, {}, std::move(opts));
        }
        HttpResponse head(const std::string& url, RequestOptions opts = {}) {
            return request("HEAD", url, {}, {}, std::move(opts));
        }
        HttpResponse options(const std::string& url, RequestOptions opts = {}) {
            return request("OPTIONS", url, {}, {}, std::move(opts));
        }
    
    private:
        struct ParsedUrl {
            bool        tls  = false;
            std::string host;
            uint16_t    port = 80;
            std::string path = "/";
        };

        struct DnsEntry {
            tcp::resolver::results_type endpoints;
            std::chrono::steady_clock::time_point expires_at;
        };        
    
        static ParsedUrl parse_url(const std::string& url) {
            ParsedUrl p;
            
            size_t scheme_end = url.find("://");
            if (scheme_end == std::string::npos)
                throw TransportError("Invalid URL (no scheme): " + url);
            std::string scheme = url.substr(0, scheme_end);
            for (char& c : scheme) c = static_cast<char>(std::tolower((unsigned char)c));
            p.tls = (scheme == "https");
            p.port = p.tls ? 443 : 80;
    
            size_t host_start = scheme_end + 3;
            size_t path_pos   = url.find('/', host_start);
            std::string authority = (path_pos == std::string::npos)
                                  ? url.substr(host_start)
                                  : url.substr(host_start, path_pos - host_start);
            p.path = (path_pos == std::string::npos) ? "/" : url.substr(path_pos);
    
            auto at = authority.rfind('@');
            if (at != std::string::npos) authority = authority.substr(at + 1);
    
            auto colon = authority.rfind(':');
            if (colon != std::string::npos) {
                p.host = authority.substr(0, colon);
                p.port = static_cast<uint16_t>(
                             std::stoul(authority.substr(colon + 1)));
            } else {
                p.host = authority;
            }
            return p;
        }
    
        static std::string resolve_location(const std::string& base_url,
                                            const std::string& location) {
            if (location.substr(0, 4) == "http") return location;  
            if (location.size() >= 2 && location[0] == '/' && location[1] == '/') {
                size_t s = base_url.find("://");
                return base_url.substr(0, s + 1) + location;
            }
            
            ParsedUrl pu = parse_url(base_url);
            std::string base = (pu.tls ? "https" : "http") + std::string("://")
                             + pu.host + ":" + std::to_string(pu.port);
            if (!location.empty() && location[0] == '/') return base + location;
            
            std::string dir = pu.path.substr(0, pu.path.rfind('/') + 1);
            return base + dir + location;
        }
        
        HttpResponse do_request_with_redirect(const std::string& method,
                                               const std::string& url,
                                               const std::string& body,
                                               const std::string& ct,
                                               RequestOptions opts,
                                               int redirect_count) {
            int limit = (opts.max_redirects >= 0)
                      ? opts.max_redirects : max_redirects_;
    
            HttpResponse resp = do_single_request(method, url, body, ct, opts);
    
            if (resp.is_redirect() && redirect_count < limit) {
                std::string loc = resp.location();
                if (loc.empty()) return resp;
                
                if (hooks_.on_redirect && !hooks_.on_redirect(resp.status, loc))
                    return resp;
                if (opts.hooks && opts.hooks->on_redirect &&
                    !opts.hooks->on_redirect(resp.status, loc))
                    return resp;
                    
                for (const auto& sc : resp.header_all("Set-Cookie")) {
                    ParsedUrl pu = parse_url(url);
                    cookie_jar_->parse_and_insert(sc, pu.host, pu.path);
                }
    
                std::string next_url = resolve_location(url, loc);    
                
                std::string next_method = method;
                std::string next_body   = body;
                std::string next_ct     = ct;
                if (resp.status == 303) {
                    next_method = "GET";
                    next_body.clear();
                    next_ct.clear();
                }
                
                RequestOptions next_opts = opts;
                if (!opts.forward_auth_on_redirect) {
                    ParsedUrl cur = parse_url(url);
                    ParsedUrl nxt = parse_url(next_url);
                    if (cur.host != nxt.host) {
                        next_opts.headers.erase(
                            std::remove_if(next_opts.headers.begin(),
                                           next_opts.headers.end(),
                                [](const std::pair<std::string,std::string>& h) {
                                    std::string k = h.first;
                                    for (char& c : k) c = static_cast<char>(
                                        std::tolower((unsigned char)c));
                                    return k == "authorization";
                                }),
                            next_opts.headers.end());
                    }
                }
    
                return do_request_with_redirect(next_method, next_url,
                                                next_body, next_ct,
                                                next_opts, redirect_count + 1);
            }

            for (const auto& sc : resp.header_all("Set-Cookie")) {
                ParsedUrl pu = parse_url(url);
                cookie_jar_->parse_and_insert(sc, pu.host, pu.path);
            }
    
            return resp;
        }
        
        HttpResponse do_single_request(const std::string& method,
                                        const std::string& url,
                                        const std::string& body,
                                        const std::string& ct,
                                        const RequestOptions& opts) {
            const RetryPolicy& rp = opts.retry_policy.value_or(retry_policy_);
            const TransportTimeouts eff_to = (opts.timeout_sec > 0.0)
                                            ? TransportTimeouts(opts.timeout_sec)
                                            : (opts.timeouts.read_sec > 0.0 ? opts.timeouts : timeouts_);
            const TlsPolicy&   tp = opts.tls_policy.value_or(tls_policy_);
    
            ParsedUrl pu = parse_url(url);
    
            TransportError last_err;

            const auto total_deadline =
                (eff_to.total_sec > 0.0)
                ? std::optional<std::chrono::steady_clock::time_point>(
                      std::chrono::steady_clock::now()
                    + duration_from_seconds(eff_to.total_sec))
                : std::nullopt;
    
            for (int attempt = 0; attempt < rp.max_attempts; ++attempt) {
                if (total_deadline &&
                    std::chrono::steady_clock::now() >= *total_deadline)
                    throw TransportError::timeout("total timeout exceeded");

                opts.cancel_token.throw_if_cancelled();
    
                if (attempt > 0) {
                    double delay = std::min(
                        rp.initial_delay_sec * std::pow(rp.backoff_factor,
                                                        static_cast<double>(attempt - 1)),
                        rp.max_delay_sec);
                        
                    auto sleep_dur = std::chrono::duration<double>(
                        delay + jitter_factor_sample(delay, rp.jitter_factor));
                    
                    auto wake_at = std::chrono::steady_clock::now() + sleep_dur;
                    while (std::chrono::steady_clock::now() < wake_at) {
                        opts.cancel_token.throw_if_cancelled();
                        std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    }
                }
    
                try {
                    HttpResponse resp =
                        do_wire_request(method, pu, body, ct, opts, eff_to, tp);
    
                    if (rp.should_retry_status(resp.status) &&
                        attempt + 1 < rp.max_attempts) {
                        last_err = TransportError::remote(resp.status, resp.reason);
                        if (hooks_.on_retry) hooks_.on_retry(attempt, last_err);
                        if (opts.hooks && opts.hooks->on_retry)
                            opts.hooks->on_retry(attempt, last_err);
                        continue;
                    }
                    if (hooks_.on_complete)
                        hooks_.on_complete(TransportError{});
                    if (opts.hooks && opts.hooks->on_complete)
                        opts.hooks->on_complete(TransportError{});
                    return resp;
    
                } catch (TransportError& e) {
                    last_err = e;
                    bool is_idempotent =
                        (method == "GET"  || method == "HEAD"  ||
                         method == "PUT"  || method == "DELETE"||
                         method == "OPTIONS");
                    bool can_retry =
                        rp.should_retry_error(e) &&
                        (is_idempotent ||
                         rp.idempotency == IdempotencyClass::Force);
    
                    if (!can_retry || attempt + 1 >= rp.max_attempts) {
                        if (hooks_.on_complete) hooks_.on_complete(e);
                        if (opts.hooks && opts.hooks->on_complete)
                            opts.hooks->on_complete(e);
                        throw;
                    }
                    if (hooks_.on_retry) hooks_.on_retry(attempt, e);
                    if (opts.hooks && opts.hooks->on_retry)
                        opts.hooks->on_retry(attempt, e);
                }
            }
            throw last_err;  
        }
        
        HttpResponse do_wire_request(const std::string& method,
                                      const ParsedUrl&   pu,
                                      const std::string& body,
                                      const std::string& ct,
                                      const RequestOptions& opts,
                                      const TransportTimeouts& to,
                                      const TlsPolicy& tp) {
            //asio::io_context ioc;
            //auto endpoints = tcp::resolver(ioc).resolve(pu.host,
            //                                            std::to_string(pu.port));

            tcp::resolver::results_type endpoints;
            std::string cache_key = pu.host + ":" + std::to_string(pu.port);
            bool need_resolve = true;
            {
                std::lock_guard<std::mutex> lk(dns_cache_mtx_);
                auto it = dns_cache_.find(cache_key);
                if (it != dns_cache_.end() &&
                    std::chrono::steady_clock::now() < it->second.expires_at) {
                    endpoints = it->second.endpoints;
                    need_resolve = false;
                }
            }
            if (need_resolve) {
                auto new_endpoints = tcp::resolver(ioc_).resolve(pu.host,
                                                    std::to_string(pu.port));
                std::lock_guard<std::mutex> lk(dns_cache_mtx_);
                dns_cache_[cache_key] = DnsEntry{
                    new_endpoints,
                    std::chrono::steady_clock::now() + dns_ttl_seconds
                };
                endpoints = new_endpoints;
            }
                                                        
            http::request<http::string_body> req;
            req.method(http::string_to_verb(method));
            req.target(pu.path);
            req.version(11);
            req.set(http::field::host, pu.host + ":" + std::to_string(pu.port));
            
            apply_header_list(req, persistent_headers_);
            apply_header_list(req, opts.headers);
            apply_user_agent_rule(req, opts.user_agent, user_agent_);
            
            if (!ct.empty()) req.set(http::field::content_type, ct);
            
            std::string cookie_hdr =
                cookie_jar_->cookie_header(pu.host, pu.path, pu.tls);
            for (const auto& [k, v] : opts.extra_cookies) {
                if (!cookie_hdr.empty()) cookie_hdr += "; ";
                cookie_hdr += k + "=" + v;
            }
            if (!cookie_hdr.empty())
                req.set(http::field::cookie, cookie_hdr);
    
            req.set(http::field::connection, "close");
            
            if (opts.upload_chunk_cb) {
                req.chunked(true);
                std::string upload;
                std::vector<char> chunk(opts.upload_chunk_size);
                while (true) {
                    size_t n = opts.upload_chunk_cb(chunk.data(), chunk.size());
                    if (n == 0) break;
                    upload.append(chunk.data(), n);
                }
                req.body() = std::move(upload);
            } else if (!body.empty()) {
                req.body() = body;
            }
            req.prepare_payload();

            HeaderList wire_extra;
            if (hooks_.on_before_request) {
                hooks_.on_before_request(wire_extra);
                apply_header_list(req, wire_extra);
            }
            if (opts.hooks && opts.hooks->on_before_request) {
                wire_extra.clear();
                opts.hooks->on_before_request(wire_extra);
                apply_header_list(req, wire_extra);
            }
                
            auto read_response = [&](auto& stream) -> HttpResponse {
                opts.cancel_token.throw_if_cancelled();
                beast::flat_buffer fb;
    
                if (opts.body_chunk_cb ||
                    (opts.hooks && opts.hooks->on_body_chunk)) {

                    http::response_parser<http::buffer_body> parser;
                    parser.body_limit(std::numeric_limits<uint64_t>::max());
                    beast::get_lowest_layer(stream)
                        .expires_after(to.read_dur());
                    http::read_header(stream, fb, parser);
    
                    HttpResponse resp;
                    resp.status = static_cast<int>(parser.get().result_int());
                    resp.reason = std::string(parser.get().reason());
                    for (const auto& f : parser.get())
                        resp.headers.emplace_back(std::string(f.name_string()),
                                                  std::string(f.value()));
    
                    if (hooks_.on_response_header)
                        hooks_.on_response_header(resp.status, resp.headers);
                    if (opts.hooks && opts.hooks->on_response_header)
                        opts.hooks->on_response_header(resp.status, resp.headers);
    
                    std::array<char, 65536> buf;
                    while (!parser.is_done()) {
                        opts.cancel_token.throw_if_cancelled();
                        parser.get().body().data = buf.data();
                        parser.get().body().size = buf.size();
                        boost::system::error_code ec;
                        beast::get_lowest_layer(stream).expires_after(to.body_dur());
                        http::read(stream, fb, parser, ec);
                        if (ec && ec != http::error::need_buffer) {
                            if (ec == asio::error::timed_out)
                                throw TransportError::timeout(pu.host);
                            throw TransportError(ec.message(),
                                                 TransportErrorKind::Local,
                                                 ec.value());
                        }
                        size_t used = buf.size() - parser.get().body().size;
                        if (used > 0) {
                            resp.bytes_received += used;
                            bool cont = true;
                            if (opts.body_chunk_cb)
                                cont = opts.body_chunk_cb(buf.data(), used);
                            if (cont && opts.hooks && opts.hooks->on_body_chunk)
                                cont = opts.hooks->on_body_chunk(buf.data(), used);
                            if (!cont) throw TransportError(
                                "body stream aborted by callback",
                                TransportErrorKind::Cancelled);
                        }
                    }
                    return resp;
                } else {
                    http::response<http::dynamic_body> res;
                    beast::get_lowest_layer(stream).expires_after(to.read_dur());
                    http::read(stream, fb, res);
    
                    HttpResponse resp;
                    resp.status = static_cast<int>(res.result_int());
                    resp.reason = std::string(res.reason());
                    resp.body   = beast::buffers_to_string(res.body().data());
                    resp.bytes_received = resp.body.size();
                    for (const auto& f : res)
                        resp.headers.emplace_back(std::string(f.name_string()),
                                                  std::string(f.value()));
    
                    if (hooks_.on_response_header)
                        hooks_.on_response_header(resp.status, resp.headers);
                    if (opts.hooks && opts.hooks->on_response_header)
                        opts.hooks->on_response_header(resp.status, resp.headers);
                    return resp;
                }
            };
    
            try {
                if (pu.tls) {
                    ssl::context ctx = create_ssl_context(tp);
                    beast::ssl_stream<beast::tcp_stream> stream(ioc_, ctx);
                    if (tp.verify_hostname)
                        SSL_set_tlsext_host_name(stream.native_handle(),
                                                 pu.host.c_str());
                    beast::get_lowest_layer(stream).expires_after(to.connect_dur());
                    opts.cancel_token.throw_if_cancelled();
                    beast::get_lowest_layer(stream).connect(endpoints);
                    beast::get_lowest_layer(stream).socket().set_option(tcp::no_delay(true));
                    beast::get_lowest_layer(stream).expires_after(to.tls_dur());
                    stream.handshake(ssl::stream_base::client);
                    
                    const unsigned char* proto = nullptr;
                    unsigned int proto_len = 0;
                    SSL_get0_alpn_selected(stream.native_handle(), &proto, &proto_len);
    
                    http::write(stream, req);
                    auto resp = read_response(stream);
                    if (proto && proto_len == 2 &&
                        memcmp(proto, "h2", 2) == 0) resp.http2 = true;
                    boost::system::error_code ec;
                    std::string conn_resp = resp.header("Connection");
                    for (char& c : conn_resp) c = static_cast<char>(std::tolower((unsigned char)c));
                    if (conn_resp != "close") {
                        struct linger lg{1, 0};
                        setsockopt(beast::get_lowest_layer(stream).socket().native_handle(),
                                   SOL_SOCKET, SO_LINGER, &lg, sizeof(lg));
                    }
                    beast::get_lowest_layer(stream).socket().shutdown(tcp::socket::shutdown_both, ec);
                    stream.shutdown(ec);
                    return resp;
                } else {
                    beast::tcp_stream stream(ioc_);
                    stream.expires_after(to.connect_dur());
                    opts.cancel_token.throw_if_cancelled();
                    stream.connect(endpoints);
                    stream.socket().set_option(tcp::no_delay(true));
                    http::write(stream, req);
                    auto resp = read_response(stream);
                    boost::system::error_code ec;
                    std::string conn_resp = resp.header("Connection");
                    for (char& c : conn_resp) c = static_cast<char>(std::tolower((unsigned char)c));
                    if (conn_resp != "close") {
                        struct linger lg{1, 0};
                        setsockopt(stream.socket().native_handle(), SOL_SOCKET,
                                   SO_LINGER, &lg, sizeof(lg));
                    }
                    stream.socket().shutdown(tcp::socket::shutdown_both, ec);
                    return resp;
                }
            } catch (const boost::system::system_error& se) {
                if (se.code() == asio::error::timed_out)
                    throw TransportError::timeout(pu.host);
                throw TransportError(se.what(), TransportErrorKind::Connect,
                                     se.code().value());
            }
        }
    
        TlsPolicy           tls_policy_;
        RetryPolicy         retry_policy_;
        KeepAliveConfig     ka_cfg_;
        TransportHooks      hooks_;
        HeaderList          persistent_headers_;
        std::string         user_agent_;
        TransportTimeouts   timeouts_;
        int                 max_redirects_;
        std::shared_ptr<CookieJar> cookie_jar_;
        mutable std::mutex                          dns_cache_mtx_;
        std::unordered_map<std::string, DnsEntry>   dns_cache_;
        mutable asio::io_context                    ioc_;
        static constexpr auto dns_ttl_seconds = std::chrono::seconds(300);
};

//************************************************************************************************
//********************************    HTTP SESSION    ********************************************
//************************************************************************************************


class HttpSession {
    public:
        HttpSession(std::string         host,
                    uint16_t            port,
                    std::string         base_path           = "/",
                    std::string         default_content_type = "application/json",
                    HeaderList          persistent_headers  = {},
                    std::string         user_agent          = "CykitTransport/1.0",
                    bool                use_tls             = true,
                    TransportTimeouts   timeouts            = {},
                    TlsPolicy           tls_policy          = {},
                    RetryPolicy         retry_policy        = {},
                    KeepAliveConfig     ka_cfg              = {},
                    TransportHooks      hooks               = {},
                    int                 max_redirects       = 10,
                    std::shared_ptr<CookieJar> cookie_jar  = nullptr)
            : host_(std::move(host))
            , port_(port)
            , base_path_(std::move(base_path))
            , default_ct_(std::move(default_content_type))
            , persistent_headers_(std::move(persistent_headers))
            , user_agent_(std::move(user_agent))
            , use_tls_(use_tls)
            , timeouts_(std::move(timeouts))
            , tls_policy_(std::move(tls_policy))
            , retry_policy_(std::move(retry_policy))
            , ka_cfg_(std::move(ka_cfg))
            , hooks_(std::move(hooks))
            , max_redirects_(max_redirects)
            , cookie_jar_(cookie_jar
                          ? std::move(cookie_jar)
                          : std::make_shared<CookieJar>())
            , ioc_()
            , ssl_ctx_(create_ssl_context(tls_policy_))
            , request_count_(0)
            , connect_time_(std::chrono::steady_clock::now()) {
            reconnect();
        }
    
        ~HttpSession() {
            force_close();   
            disconnect();    
        }
    
        HttpSession(const HttpSession&)            = delete;
        HttpSession& operator=(const HttpSession&) = delete;
        HttpSession(HttpSession&&)                 = delete;
        HttpSession& operator=(HttpSession&&)      = delete;
        
        CookieJar&       cookie_jar()       noexcept { return *cookie_jar_; }
        const CookieJar& cookie_jar() const noexcept { return *cookie_jar_; }
        HeaderList&       persistent_headers()       noexcept { return persistent_headers_; }
        const HeaderList& persistent_headers() const noexcept { return persistent_headers_; }
        
        HttpResponse get(const std::string& path, RequestOptions opts = {}) {
            return do_request(http::verb::get, path, {}, {}, std::move(opts));
        }
        HttpResponse post(const std::string& path, const std::string& body,
                          const std::string& ct = {}, RequestOptions opts = {}) {
            return do_request(http::verb::post, path, ct, body, std::move(opts));
        }
        HttpResponse put(const std::string& path, const std::string& body,
                         const std::string& ct = {}, RequestOptions opts = {}) {
            return do_request(http::verb::put, path, ct, body, std::move(opts));
        }
        HttpResponse patch(const std::string& path, const std::string& body,
                           const std::string& ct = {}, RequestOptions opts = {}) {
            return do_request(http::verb::patch, path, ct, body, std::move(opts));
        }
        HttpResponse del(const std::string& path, RequestOptions opts = {}) {
            return do_request(http::verb::delete_, path, {}, {}, std::move(opts));
        }
        HttpResponse head(const std::string& path, RequestOptions opts = {}) {
            return do_request(http::verb::head, path, {}, {}, std::move(opts));
        }
        HttpResponse options(const std::string& path, RequestOptions opts = {}) {
            return do_request(http::verb::options, path, {}, {}, std::move(opts));
        }
    
        void reconnect() {
            std::unique_lock<std::shared_mutex> lk(stream_mtx_);
            disconnect_locked();
            auto endpoints = tcp::resolver(ioc_)
                                 .resolve(host_, std::to_string(port_));
                                 
            if (use_tls_) {
                tls_stream_.emplace(ioc_, ssl_ctx_);
                if (tls_policy_.verify_hostname)
                    SSL_set_tlsext_host_name(tls_stream_->native_handle(),
                                             host_.c_str());
                beast::get_lowest_layer(*tls_stream_).expires_after(timeouts_.connect_dur());
                beast::get_lowest_layer(*tls_stream_).connect(endpoints);
                beast::get_lowest_layer(*tls_stream_).expires_after(timeouts_.tls_dur());
                tls_stream_->handshake(ssl::stream_base::client);
                
                ka_cfg_.apply(static_cast<intptr_t>(
                    beast::get_lowest_layer(*tls_stream_)
                        .socket().native_handle()));
            } else {
                plain_stream_.emplace(ioc_);
                plain_stream_->expires_after(timeouts_.connect_dur());
                plain_stream_->connect(endpoints);
                ka_cfg_.apply(static_cast<intptr_t>(
                    plain_stream_->socket().native_handle()));
            }
            request_count_ = 0;
            connect_time_  = std::chrono::steady_clock::now();
        }
    
        void disconnect() {
            std::unique_lock<std::shared_mutex> lk(stream_mtx_);
            disconnect_locked();
        }

        void force_close() noexcept {
            boost::system::error_code ec;
            std::unique_lock<std::shared_mutex> lk(stream_mtx_);
            if (tls_stream_) {
                beast::get_lowest_layer(*tls_stream_).cancel();
                beast::get_lowest_layer(*tls_stream_).socket().close(ec);
            }
            if (plain_stream_) {
                plain_stream_->cancel();
                plain_stream_->socket().close(ec);
            }
        }
    
    private:
        void disconnect_locked() noexcept {
            boost::system::error_code ec;
            if (tls_stream_) {
                beast::get_lowest_layer(*tls_stream_).cancel();
                beast::get_lowest_layer(*tls_stream_).socket().close(ec);
                tls_stream_.reset();
            }
            if (plain_stream_) {
                plain_stream_->cancel();
                plain_stream_->socket().close(ec);
                plain_stream_.reset();
            }
        }
    
        bool needs_reconnect() const noexcept {
            if (request_count_ >= static_cast<unsigned>(ka_cfg_.max_requests))
                return true;
            double max_age = (timeouts_.pool_idle_sec > 0.0)
                           ? timeouts_.pool_idle_sec
                           : ka_cfg_.max_age_sec;
            auto age = std::chrono::steady_clock::now() - connect_time_;
            return std::chrono::duration<double>(age).count() >= max_age;
        }
        
        HttpResponse do_request(http::verb        verb,
                                 const std::string& path,
                                 const std::string& content_type,
                                 const std::string& body,
                                 RequestOptions     opts) {
            const RetryPolicy& rp = opts.retry_policy.value_or(retry_policy_);
            const TransportTimeouts eff_to = (opts.timeout_sec > 0.0)
                                            ? TransportTimeouts(opts.timeout_sec)
                                            : (opts.timeouts.read_sec > 0.0 ? opts.timeouts : timeouts_);
    
            std::string target = base_path_;
            if (!path.empty()) {
                if (path[0] != '/' && !base_path_.empty() && base_path_.back() != '/')
                    target += '/';
                target += path;
            }
    
            http::request<http::string_body> req;
            req.method(verb);
            req.target(target);
            req.version(11);
            req.set(http::field::host, host_ + ":" + std::to_string(port_));
            
            apply_header_list(req, persistent_headers_);
            apply_header_list(req, opts.headers);
            apply_user_agent_rule(req, opts.user_agent, user_agent_);
            
            std::string ct = content_type.empty() ? default_ct_ : content_type;
            if (verb != http::verb::get && verb != http::verb::head &&
                verb != http::verb::options && verb != http::verb::delete_)
                req.set(http::field::content_type, ct);
                
            std::string cookie_hdr =
                cookie_jar_->cookie_header(host_, target, use_tls_);
            for (const auto& [k, v] : opts.extra_cookies) {
                if (!cookie_hdr.empty()) cookie_hdr += "; ";
                cookie_hdr += k + "=" + v;
            }
            if (!cookie_hdr.empty())
                req.set(http::field::cookie, cookie_hdr);
    
            req.set(http::field::connection, "keep-alive");

            const bool use_expect_continue =
                opts.expect_continue_threshold > 0 &&
                (verb == http::verb::post || verb == http::verb::put ||
                 verb == http::verb::patch) &&
                body.size() >= opts.expect_continue_threshold;
            if (use_expect_continue)
                req.set(http::field::expect, "100-continue");
            
            if (opts.upload_chunk_cb) {
                std::string upload;
                std::vector<char> chunk(opts.upload_chunk_size);
                while (true) {
                    size_t n = opts.upload_chunk_cb(chunk.data(), chunk.size());
                    if (n == 0) break;
                    upload.append(chunk.data(), n);
                }
                req.body() = std::move(upload);
            } else if (!body.empty()) {
                req.body() = body;
            }
            req.prepare_payload();
            
            HeaderList wire_extra;
            if (hooks_.on_before_request) {
                hooks_.on_before_request(wire_extra);
                apply_header_list(req, wire_extra);
            }
            if (opts.hooks && opts.hooks->on_before_request) {
                wire_extra.clear();
                opts.hooks->on_before_request(wire_extra);
                apply_header_list(req, wire_extra);
            }
    
            TransportError last_err;

            const auto total_deadline =
                (eff_to.total_sec > 0.0)
                ? std::optional<std::chrono::steady_clock::time_point>(
                      std::chrono::steady_clock::now()
                    + duration_from_seconds(eff_to.total_sec))
                : std::nullopt;
    
            for (int attempt = 0; attempt < rp.max_attempts; ++attempt) {
                if (total_deadline &&
                    std::chrono::steady_clock::now() >= *total_deadline)
                    throw TransportError::timeout("total timeout exceeded");

                opts.cancel_token.throw_if_cancelled();
    
                if (attempt > 0) {
                    double delay = std::min(
                        rp.initial_delay_sec * std::pow(rp.backoff_factor,
                                                        static_cast<double>(attempt - 1)),
                        rp.max_delay_sec);
                    auto wake_at = std::chrono::steady_clock::now()
                                 + std::chrono::duration<double>(
                                       delay + jitter_factor_sample(
                                                   delay, rp.jitter_factor));
                    while (std::chrono::steady_clock::now() < wake_at) {
                        opts.cancel_token.throw_if_cancelled();
                        std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    }
                }
    
                try {
                    std::unique_lock<std::shared_mutex> lk(stream_mtx_);
                    if (!plain_stream_ && !tls_stream_) {
                        lk.unlock(); reconnect(); lk.lock();
                    }
                    if (needs_reconnect()) {
                        disconnect_locked();
                        lk.unlock(); reconnect(); lk.lock();
                    }
    
                    HttpResponse resp = send_recv_locked(req, opts, eff_to, use_expect_continue);
                    ++request_count_;
                    
                    for (const auto& sc : resp.header_all("Set-Cookie"))
                        cookie_jar_->parse_and_insert(sc, host_, target);
    
                    if (rp.should_retry_status(resp.status) &&
                        attempt + 1 < rp.max_attempts) {
                        last_err = TransportError::remote(resp.status, resp.reason);
                        if (hooks_.on_retry) hooks_.on_retry(attempt, last_err);
                        continue;
                    }
    
                    if (hooks_.on_complete)
                        hooks_.on_complete(TransportError{});
                    if (opts.hooks && opts.hooks->on_complete)
                        opts.hooks->on_complete(TransportError{});
                        
                    int max_redir = (opts.max_redirects >= 0)
                                  ? opts.max_redirects : max_redirects_;
                    if (resp.is_redirect() && attempt < max_redir) {
                        std::string loc = resp.location();
                        if (!loc.empty() && loc[0] == '/') {
                            RequestOptions redir_opts = opts;

                            redir_opts.headers.erase(
                                std::remove_if(
                                    redir_opts.headers.begin(),
                                    redir_opts.headers.end(),
                                    [](const std::pair<std::string,std::string>& h) {
                                        std::string k = h.first;
                                        for (char& c : k)
                                            c = static_cast<char>(
                                                std::tolower((unsigned char)c));
                                        return k == "authorization";
                                    }),
                                redir_opts.headers.end());
                            return do_request(
                                resp.status == 303 ? http::verb::get : verb,
                                loc, content_type,
                                resp.status == 303 ? "" : body,
                                std::move(redir_opts));
                        }
                        
                    }
    
                    return resp;
    
                } catch (const boost::system::system_error& se) {
                    const auto ec = se.code();
                    const bool peer_closed =
                        (ec == asio::error::connection_reset ||
                         ec == asio::error::broken_pipe      ||
                         ec == boost::beast::http::error::end_of_stream ||
                         ec == asio::error::eof);
    
                    last_err = TransportError(
                        se.what(),
                        peer_closed ? TransportErrorKind::Local  
                                    : TransportErrorKind::Connect,
                        ec.value());
    
                    disconnect_locked();
    
                    if (!rp.should_retry_error(last_err) ||
                        attempt + 1 >= rp.max_attempts) {
                        if (hooks_.on_complete) hooks_.on_complete(last_err);
                        throw last_err;
                    }
                    if (hooks_.on_retry) hooks_.on_retry(attempt, last_err);
    
                } catch (TransportError& e) {
                    last_err = e;
                    if (!rp.should_retry_error(e) ||
                        attempt + 1 >= rp.max_attempts) {
                        if (hooks_.on_complete) hooks_.on_complete(e);
                        throw;
                    }
                    if (hooks_.on_retry) hooks_.on_retry(attempt, e);
                }
            }
            throw last_err;
        }
        
        HttpResponse send_recv_locked(const http::request<http::string_body>& req,
                                                        const RequestOptions& opts,
                                                        const TransportTimeouts& to,
                                                        bool use_expect_continue = false) {
            auto do_io = [&](auto& stream) -> HttpResponse {
                opts.cancel_token.throw_if_cancelled();
                beast::flat_buffer fb;
    
                if (opts.body_chunk_cb ||
                    (opts.hooks && opts.hooks->on_body_chunk)) {
                    beast::get_lowest_layer(stream).expires_after(to.write_dur());
                    http::write(stream, req);
    
                    http::response_parser<http::buffer_body> parser;
                    parser.body_limit(std::numeric_limits<uint64_t>::max());
                    beast::get_lowest_layer(stream).expires_after(to.read_dur());
                    http::read_header(stream, fb, parser);
    
                    HttpResponse resp;
                    resp.status = static_cast<int>(parser.get().result_int());
                    resp.reason = std::string(parser.get().reason());
                    for (const auto& f : parser.get())
                        resp.headers.emplace_back(std::string(f.name_string()),
                                                  std::string(f.value()));
                    if (hooks_.on_response_header)
                        hooks_.on_response_header(resp.status, resp.headers);
                    if (opts.hooks && opts.hooks->on_response_header)
                        opts.hooks->on_response_header(resp.status, resp.headers);
    
                    std::array<char, 65536> buf;
                    while (!parser.is_done()) {
                        opts.cancel_token.throw_if_cancelled();
                        parser.get().body().data = buf.data();
                        parser.get().body().size = buf.size();
                        boost::system::error_code ec;
                        beast::get_lowest_layer(stream).expires_after(to.body_dur());
                        http::read(stream, fb, parser, ec);
                        if (ec && ec != http::error::need_buffer) {
                            if (ec == asio::error::timed_out)
                                throw TransportError::timeout(host_);
                            throw TransportError(ec.message(),
                                                 TransportErrorKind::Local,
                                                 ec.value());
                        }
                        size_t used = buf.size() - parser.get().body().size;
                        if (used > 0) {
                            resp.bytes_received += used;
                            bool cont = true;
                            if (opts.body_chunk_cb)
                                cont = opts.body_chunk_cb(buf.data(), used);
                            if (cont && opts.hooks && opts.hooks->on_body_chunk)
                                cont = opts.hooks->on_body_chunk(buf.data(), used);
                            if (!cont) throw TransportError(
                                "body stream aborted by callback",
                                TransportErrorKind::Cancelled);
                        }
                    }
                    return resp;
                } else {
                    if (use_expect_continue && !req.body().empty()) {
                        http::serializer<true, http::string_body> sr(req);

                        beast::get_lowest_layer(stream).expires_after(to.write_dur());
                        boost::system::error_code ech;
                        http::write_header(stream, sr, ech);
                        if (ech) throw TransportError(ech.message(),
                                                      TransportErrorKind::Local,
                                                      ech.value());
                                                      
                        beast::get_lowest_layer(stream).expires_after(to.read_dur());
                        http::response<http::dynamic_body> interim;
                        boost::system::error_code ec100;
                        http::read(stream, fb, interim, ec100);

                        if (!ec100 && interim.result_int() == 100) {
                            beast::get_lowest_layer(stream).expires_after(
                                to.write_dur());
                            boost::system::error_code ecb;
                            
                            http::write(stream, sr, ecb);
                            if (ecb) throw TransportError(ecb.message(),
                                                          TransportErrorKind::Local,
                                                          ecb.value());
                        } else if (!ec100) {
                            HttpResponse resp;
                            resp.status = static_cast<int>(interim.result_int());
                            resp.reason = std::string(interim.reason());
                            resp.body   = beast::buffers_to_string(
                                              interim.body().data());
                            for (const auto& f : interim)
                                resp.headers.emplace_back(
                                    std::string(f.name_string()),
                                    std::string(f.value()));
                            return resp;
                        }
                        
                    } else {
                        beast::get_lowest_layer(stream).expires_after(to.write_dur());
                        http::write(stream, req);
                    }

                    http::response<http::dynamic_body> res;
                    beast::get_lowest_layer(stream).expires_after(to.read_dur());
                    http::read(stream, fb, res);
    
                    HttpResponse resp;
                    resp.status = static_cast<int>(res.result_int());
                    resp.reason = std::string(res.reason());
                    resp.body   = beast::buffers_to_string(res.body().data());
                    resp.bytes_received = resp.body.size();
                    for (const auto& f : res)
                        resp.headers.emplace_back(std::string(f.name_string()),
                                                  std::string(f.value()));
                    if (hooks_.on_response_header)
                        hooks_.on_response_header(resp.status, resp.headers);
                    if (opts.hooks && opts.hooks->on_response_header)
                        opts.hooks->on_response_header(resp.status, resp.headers);
                    return resp;
                }
            };
    
            if (use_tls_) return do_io(*tls_stream_);
            return do_io(*plain_stream_);
        }
        
        std::string         host_;
        uint16_t            port_;
        std::string         base_path_;
        std::string         default_ct_;
        HeaderList          persistent_headers_;
        std::string         user_agent_;
        bool                use_tls_;
        TransportTimeouts   timeouts_;
        TlsPolicy           tls_policy_;
        RetryPolicy         retry_policy_;
        KeepAliveConfig     ka_cfg_;
        TransportHooks      hooks_;
        int                 max_redirects_;
        std::shared_ptr<CookieJar> cookie_jar_;
    
        asio::io_context    ioc_;
        ssl::context        ssl_ctx_;
    
        mutable std::shared_mutex stream_mtx_;  
        std::optional<beast::ssl_stream<beast::tcp_stream>> tls_stream_;
        std::optional<beast::tcp_stream>                    plain_stream_;
    
        unsigned int        request_count_;
        std::chrono::steady_clock::time_point connect_time_;
};


//************************************************************************************************
//************************************    SMTP    ************************************************
//************************************************************************************************


enum class SmtpAuth : uint8_t {
    None        = 0,
    Plain       = 1,  
    Login       = 2,  
    XOAuth2     = 3,  
};

struct OAuth2Config {
    std::string client_id;
    std::string client_secret;
    std::string refresh_token;
    
    std::function<std::string()> token_provider;
    
    static std::string build_xoauth2_payload(const std::string& user,
                                              const std::string& token) {
        std::string raw = "user=" + user + "\x01"
                        + "auth=Bearer " + token + "\x01\x01";
        return base64_encode(raw);
    }

    void set_refresh_provider(const std::string& token_endpoint) {
        token_provider = [cid  = client_id,
                          csec = client_secret,
                          rtok = refresh_token,
                          ep   = token_endpoint]() -> std::string {
            HttpClient hc;
            auto r = hc.post(
                ep,
                "client_id="      + cid  +
                "&client_secret=" + csec +
                "&refresh_token=" + rtok +
                "&grant_type=refresh_token",
                "application/x-www-form-urlencoded",
                RequestOptions{});
            if (!r.ok()) return {};
            
            auto pos = r.body.find("\"access_token\"");
            if (pos == std::string::npos) return {};
            
            pos = r.body.find('"', pos + 14);  
            if (pos == std::string::npos) return {};
            auto end = r.body.find('"', pos + 1);
            if (end == std::string::npos) return {};
            return r.body.substr(pos + 1, end - pos - 1);
        };
    }
};


struct SmtpCapabilities {
    bool starttls    = false;
    bool pipelining  = false;
    bool eight_bit   = false;  
    bool smtputf8    = false;  
    bool dsn         = false;  
    size_t max_size  = 0;   
    
    std::set<std::string> auth_mechanisms;

    bool supports_auth(const std::string& mech) const {
        return auth_mechanisms.count(mech) > 0;
    }
};

enum class SmtpErrorClass : uint8_t {
    None        = 0,
    Transient   = 1,  
    Permanent   = 2,  
    ServiceDown = 3,  
};

inline SmtpErrorClass classify_smtp_code(int code) noexcept {
    if (code <= 0)   return SmtpErrorClass::Transient;
    if (code == 421) return SmtpErrorClass::ServiceDown;
    if (code >= 500) return SmtpErrorClass::Permanent;
    if (code >= 400) return SmtpErrorClass::Transient;
    return SmtpErrorClass::None;
}

struct SmtpSendResult {
    bool            ok           = false;
    int             smtp_code    = 0;    
    std::string     smtp_message;        
    SmtpErrorClass  error_class  = SmtpErrorClass::None;
    int             attempts     = 0;
    
    bool should_retry() const noexcept {
        return error_class == SmtpErrorClass::Transient ||
               error_class == SmtpErrorClass::ServiceDown;
    }
    
    bool is_permanent_failure() const noexcept {
        return error_class == SmtpErrorClass::Permanent;
    }

    explicit operator bool() const noexcept { return ok; }
};

class SmtpMessage {
public:
    SmtpMessage& set_from(const std::string& from) { from_ = from; return *this; }
    SmtpMessage& add_to(const std::string& to) { to_.push_back(to); return *this; }
    SmtpMessage& add_cc(const std::string& cc) { cc_.push_back(cc); return *this; }
    SmtpMessage& add_bcc(const std::string& bcc) { bcc_.push_back(bcc); return *this; }
    SmtpMessage& set_reply_to(const std::string& reply_to) { reply_to_ = reply_to; return *this; }
    SmtpMessage& set_subject(const std::string& subject) { subject_ = subject; return *this; }
    SmtpMessage& set_body_text(const std::string& text) { body_text_ = text; return *this; }
    SmtpMessage& set_body_html(const std::string& html) { body_html_ = html; return *this; }
    SmtpMessage& add_attachment(const std::string& name, const std::string& base64_data) {
        attachments_.emplace_back(name, base64_data);
        return *this;
    }

    SmtpMessage& set_dsn_ret(const std::string& ret) {
        dsn_ret_ = ret; return *this;
    }
    
    SmtpMessage& set_dsn_notify(const std::string& notify) {
        dsn_notify_ = notify; return *this;
    }
    
    SmtpMessage& set_envid(const std::string& envid) {
        envid_ = envid; return *this;
    }

    const std::string& dsn_ret()    const { return dsn_ret_; }
    const std::string& dsn_notify() const { return dsn_notify_; }
    const std::string& envid()      const { return envid_; }

    static std::string make_boundary() {
        thread_local std::mt19937_64 gen{std::random_device{}()};
        std::uniform_int_distribution<uint64_t> dist;
        char buf[64];
        snprintf(buf, sizeof(buf), "----=_Part_%016llx_%016llx",
                 static_cast<unsigned long long>(dist(gen)),
                 static_cast<unsigned long long>(dist(gen)));
        return std::string(buf);
    }

    static std::string normalize_crlf(const std::string& s) {
        std::string out;
        out.reserve(s.size() + 64);
        for (size_t i = 0; i < s.size(); ++i) {
            if (s[i] == '\n' && (i == 0 || s[i-1] != '\r'))
                out += '\r';
            out += s[i];
        }
        return out;
    }

    std::string build() const {
        bool has_html = !body_html_.empty();
        bool has_att  = !attachments_.empty();

        const std::string boundary     = make_boundary();
        const std::string alt_boundary = make_boundary();  

        auto join = [](const std::vector<std::string>& v) {
            std::string r;
            for (size_t i = 0; i < v.size(); ++i) { if (i) r += ", "; r += v[i]; }
            return r;
        };

        std::ostringstream m;
        
        m << "From: "         << from_    << "\r\n"
          << "To: "           << join(to_)<< "\r\n";
        if (!cc_.empty())
            m << "Cc: "       << join(cc_)<< "\r\n";
        if (!reply_to_.empty())
            m << "Reply-To: " << reply_to_<< "\r\n";
        m << "Subject: "      << subject_ << "\r\n"
          << "MIME-Version: 1.0\r\n"
          << "X-Mailer: CykitTransport/1.0\r\n";
          
        const std::string plain = normalize_crlf(body_text_);
        const std::string html  = normalize_crlf(body_html_);

        if (!has_html && !has_att) {
            m << "Content-Type: text/plain; charset=utf-8\r\n"
              << "Content-Transfer-Encoding: 8bit\r\n"
              << "\r\n"
              << plain << "\r\n";

        } else if (has_html && !has_att) {
            m << "Content-Type: multipart/alternative;\r\n"
              << "\tboundary=\"" << boundary << "\"\r\n"
              << "\r\n"
              << "--" << boundary << "\r\n"
              << "Content-Type: text/plain; charset=utf-8\r\n"
              << "Content-Transfer-Encoding: 8bit\r\n"
              << "\r\n"
              << plain << "\r\n"
              << "--" << boundary << "\r\n"
              << "Content-Type: text/html; charset=utf-8\r\n"
              << "Content-Transfer-Encoding: 8bit\r\n"
              << "\r\n"
              << html << "\r\n"
              << "--" << boundary << "--\r\n";

        } else {
            m << "Content-Type: multipart/mixed;\r\n"
              << "\tboundary=\"" << boundary << "\"\r\n"
              << "\r\n";

            if (has_html) {
                m << "--" << boundary << "\r\n"
                  << "Content-Type: multipart/alternative;\r\n"
                  << "\tboundary=\"" << alt_boundary << "\"\r\n"
                  << "\r\n"
                  << "--" << alt_boundary << "\r\n"
                  << "Content-Type: text/plain; charset=utf-8\r\n"
                  << "Content-Transfer-Encoding: 8bit\r\n"
                  << "\r\n"
                  << plain << "\r\n"
                  << "--" << alt_boundary << "\r\n"
                  << "Content-Type: text/html; charset=utf-8\r\n"
                  << "Content-Transfer-Encoding: 8bit\r\n"
                  << "\r\n"
                  << html << "\r\n"
                  << "--" << alt_boundary << "--\r\n";
            } else {
                m << "--" << boundary << "\r\n"
                  << "Content-Type: text/plain; charset=utf-8\r\n"
                  << "Content-Transfer-Encoding: 8bit\r\n"
                  << "\r\n"
                  << plain << "\r\n";
            }
            
            for (const auto& att : attachments_) {
                m << "--" << boundary << "\r\n"
                  << "Content-Type: application/octet-stream\r\n"
                  << "Content-Transfer-Encoding: base64\r\n"
                  << "Content-Disposition: attachment;\r\n"
                  << "\tfilename=\"" << att.first << "\"\r\n"
                  << "\r\n"
                  << att.second << "\r\n";
            }
            m << "--" << boundary << "--\r\n";
        }
        return m.str();
    }

    const std::string& from() const { return from_; }
    const std::vector<std::string>& to() const { return to_; }
    const std::vector<std::string>& cc() const { return cc_; }
    const std::vector<std::string>& bcc() const { return bcc_; }

private:
    std::string from_;
    std::vector<std::string> to_, cc_, bcc_;
    std::string reply_to_, subject_, body_text_, body_html_;
    std::vector<std::pair<std::string, std::string>> attachments_;
    std::string dsn_ret_    = "FULL";
    std::string dsn_notify_ = "FAILURE,DELAY";
    std::string envid_;
};


enum class SmtpMode : uint8_t {
    Plain    = 0,  
    StartTls = 1,  
    Smtps    = 2,  
};

class SmtpClient {
    public:    
        SmtpClient(const std::string& host,
                   uint16_t           port,
                   const std::string& client_name       = "localhost",
                   const std::string& username           = "",
                   const std::string& password           = "",
                   SmtpMode           mode               = SmtpMode::StartTls,
                   SmtpAuth           auth_mech          = SmtpAuth::Login,
                   OAuth2Config       oauth2             = {},
                   int                max_send_attempts  = 3,
                   SmtpTimeouts       timeouts           = {})
            : host_(host), port_(port), client_name_(client_name)
            , username_(username), password_(password)
            , mode_(mode), auth_mech_(auth_mech)
            , oauth2_(std::move(oauth2))
            , max_send_attempts_(max_send_attempts)
            , timeouts_(std::move(timeouts))
            , ioc_()
            , ssl_ctx_(create_ssl_context([](){
                  TlsPolicy p;
                  p.verify_peer     = true;
                  p.verify_hostname = true;
                  p.min_tls_version = TLS1_2_VERSION;
                  return p;
              }())) {
            //connect_and_auth();
        }
    
    ~SmtpClient() {
        boost::system::error_code ec;
        if (plain_socket_ && plain_socket_->is_open()) {
            plain_socket_->cancel(ec);
            plain_socket_->shutdown(tcp::socket::shutdown_both, ec);
            plain_socket_->close(ec);
            plain_socket_.reset();
        }
        if (tls_stream_) {
            auto& sock = tls_stream_->lowest_layer(); 
            sock.cancel(ec);
            sock.shutdown(tcp::socket::shutdown_both, ec);
            sock.close(ec);
            tls_stream_.reset();
        }
    }

    SmtpClient(const SmtpClient&) = delete;
    SmtpClient& operator=(const SmtpClient&) = delete;
    SmtpClient(SmtpClient&& other) noexcept = delete;
    SmtpClient& operator=(SmtpClient&& other) noexcept = delete;

    SmtpSendResult send(const SmtpMessage& msg, bool close_after_send= false) {
        std::lock_guard<std::mutex> lk(send_mtx_);
        SmtpSendResult result;

        if ((tls_stream_ || plain_socket_) && !is_connected()) {
            disconnect();
        }

        if (!tls_stream_ && !plain_socket_) {
                try {
                    connect_and_auth();
                } catch (const std::exception& e) {
                    result.ok           = false;
                    result.smtp_code    = 0;
                    result.smtp_message = e.what();
                    result.error_class  = SmtpErrorClass::Transient;
                    return result;
                }
            }
            
        for (int attempt = 0; attempt < max_send_attempts_; ++attempt) {
            result.attempts = attempt + 1;
            try {
                needs_rset_ = true;
                result = send_to_stream(msg);
            } catch (const std::exception&) {
                needs_rset_ = false;
                try {
                    connect_and_auth();
                    result = send_to_stream(msg);
                } catch (const std::exception& e2) {
                    result.ok          = false;
                    result.smtp_code   = 0;
                    result.smtp_message= e2.what();
                    result.error_class = SmtpErrorClass::Transient;
                }
            }
            
            if (result.ok) {
                needs_rset_ = false;
                if (close_after_send) disconnect();
                return result;
            }
            if (result.is_permanent_failure())   return result; 
            if (!result.should_retry())          return result; 
            
            double delay = std::min(2.0 * std::pow(2.0, static_cast<double>(attempt)),
                                    30.0);
            std::this_thread::sleep_for(
                std::chrono::duration<double>(delay));
                
            if (result.smtp_code == 421) {
                try { connect_and_auth(); } catch (...) {}
            }
        }
        return result;
    }
    
    bool noop() { std::lock_guard<std::mutex> lk(send_mtx_); return command("NOOP\r\n").code == 250; }
    bool rset() { std::lock_guard<std::mutex> lk(send_mtx_); return command("RSET\r\n").code == 250; }

private:
    void disconnect() {
        boost::system::error_code ec;
        if (tls_stream_) {
            try { command("QUIT\r\n"); } catch (...) {}
            tls_stream_->shutdown(ec);
            tls_stream_.reset();
        }
        if (plain_socket_) {
            try { command("QUIT\r\n"); } catch (...) {}
            plain_socket_->shutdown(tcp::socket::shutdown_both, ec);
            plain_socket_.reset();
        }
    }

    void connect_and_auth() {
        disconnect();
        tcp::resolver resolver(ioc_);
        auto endpoints = resolver.resolve(host_, std::to_string(port_));

        if (mode_ == SmtpMode::Smtps) {
            tls_stream_.emplace(ioc_, ssl_ctx_);
            SSL_set_tlsext_host_name(tls_stream_->native_handle(), host_.c_str());
            asio::connect(tls_stream_->next_layer(), endpoints);
            tls_stream_->next_layer().set_option(boost::asio::socket_base::keep_alive(true));
            set_socket_timeout(tls_stream_->next_layer().native_handle(),
                               timeouts_.connect_sec);

            SET_SOCK_TIMEOUT(tls_stream_->next_layer().native_handle(), timeouts_.tls_sec);
            tls_stream_->handshake(ssl::stream_base::client);
            SET_SOCK_TIMEOUT(tls_stream_->next_layer().native_handle(), timeouts_.command_sec);

            drain_banner(*tls_stream_);
            caps_ = do_ehlo(*tls_stream_);
            do_auth(*tls_stream_);

        } else if (mode_ == SmtpMode::StartTls) {
            plain_socket_.emplace(ioc_);
            asio::connect(*plain_socket_, endpoints);
            plain_socket_->set_option(boost::asio::socket_base::keep_alive(true));
            SET_SOCK_TIMEOUT(plain_socket_->native_handle(), timeouts_.banner_sec);
            drain_banner(*plain_socket_);
            SET_SOCK_TIMEOUT(plain_socket_->native_handle(), timeouts_.command_sec);

            SmtpCapabilities pre_caps = do_ehlo(*plain_socket_);
            if (!pre_caps.starttls)
                throw TransportError(
                    "Server does not advertise STARTTLS — refusing plaintext SMTP",
                    TransportErrorKind::Tls);
                    
            auto r = command(*plain_socket_, "STARTTLS\r\n");
            if (r.code != 220)
                throw TransportError(
                    "STARTTLS rejected: " + r.text, TransportErrorKind::Tls);
                    
            tls_stream_.emplace(std::move(*plain_socket_), ssl_ctx_);
            plain_socket_.reset();
            SSL_set_tlsext_host_name(tls_stream_->native_handle(), host_.c_str());
            SET_SOCK_TIMEOUT(tls_stream_->next_layer().native_handle(),
                             timeouts_.tls_sec);
            tls_stream_->handshake(ssl::stream_base::client);
            SET_SOCK_TIMEOUT(tls_stream_->next_layer().native_handle(),
                             timeouts_.command_sec);
            
            caps_ = do_ehlo(*tls_stream_);
            do_auth(*tls_stream_);

        } else {
            plain_socket_.emplace(ioc_);
            asio::connect(*plain_socket_, endpoints);
            plain_socket_->set_option(boost::asio::socket_base::keep_alive(true));
            SET_SOCK_TIMEOUT(plain_socket_->native_handle(), timeouts_.banner_sec);
            drain_banner(*plain_socket_);
            SET_SOCK_TIMEOUT(plain_socket_->native_handle(), timeouts_.command_sec);
            caps_ = do_ehlo(*plain_socket_);
            do_auth(*plain_socket_);
        }
    }

    template<typename Stream>
    void drain_banner(Stream& stream) {
        std::string buf;
        boost::system::error_code ec;
        while (true) {
            asio::read_until(stream, asio::dynamic_buffer(buf), "\r\n", ec);
            if (ec) throw TransportError("SMTP banner read failed", TransportErrorKind::Protocol);
            std::string line = buf.substr(0, buf.find("\r\n") + 2);
            buf.erase(0, line.size());
            int code = std::stoi(line);
            if (code != 220)
                throw TransportError("Bad SMTP banner code", TransportErrorKind::Protocol);
            if (line.size() >= 4 && (line[3] == ' ' || line[3] == '\r' || line[3] == '\n'))
                break;
        }
    }

    template<typename Stream>
    SmtpCapabilities do_ehlo(Stream& stream) {
        auto r = command(stream, "EHLO " + client_name_ + "\r\n");
        if (r.code != 250) {
            r = command(stream, "HELO " + client_name_ + "\r\n");
            if (r.code != 250)
                throw TransportError("EHLO/HELO failed: " + r.text,
                                     TransportErrorKind::Protocol);
            return {};  
        }

        SmtpCapabilities caps;
        for (const auto& line : r.all_lines) {
            if (line.size() < 4) continue;
            std::string kw = line.substr(4);  
            std::string kwu = kw;
            for (char& c : kwu) c = static_cast<char>(
                                        std::toupper((unsigned char)c));

            if (kwu == "STARTTLS")        caps.starttls   = true;
            else if (kwu == "PIPELINING") caps.pipelining = true;
            else if (kwu == "8BITMIME")   caps.eight_bit  = true;
            else if (kwu == "SMTPUTF8")   caps.smtputf8   = true;
            else if (kwu == "DSN")        caps.dsn        = true;
            else if (kwu.substr(0, 5) == "SIZE ") {
                caps.max_size = static_cast<size_t>(
                    std::stoul(kwu.substr(5)));
            } else if (kwu.substr(0, 5) == "AUTH ") {
                std::istringstream ss(kw.substr(5));
                std::string mech;
                while (ss >> mech) {
                    for (char& c : mech) c = static_cast<char>(
                                                std::toupper((unsigned char)c));
                    caps.auth_mechanisms.insert(mech);
                }
            }
        }
        return caps;
    }

    template<typename Stream>
    void do_auth(Stream& stream) {
        if (auth_mech_ == SmtpAuth::None) return;
        if (username_.empty() && auth_mech_ != SmtpAuth::XOAuth2) return;

        if (auth_mech_ == SmtpAuth::XOAuth2) {
            if (!caps_.supports_auth("XOAUTH2"))
                throw TransportError(
                    "Server does not advertise AUTH XOAUTH2",
                    TransportErrorKind::Auth);
            if (!oauth2_.token_provider)
                throw TransportError(
                    "OAuth2Config.token_provider is not set",
                    TransportErrorKind::Auth);

            std::string token = oauth2_.token_provider();
            if (token.empty())
                throw TransportError("OAuth2 token_provider returned empty token",
                                     TransportErrorKind::Auth);

            std::string payload = OAuth2Config::build_xoauth2_payload(
                                      username_, token);
            auto r = command(stream, "AUTH XOAUTH2 " + payload + "\r\n");
            if (r.code != 235)
                throw TransportError(
                    "AUTH XOAUTH2 rejected (" + std::to_string(r.code)
                    + "): " + r.text, TransportErrorKind::Auth);

        } else if (auth_mech_ == SmtpAuth::Plain) {
            if (!caps_.supports_auth("PLAIN"))
                throw TransportError("Server does not advertise AUTH PLAIN",
                                     TransportErrorKind::Auth);
                                     
            std::string raw = '\0' + username_ + '\0' + password_;
            auto r = command(stream,
                "AUTH PLAIN " + base64_encode(raw) + "\r\n");
            if (r.code != 235)
                throw TransportError(
                    "AUTH PLAIN rejected (" + std::to_string(r.code)
                    + "): " + r.text, TransportErrorKind::Auth);

        } else {
            if (!caps_.supports_auth("LOGIN"))
                throw TransportError("Server does not advertise AUTH LOGIN",
                                     TransportErrorKind::Auth);
            auto r1 = command(stream, "AUTH LOGIN\r\n");
            if (r1.code != 334)
                throw TransportError(
                    "AUTH LOGIN rejected: " + r1.text, TransportErrorKind::Auth);
            auto r2 = command(stream, base64_encode(username_) + "\r\n");
            if (r2.code != 334)
                throw TransportError(
                    "AUTH LOGIN username rejected: " + r2.text,
                    TransportErrorKind::Auth);
            auto r3 = command(stream, base64_encode(password_) + "\r\n");
            if (r3.code != 235)
                throw TransportError(
                    "AUTH LOGIN password rejected (" + std::to_string(r3.code)
                    + "): " + r3.text, TransportErrorKind::Auth);
        }
    }

    struct SmtpResponse {
        int                      code = -1;
        std::string              text;        
        std::vector<std::string> all_lines;   

        operator int() const noexcept { return code; }
    };

    SmtpResponse command(const std::string& cmd) {
        if (tls_stream_)   return command(*tls_stream_, cmd);
        if (plain_socket_) return command(*plain_socket_, cmd);
        SmtpResponse r; r.code = -1; r.text = "not connected"; return r;
    }

    template<typename Stream>
    SmtpResponse command(Stream& stream, const std::string& cmd) {
        boost::system::error_code ec;
        if (!cmd.empty()) {
            asio::write(stream, asio::buffer(cmd), ec);
            if (ec) {
                SmtpResponse r; r.code = -1; r.text = ec.message(); return r;
            }
        }
        std::string buf;
        SmtpResponse resp;
        while (true) {
            asio::read_until(stream, asio::dynamic_buffer(buf), "\r\n", ec);
            if (ec) { resp.code = -1; resp.text = ec.message(); return resp; }

            size_t crlf = buf.find("\r\n");
            std::string line = buf.substr(0, crlf);
            buf.erase(0, crlf + 2);

            resp.all_lines.push_back(line);

            if (line.size() < 3) { resp.code = -1; return resp; }
            resp.code = std::stoi(line.substr(0, 3));
            
            if (line.size() == 3 || line[3] == ' ') {
                resp.text = (line.size() > 4) ? line.substr(4) : "";
                break;
            }
            
        }
        return resp;
    }

    SmtpSendResult send_to_stream(const SmtpMessage& msg) {
        
        if (needs_rset_) {
            auto r = command("RSET\r\n");
            if (r.code < 0) {
                connect_and_auth();
            }
            needs_rset_ = false;
        }
        
        std::string raw_msg = msg.build();

        if (caps_.max_size > 0 && raw_msg.size() > caps_.max_size)
            return make_result(552,
                "Message size " + std::to_string(raw_msg.size())
                + " exceeds server limit " + std::to_string(caps_.max_size));
                
        std::string escaped;
        escaped.reserve(raw_msg.size() + raw_msg.size() / 64 + 8);

        bool line_start = true;
        for (size_t i = 0; i < raw_msg.size(); ++i) {
            char c = raw_msg[i];
            if (line_start && c == '.')
                escaped += '.';  
            escaped += c;
            line_start = (c == '\n');
        }
        escaped += "\r\n.\r\n"; 
        
        std::string mail_from = "MAIL FROM:<" + msg.from() + ">";
        if (caps_.dsn) {
            if (!msg.dsn_ret().empty())
                mail_from += " RET=" + msg.dsn_ret();
            if (!msg.envid().empty())
                mail_from += " ENVID=" + msg.envid();
        }
        mail_from += "\r\n";

        if (caps_.pipelining) {
            std::string batch = mail_from;
            auto append_rcpts = [&](const std::vector<std::string>& addrs) {
                for (const auto& a : addrs) {
                    batch += "RCPT TO:<" + a + ">";
                    if (caps_.dsn && !msg.dsn_notify().empty())
                        batch += " NOTIFY=" + msg.dsn_notify();
                    batch += "\r\n";
                }
            };
            append_rcpts(msg.to());
            append_rcpts(msg.cc());
            append_rcpts(msg.bcc());
            batch += "DATA\r\n";
            
            boost::system::error_code wec;
            if (tls_stream_)
                asio::write(*tls_stream_, asio::buffer(batch), wec);
            else
                asio::write(*plain_socket_, asio::buffer(batch), wec);
            if (wec) return make_result(-1, wec.message());
            
            const size_t rcpt_count = msg.to().size() + msg.cc().size()
                                    + msg.bcc().size();
                                    
            const size_t total_expected = 1 + rcpt_count + 1;

            std::vector<SmtpResponse> responses;
            responses.reserve(total_expected);
            for (size_t i = 0; i < total_expected; ++i)
                responses.push_back(command(""));
                
            if (responses[0].code != 250)
                return make_result(responses[0].code, responses[0].text);
                
            SmtpSendResult rcpt_err;
            bool had_rcpt_error = false;
            for (size_t i = 1; i <= rcpt_count; ++i) {
                if (!had_rcpt_error &&
                    responses[i].code != 250 && responses[i].code != 251) {
                    rcpt_err = make_result(responses[i].code, responses[i].text);
                    had_rcpt_error = true;                    
                }
            }
            if (had_rcpt_error) return rcpt_err;
            
            const auto& data_r = responses[rcpt_count + 1];
            if (data_r.code != 354)
                return make_result(data_r.code, data_r.text);

        } else {
            auto mf_r = command(mail_from);
            if (mf_r.code != 250) return make_result(mf_r.code, mf_r.text);

            auto send_rcpts = [&](const std::vector<std::string>& addrs)
                -> SmtpSendResult {
                for (const auto& a : addrs) {
                    std::string rcpt = "RCPT TO:<" + a + ">";
                    if (caps_.dsn && !msg.dsn_notify().empty())
                        rcpt += " NOTIFY=" + msg.dsn_notify();
                    rcpt += "\r\n";
                    auto rr = command(rcpt);
                    if (rr.code != 250 && rr.code != 251)
                        return make_result(rr.code, rr.text);
                }
                
                SmtpSendResult ok;
                ok.ok         = true;
                ok.smtp_code  = 250;
                ok.smtp_message = "ok";
                ok.error_class  = SmtpErrorClass::None;
                return ok;                            
            };

            auto t = send_rcpts(msg.to());
            if (!t.ok) return t;
            auto cc = send_rcpts(msg.cc());
            if (!cc.ok) return cc;
            auto bcc = send_rcpts(msg.bcc());
            if (!bcc.ok) return bcc;

            auto data_r = command("DATA\r\n");
            if (data_r.code != 354) return make_result(data_r.code, data_r.text);
        }
        
        auto apply_timeout = [&](double secs) {
            if (tls_stream_)
                SET_SOCK_TIMEOUT(tls_stream_->next_layer().native_handle(), secs);
            else if (plain_socket_)
                SET_SOCK_TIMEOUT(plain_socket_->native_handle(), secs);
        };
        apply_timeout(timeouts_.data_sec);

        boost::system::error_code ec;
        if (tls_stream_)
            asio::write(*tls_stream_, asio::buffer(escaped), ec);
        else
            asio::write(*plain_socket_, asio::buffer(escaped), ec);
        if (ec) return make_result(-1, ec.message());
        
        apply_timeout(timeouts_.response_sec);
        auto final_r = command("");

        if (final_r.code != 250)
            return make_result(final_r.code, final_r.text);

        SmtpSendResult ok;
        ok.ok         = true;
        ok.smtp_code  = 250;
        ok.smtp_message = final_r.text;
        ok.error_class  = SmtpErrorClass::None;
        needs_rset_ = false;
        return ok;
    }
    
    static SmtpSendResult make_result(int code, const std::string& text) {
        SmtpSendResult r;
        r.ok          = false;
        r.smtp_code   = code;
        r.smtp_message= text;
        r.error_class = classify_smtp_code(code);
        return r;
    }

    void set_socket_timeout(tcp::socket::native_handle_type fd, double secs) {
        SET_SOCK_TIMEOUT(fd, secs);
    }

    bool is_connected() const noexcept {
        try {
            if (tls_stream_) {
                return const_cast<boost::asio::ssl::stream<boost::asio::ip::tcp::socket>&>(*tls_stream_)
                    .lowest_layer().is_open();
            }
            if (plain_socket_) {
                return plain_socket_->is_open();
            }
        } catch (...) {}
        return false;
    }

    std::string         host_;
    uint16_t            port_;
    std::string         client_name_;
    std::string         username_;
    std::string         password_;
    SmtpMode            mode_;
    SmtpAuth            auth_mech_;
    OAuth2Config        oauth2_;
    SmtpCapabilities    caps_;  
    bool                needs_rset_= false;        
    int                 max_send_attempts_;
    SmtpTimeouts        timeouts_;
    std::optional<tcp::socket>  plain_socket_;
    std::optional<ssl::stream<tcp::socket>> tls_stream_;
    asio::io_context    ioc_;
    ssl::context        ssl_ctx_;
    mutable std::mutex send_mtx_;
};

} // transport