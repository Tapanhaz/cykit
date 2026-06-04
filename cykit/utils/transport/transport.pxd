

from libcpp.pair cimport pair
from libc.stddef cimport size_t
from libcpp cimport bool as cbool
from libcpp.string cimport string
from libcpp.vector cimport vector
from libcpp.set cimport set as cset
from libcpp.memory cimport shared_ptr
from libc.stdint cimport uint8_t, uint16_t

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
    cdef enum TransportErrorKind:
        none      "transport::TransportErrorKind::None"
        Timeout   "transport::TransportErrorKind::Timeout"
        Dns       "transport::TransportErrorKind::Dns"
        Connect   "transport::TransportErrorKind::Connect"
        Tls       "transport::TransportErrorKind::Tls"
        Protocol  "transport::TransportErrorKind::Protocol"
        Auth      "transport::TransportErrorKind::Auth"
        Remote    "transport::TransportErrorKind::Remote"
        Cancelled "transport::TransportErrorKind::Cancelled"
        Local     "transport::TransportErrorKind::Local"

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


    cdef enum IdempotencyClass:
        Idempotent  "transport::IdempotencyClass::Idempotent"
        NonIdempotent "transport::IdempotencyClass::NonIdempotent"
        Force       "transport::IdempotencyClass::Force"

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
        HeaderList  headers
        HeaderList  extra_cookies
        string      user_agent
        double      timeout_sec
        CancelToken cancel_token
        int         max_redirects
        cbool        forward_auth_on_redirect

        RequestOptions() except +


    cdef cppclass HttpClient:
        HttpClient() except +
        HttpClient(TlsPolicy         tls_policy,
                   RetryPolicy       retry_policy,
                   KeepAliveConfig   ka_cfg,
                   TransportHooks    hooks,
                   HeaderList        persistent_headers,
                   string            user_agent,
                   double            timeout_sec,
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
                    double           timeout_sec,
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

        CookieJar&  cookie_jar() except +
        HeaderList& persistent_headers() except +


    cdef cppclass TcpSocket:
        TcpSocket() except +
        void   connect(const string& host,
                       uint16_t      port,
                       double        timeout_sec,
                       cbool          keepalive,
                       CancelToken   token) except +
        void   close() except +
        void   shutdown() except +
        void   send_all(const string& data) except +
        string recv(size_t max_size) except +
        string recv_exactly(size_t need) except +
        string peek(size_t max_size) except +


    cdef cppclass UdpSocket:
        UdpSocket() except +
        void create_client(const string& host,
                           uint16_t      port,
                           double        timeout_sec,
                           cbool          broadcast) except +
        void create_server(uint16_t port,
                           cbool     reuse_addr,
                           double   timeout_sec) except +
        void sendto(const string& data) except +
        pair[string, sockaddr_storage] recvfrom(size_t max_size) except +
        void close() except +

    cdef cppclass OAuth2Config:
        string client_id
        string client_secret
        string refresh_token

        OAuth2Config() except +
        
        @staticmethod
        string build_xoauth2_payload(const string& user,
                                     const string& token) except +

        void set_refresh_provider(const string& token_endpoint) except +

    cdef enum SmtpAuth:
        smtp_auth_none    "transport::SmtpAuth::None"
        smtp_auth_plain   "transport::SmtpAuth::Plain"
        Login   "transport::SmtpAuth::Login"
        XOAuth2 "transport::SmtpAuth::XOAuth2"

    cdef enum SmtpMode:
        smtp_mode_plain    "transport::SmtpMode::Plain"
        StartTls "transport::SmtpMode::StartTls"
        Smtps    "transport::SmtpMode::Smtps"

    cdef enum SmtpErrorClass:
        smtp_error_none        "transport::SmtpErrorClass::None"
        Transient   "transport::SmtpErrorClass::Transient"
        Permanent   "transport::SmtpErrorClass::Permanent"
        ServiceDown "transport::SmtpErrorClass::ServiceDown"

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
                   double        timeout_sec) except +

        SmtpSendResult send(const SmtpMessage& msg) except +
        cbool noop() except +
        cbool rset() except +


    string base64_encode(const string& src) except +



cdef inline TcpSocket* make_tcp_socket(
        string      host,
        uint16_t    port,
        double      timeout_sec  = 30.0,
        bint        keepalive    = True,
        CancelToken cancel_token = CancelToken()
) except *:
    cdef TcpSocket* s = new TcpSocket()
    s.connect(host, port, timeout_sec, keepalive, cancel_token)
    return s


cdef inline UdpSocket* make_udp_client(
        string   host,
        uint16_t port,
        double   timeout_sec = 5.0,
        bint     broadcast   = False
) except *:
    cdef UdpSocket* s = new UdpSocket()
    s.create_client(host, port, timeout_sec, broadcast)
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



cdef inline HttpClient* make_http_client(
        double           timeout_sec         = 30.0,
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
        timeout_sec,
        max_redirects,
        cookie_jar)



cdef inline HttpSession* make_http_session(
        string           host,
        uint16_t         port,
        string           base_path            = b"/",
        string           default_content_type = b"application/json",
        bint             use_tls              = True,
        double           timeout_sec          = 30.0,
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
        persistent_headers, user_agent, use_tls, timeout_sec,
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



cdef inline SmtpClient* make_smtp_client(
        string      host,
        uint16_t    port,
        string      username          = b"",
        string      password          = b"",
        string      client_name       = b"localhost",
        SmtpMode    mode              = SmtpMode.StartTls,
        SmtpAuth    auth_mech         = SmtpAuth.Login,
        OAuth2Config oauth2           = OAuth2Config(),
        int         max_send_attempts = 3,
        double      timeout_sec       = 30.0,
) except *:
    return new SmtpClient(host, port, client_name, username, password,
                          mode, auth_mech, oauth2,
                          max_send_attempts, timeout_sec)


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
        string      envid       = b""
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

    return client[0].send(msg)
