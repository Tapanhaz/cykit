

from libcpp.pair cimport pair
from libc.stddef cimport size_t
from libcpp cimport bool as cbool
from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp.set cimport set as cset
from libcpp.memory cimport shared_ptr
from libc.stdint cimport uint8_t, uint16_t
from libcpp.optional cimport optional




cdef extern from *:
    """
    #ifdef _WIN32
    #  include <winsock2.h>
    #  include <ws2tcpip.h>
       typedef int socklen_t;
    #else
    #  include <sys/socket.h>
    #  include <netinet/in.h>
    #endif
    """
    ctypedef int socklen_t
    cdef struct sockaddr_storage:
        pass


cdef extern from "base_transport.hpp" namespace "transport" nogil:
        
    cdef enum class TransportErrorKind "transport::TransportErrorKind":
        NoErr     "NoErr"
        Timeout   "Timeout"
        Dns       "Dns"
        Connect   "Connect"
        Tls       "Tls"
        Protocol  "Protocol"
        Auth      "Auth"
        Remote    "Remote"
        Cancelled "Cancelled"
        Local     "Local"


    cdef cppclass TransportError:
        TransportErrorKind kind
        int                code
        string             message
        string             url
        int                http_status

        TransportError() except +
        TransportError(string msg,
                       TransportErrorKind k,
                       int c) except +
        TransportError(TransportErrorKind k,
                       string msg,
                       int c,
                       string u) except +

        const char* what() except +

        @staticmethod
        TransportError timeout(const string& url) except + nogil
        @staticmethod
        TransportError cancelled(const string& url) except +
        @staticmethod
        TransportError tls(const string& detail, int c) except +
        @staticmethod
        TransportError dns(const string& host) except +
        @staticmethod
        TransportError remote(int http_code, const string& reason) except +

    cdef cppclass CancellationSource:
        CancellationSource() except +
        void cancel()
        void reset()
        cbool is_cancelled()

        cppclass Token:
            cbool is_cancelled()
            void throw_if_cancelled() except +

        Token token()

    ctypedef CancellationSource.Token CancelToken

    ctypedef vector[pair[string, string]] HeaderList


    cdef cppclass CookieEntry:
        string name
        string value
        string domain
        string path
        string same_site
        cbool   secure
        cbool   http_only
        cbool   persistent

        cbool is_expired()
        cbool domain_matches(const string& host)
        cbool path_matches(const string& req_path)
        cbool secure_ok(cbool is_https)

    cdef cppclass CookieJar:
        CookieJar() except +
        void   parse_and_insert(const string& set_cookie_header,
                                const string& request_domain,
                                const string& request_path) except +
        string cookie_header(const string& domain,
                             const string& path,
                             cbool is_https) except +
        vector[CookieEntry] snapshot() except +
        void   clear() except +
        void   evict_expired() except +


    cdef cppclass TlsPolicy:
        cbool   verify_peer
        cbool   verify_hostname
        string ca_file
        string ca_path
        string cert_file
        string key_file
        string key_password
        int    min_tls_version
        cbool   allow_http2

        TlsPolicy() except +

        @staticmethod
        TlsPolicy strict() except +
        @staticmethod
        TlsPolicy insecure()  except +


    cdef enum class IdempotencyClass "transport::IdempotencyClass":
        Idempotent  "Idempotent"
        NonIdempotent "NonIdempotent"
        Force       "Force"

    cdef cppclass RetryPolicy:
        int              max_attempts
        double           initial_delay_sec
        double           backoff_factor
        double           max_delay_sec
        double           jitter_factor
        cset[int]                  retryable_statuses
        cset[TransportErrorKind]   retryable_kinds
        IdempotencyClass          idempotency

        RetryPolicy() except +
        cbool should_retry_error(const TransportError& e)
        cbool should_retry_status(int s)


    cdef cppclass KeepAliveConfig:
        cbool   enabled
        int    idle_sec
        int    interval_sec
        int    probe_count
        int    max_requests
        double max_age_sec

        KeepAliveConfig() except +
    
    cdef cppclass TransportTimeouts:
        double connect_sec
        double tls_sec
        double write_sec
        double read_sec
        double body_sec
        double total_sec
        double pool_idle_sec

        TransportTimeouts() except +
        TransportTimeouts(double all) except +
    
    cdef cppclass TcpTimeouts:
        double connect_sec
        double read_sec
        double write_sec
        TcpTimeouts() except +
        TcpTimeouts(double all) except +

    cdef cppclass SmtpTimeouts:
        double connect_sec
        double tls_sec
        double banner_sec
        double command_sec
        double data_sec
        double response_sec
        SmtpTimeouts() except +
        SmtpTimeouts(double all) except +


    cdef cppclass TransportHooks:
        TransportHooks() except +


    cdef cppclass HttpResponse:
        int        status
        string     body
        string     reason
        HeaderList headers
        cbool       http2
        size_t     bytes_received

        HttpResponse()  except +
        string header(const string& name) except +
        vector[string] header_all(const string& name) except +
        cbool ok()
        cbool is_redirect()
        string location() except +

    cdef cppclass RequestOptions:
        HeaderList               headers
        HeaderList               extra_cookies
        string                   user_agent
        TransportTimeouts        timeouts
        size_t                   expect_continue_threshold
        optional[TlsPolicy]      tls_policy
        optional[RetryPolicy]    retry_policy
        CancelToken              cancel_token
        unsigned char[32]        _body_chunk_cb
        unsigned char[32]        _upload_chunk_cb
        size_t                   upload_chunk_size
        optional[TransportHooks] hooks
        int                      max_redirects
        cbool                    forward_auth_on_redirect
        
        RequestOptions() except +


    cdef cppclass HttpClient:
        HttpClient() except +
        HttpClient(TlsPolicy         tls_policy,
                   RetryPolicy       retry_policy,
                   KeepAliveConfig   ka_cfg,
                   TransportHooks    hooks,
                   HeaderList        persistent_headers,
                   string            user_agent,
                   TransportTimeouts timeouts,
                   int               max_redirects,
                   shared_ptr[CookieJar] cookie_jar) except +

        HttpResponse request(const string& method,
                             const string& url,
                             const string& body,
                             const string& content_type,
                             RequestOptions opts) except +
        HttpResponse get(const string& url,
                         RequestOptions opts) except +
        HttpResponse post(const string& url,
                          const string& body,
                          const string& ct,
                          RequestOptions opts) except +
        HttpResponse put(const string& url,
                         const string& body,
                         const string& ct,
                         RequestOptions opts) except +
        HttpResponse patch(const string& url,
                           const string& body,
                           const string& ct,
                           RequestOptions opts) except +
        HttpResponse delete "del"(const string& url,
                               RequestOptions opts) except +
        HttpResponse head(const string& url,
                          RequestOptions opts) except +
        HttpResponse options(const string& url,
                             RequestOptions opts) except +

        CookieJar&  cookie_jar() except +
        HeaderList& persistent_headers()  except +
        

    cdef cppclass HttpSession:
        HttpSession(string           host,
                    uint16_t         port,
                    string           base_path,
                    string           default_content_type,
                    HeaderList       persistent_headers,
                    string           user_agent,
                    cbool             use_tls,
                    TransportTimeouts timeouts,
                    TlsPolicy        tls_policy,
                    RetryPolicy      retry_policy,
                    KeepAliveConfig  ka_cfg,
                    TransportHooks   hooks,
                    int              max_redirects,
                    shared_ptr[CookieJar] cookie_jar) except +

        HttpResponse get(const string& path,
                         RequestOptions opts) except +
        HttpResponse post(const string& path,
                          const string& body,
                          const string& ct,
                          RequestOptions opts) except +
        HttpResponse put(const string& path,
                         const string& body,
                         const string& ct,
                         RequestOptions opts) except +
        HttpResponse patch(const string& path,
                           const string& body,
                           const string& ct,
                           RequestOptions opts) except +
        HttpResponse delete "del"(const string& path,
                               RequestOptions opts) except +
        HttpResponse head(const string& path,
                          RequestOptions opts) except +
        HttpResponse options(const string& path,
                             RequestOptions opts) except +

        void reconnect() except +
        void disconnect() except +

        void force_close() noexcept

        CookieJar&  cookie_jar() except +
        HeaderList& persistent_headers() except +


    cdef cppclass TcpSocket:
        TcpSocket() except +
        void   connect(const string& host,
                       uint16_t      port,
                       TcpTimeouts   timeouts,
                       cbool          keepalive,
                       CancelToken   token) except +
        void   close() except +
        void   shutdown() except +
        void   send_all(const string& data) except +
        string recv(size_t max_size) except +
        string recv_exactly(size_t need) except +
        string peek(size_t max_size) except +
        cbool is_open() noexcept


    cdef cppclass UdpSocket:
        UdpSocket() except +
        void create_client(const string& host,
                           uint16_t port,
                           double   recv_timeout_sec,
                           cbool broadcast,
                           double   send_timeout_sec) except +
        void create_server(uint16_t port,
                           cbool reuse_addr,
                           double timeout_sec) except +
        void sendto(const string& data) except +
        pair[string, sockaddr_storage] recvfrom(size_t max_size) except +
        void close() except +
        cbool is_open() noexcept

    cdef cppclass OAuth2Config:
        string client_id
        string client_secret
        string refresh_token

        OAuth2Config() except +
        
        @staticmethod
        string build_xoauth2_payload(const string& user, const string& token) except +

        void set_refresh_provider(const string& token_endpoint) except +

    cdef enum class SmtpAuth "transport::SmtpAuth":
        Off    "Off"
        Plain   "Plain"
        Login   "Login"
        XOAuth2 "XOAuth2"


    cdef enum class SmtpMode "transport::SmtpMode":
        Plain    "Plain"
        StartTls "StartTls"
        Smtps    "Smtps"

    cdef enum class SmtpErrorClass "transport::SmtpErrorClass":
        NoErr       "NoErr"
        Transient   "Transient"
        Permanent   "Permanent"
        ServiceDown "ServiceDown"

    cdef cppclass SmtpCapabilities:
        cbool        starttls
        cbool        pipelining
        cbool        eight_bit
        cbool        smtputf8
        cbool        dsn
        size_t      max_size
        cset[string] auth_mechanisms

        SmtpCapabilities() except +
        cbool supports_auth(const string& mech)

    cdef cppclass SmtpSendResult:
        cbool           ok
        int            smtp_code
        string         smtp_message
        SmtpErrorClass error_class
        int            attempts

        SmtpSendResult() except +
        cbool should_retry()
        cbool is_permanent_failure()

    
    cdef cppclass SmtpMessage:
        SmtpMessage() except +

        SmtpMessage& set_from(const string& f) except +
        SmtpMessage& add_to(const string& t) except +
        SmtpMessage& add_cc(const string& cc)  except +
        SmtpMessage& add_bcc(const string& bcc) except +
        SmtpMessage& set_reply_to(const string& r) except +
        SmtpMessage& set_subject(const string& s) except +
        SmtpMessage& set_body_text(const string& t) except +
        SmtpMessage& set_body_html(const string& h) except +
        SmtpMessage& add_attachment(const string& name,
                                    const string& b64) except +
        SmtpMessage& set_dsn_ret(const string& ret) except +
        SmtpMessage& set_dsn_notify(const string& n) except +
        SmtpMessage& set_envid(const string& id) except +

        const string& from_addr "from"() except +
        const vector[string]& to() except +
        const vector[string]& cc() except +
        const vector[string]& bcc() except +
        const string&         dsn_ret() except +
        const string&         dsn_notify() except +
        const string&         envid() except +
        string                build()  except +


    cdef cppclass SmtpClient:
        SmtpClient(const string& host,
                   uint16_t      port,
                   const string& client_name,
                   const string& username,
                   const string& password,
                   SmtpMode      mode,
                   SmtpAuth      auth_mech,
                   OAuth2Config  oauth2,
                   int           max_send_attempts,
                   SmtpTimeouts  timeouts) except +

        SmtpSendResult send(const SmtpMessage& msg, cbool close_after_send) except +
        cbool noop() except +
        cbool rset() except +


    string base64_encode(const string& src) except +



cdef inline TcpSocket* make_tcp_socket(
        string      host,
        uint16_t    port,
        double      connect_timeout = 10.0,
        double      read_timeout    = 30.0,
        double      write_timeout   = 30.0,
        bint        keepalive       = True,
        CancelToken cancel_token    = CancelToken()
) except *:
    cdef TcpSocket* s = new TcpSocket()
    cdef TcpTimeouts t
    t.connect_sec = connect_timeout
    t.read_sec    = read_timeout
    t.write_sec   = write_timeout
    s.connect(host, port, t, keepalive, cancel_token)
    return s


cdef inline UdpSocket* make_udp_client(
        string   host,
        uint16_t port,
        double   recv_timeout_sec = 5.0,
        double   send_timeout_sec = 5.0,
        bint     broadcast        = False
) except *:
    cdef UdpSocket* s = new UdpSocket()
    s.create_client(host, port, recv_timeout_sec, broadcast, send_timeout_sec)
    return s


cdef inline UdpSocket* make_udp_server(
        uint16_t port,
        double   timeout_sec = 5.0,
        bint     reuse_addr  = True
) except *:
    cdef UdpSocket* s = new UdpSocket()
    s.create_server(port, reuse_addr, timeout_sec)
    return s


cdef inline TlsPolicy _build_tls(
        bint   verify_tls,
        bint   verify_hostname,
        string ca_file,
        string ca_path,
        string cert_file,
        string key_file,
        string key_password,
        int    min_tls_version,
        bint   allow_http2
) nogil:
    cdef TlsPolicy tp

    tp.verify_peer     = verify_tls
    tp.verify_hostname = verify_hostname
    tp.ca_file         = ca_file
    tp.ca_path         = ca_path
    tp.cert_file       = cert_file
    tp.key_file        = key_file
    tp.key_password    = key_password
    tp.allow_http2     = allow_http2
    if min_tls_version != 0:
        tp.min_tls_version = min_tls_version
    
    return tp


cdef inline RetryPolicy _build_retry(
        int              max_attempts,
        double           initial_delay,
        double           backoff_factor,
        double           max_delay,
        double           jitter,
        IdempotencyClass idempotency
) nogil:
    cdef RetryPolicy rp

    rp.max_attempts      = max_attempts
    rp.initial_delay_sec = initial_delay
    rp.backoff_factor    = backoff_factor
    rp.max_delay_sec     = max_delay
    rp.jitter_factor     = jitter
    rp.idempotency       = idempotency

    return rp


cdef inline KeepAliveConfig _build_ka(
        bint   enabled,
        int    idle_sec,
        int    interval_sec,
        int    probe_count,
        int    max_requests,
        double max_age_sec
) nogil:
    cdef KeepAliveConfig ka

    ka.enabled      = enabled
    ka.idle_sec     = idle_sec
    ka.interval_sec = interval_sec
    ka.probe_count  = probe_count
    ka.max_requests = max_requests
    ka.max_age_sec  = max_age_sec

    return ka


cdef inline TransportTimeouts _build_http_timeouts(
        double connect_sec,
        double tls_sec,
        double write_sec,
        double read_sec,
        double body_sec,
        double total_sec,
        double pool_idle_sec
) nogil:
    cdef TransportTimeouts t
    t.connect_sec = connect_sec
    t.tls_sec     = tls_sec
    t.write_sec   = write_sec
    t.read_sec    = read_sec
    t.body_sec    = body_sec
    t.total_sec   = total_sec
    t.pool_idle_sec = pool_idle_sec
    return t

cdef inline SmtpTimeouts _build_smtp_timeouts(
        double connect_sec,
        double tls_sec,
        double banner_sec,
        double command_sec,
        double data_sec,
        double response_sec
) noexcept nogil:
    cdef SmtpTimeouts t
    t.connect_sec  = connect_sec
    t.tls_sec      = tls_sec
    t.banner_sec   = banner_sec
    t.command_sec  = command_sec
    t.data_sec     = data_sec
    t.response_sec = response_sec
    return t


cdef inline HttpClient* make_http_client(
        double           connect_timeout     = 10.0,
        double           tls_timeout         = 10.0,
        double           write_timeout       = 30.0,
        double           read_timeout        = 30.0,
        double           body_timeout        = 60.0,
        double           total_timeout       = 0,
        double           pool_idle_timeout   = 0,
        int              max_redirects       = 10,
        bint             verify_tls          = True,
        bint             verify_hostname     = True,
        string           ca_file             = b"",
        string           ca_path             = b"",
        string           cert_file           = b"",
        string           key_file            = b"",
        string           key_password        = b"",
        int              min_tls_version     = 0,
        bint             allow_http2         = False,
        int              retry_max_attempts  = 1,
        double           retry_initial_delay = 1.0,
        double           retry_backoff       = 2.0,
        double           retry_max_delay     = 30.0,
        double           retry_jitter        = 0.1,
        IdempotencyClass retry_idempotency   = IdempotencyClass.Idempotent,
        bint             ka_enabled          = True,
        int              ka_idle_sec         = 60,
        int              ka_interval_sec     = 10,
        int              ka_probe_count      = 5,
        int              ka_max_requests     = 1000,
        double           ka_max_age_sec      = 300.0,
        string           user_agent          = b"TransportLib/3.0",
        HeaderList       persistent_headers  = HeaderList(),
        shared_ptr[CookieJar] cookie_jar     = shared_ptr[CookieJar]()
) except *:
    return new HttpClient(
        _build_tls(verify_tls, verify_hostname, ca_file, ca_path,
                   cert_file, key_file, key_password,
                   min_tls_version, allow_http2),
        _build_retry(retry_max_attempts, retry_initial_delay, retry_backoff,
                     retry_max_delay, retry_jitter, retry_idempotency),
        _build_ka(ka_enabled, ka_idle_sec, ka_interval_sec,
                  ka_probe_count, ka_max_requests, ka_max_age_sec),
        TransportHooks(),
        persistent_headers,
        user_agent,
        _build_http_timeouts(connect_timeout, tls_timeout,
                        write_timeout, read_timeout, body_timeout,
                        total_timeout, pool_idle_timeout),
        max_redirects,
        cookie_jar)



cdef inline HttpSession* make_http_session(
        string           host,
        uint16_t         port,
        string           base_path            = b"/",
        string           default_content_type = b"application/json",
        bint             use_tls              = True,
        double           connect_timeout     = 10.0,
        double           tls_timeout         = 10.0,
        double           write_timeout       = 30.0,
        double           read_timeout        = 30.0,
        double           body_timeout        = 60.0,
        double           total_timeout       = 0,
        double           pool_idle_timeout   = 0,
        bint             verify_tls           = True,
        bint             verify_hostname      = True,
        string           ca_file              = b"",
        string           ca_path              = b"",
        string           cert_file            = b"",
        string           key_file             = b"",
        string           key_password         = b"",
        int              min_tls_version      = 0,
        bint             allow_http2          = False,
        int              retry_max_attempts   = 1,
        double           retry_initial_delay  = 1.0,
        double           retry_backoff        = 2.0,
        double           retry_max_delay      = 30.0,
        double           retry_jitter         = 0.1,
        IdempotencyClass retry_idempotency    = IdempotencyClass.Idempotent,
        bint             ka_enabled           = True,
        int              ka_idle_sec          = 60,
        int              ka_interval_sec      = 10,
        int              ka_probe_count       = 5,
        int              ka_max_requests      = 1000,
        double           ka_max_age_sec       = 300.0,
        string           user_agent           = b"TransportLib/3.0",
        HeaderList       persistent_headers   = HeaderList(),
        int              max_redirects        = 10,
        shared_ptr[CookieJar] cookie_jar      = shared_ptr[CookieJar]()
) except *:
    return new HttpSession(
        host, port, base_path, default_content_type,
        persistent_headers, user_agent, use_tls, 
        _build_http_timeouts(connect_timeout, tls_timeout,
                        write_timeout, read_timeout, body_timeout,
                        total_timeout, pool_idle_timeout),
        _build_tls(verify_tls, verify_hostname, ca_file, ca_path,
                   cert_file, key_file, key_password,
                   min_tls_version, allow_http2),
        _build_retry(retry_max_attempts, retry_initial_delay, retry_backoff,
                     retry_max_delay, retry_jitter, retry_idempotency),
        _build_ka(ka_enabled, ka_idle_sec, ka_interval_sec,
                  ka_probe_count, ka_max_requests, ka_max_age_sec),
        TransportHooks(),
        max_redirects,
        cookie_jar)


cdef inline const char* smtp_error_class_str(SmtpErrorClass ec) noexcept nogil:
    if ec == SmtpErrorClass.NoErr:
        return b"NoError"
    elif ec == SmtpErrorClass.Transient:
        return b"Transient"
    elif ec == SmtpErrorClass.Permanent:
        return b"Permanent"
    elif ec == SmtpErrorClass.ServiceDown:
        return b"ServiceDown"

cdef inline SmtpClient* make_smtp_client(
        string       host,
        uint16_t     port,
        string       username            = b"",
        string       password            = b"",
        string       client_name         = b"localhost",
        SmtpMode     mode                = SmtpMode.StartTls,
        SmtpAuth     auth_mech           = SmtpAuth.Login,
        OAuth2Config oauth2              = OAuth2Config(),
        int          max_send_attempts   = 3,
        double       connect_timeout     = 10.0,
        double       tls_timeout         = 10.0,
        double       banner_timeout      = 10.0,
        double       command_timeout     = 30.0,
        double       data_timeout        = 60.0,
        double       response_timeout    = 30.0,
) noexcept nogil:
    return new SmtpClient(host, port, client_name, username, password,
                          mode, auth_mech, oauth2, max_send_attempts,
                          _build_smtp_timeouts(connect_timeout, tls_timeout,
                                               banner_timeout, command_timeout,
                                               data_timeout, response_timeout))


cdef inline SmtpSendResult smtp_send(
        SmtpClient* client,
        string      from_addr,
        list        to_addrs,
        string      subject,
        string      body_text   = b"",
        string      body_html   = b"",
        list        cc_addrs    = [],
        list        bcc_addrs   = [],
        string      reply_to    = b"",
        list        attachments = [],
        string      dsn_ret     = b"FULL",
        string      dsn_notify  = b"FAILURE,DELAY",
        string      envid       = b"",
        bool        close_after_send = False
) except *:
    cdef SmtpMessage msg
    cdef string      addr
    cdef tuple       att

    msg.set_from(from_addr)
    for addr in to_addrs:
        msg.add_to(addr)
    for addr in cc_addrs:
        msg.add_cc(addr)
    for addr in bcc_addrs:
        msg.add_bcc(addr)
    
    if not reply_to.empty():
        msg.set_reply_to(reply_to)
    
    msg.set_subject(subject)
    
    if not body_text.empty():
        msg.set_body_text(body_text)
    
    if not body_html.empty():
        msg.set_body_html(body_html)
    
    for att in attachments:
        msg.add_attachment(att[0], att[1])
    msg.set_dsn_ret(dsn_ret)
    msg.set_dsn_notify(dsn_notify)
    
    if not envid.empty():
        msg.set_envid(envid)

    return client[0].send(msg, close_after_send)