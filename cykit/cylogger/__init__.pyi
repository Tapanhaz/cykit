from typing import Optional, Literal, List
from enum import IntEnum

class LogLevel(IntEnum):
    TRACE = ...
    DEBUG = ...
    INFO = ...
    WARN = ...
    ERROR = ...
    CRITICAL = ...
    OFF = ...

class OverflowPolicy(IntEnum):
    BLOCK = ...
    DROP_NEWEST = ...
    DROP_OLDEST = ...

class SmtpAuthMethod(IntEnum):
    NONE = ...
    PLAIN = ...
    LOGIN = ...
    XOAUTH2 = ...

class SmtpSecurityMode(IntEnum):
    PLAIN = ...
    STARTTLS = ...
    SMTPS = ...

class SmtpErrorCategory(IntEnum):
    NONE = ...
    TRANSIENT = ...
    PERMANENT = ...
    SERVICE_DOWN = ...

class LogHandler:
    color: bool
    pattern: str
    level: LogLevel

    def __init__(
        self,
        color: bool = True,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
    ) -> None: ...

class UserSinkBase(LogHandler):
    def __init__(
        self,
        pattern: str,
        level: LogLevel,
        queue_capacity: int,
        max_msg_size: int,
        overflow_policy: OverflowPolicy,
        close_timeout_ms: int = -1,
        detach: bool = False,
    ) -> None: ...
    def stop(self) -> None: ...

class StdoutHandler(LogHandler):
    max_level: LogLevel

    def __init__(
        self,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
        max_level: LogLevel = LogLevel.INFO,
    ) -> None: ...

class StderrHandler(LogHandler):
    def __init__(
        self,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.WARN,
    ) -> None: ...

class BasicConsoleHandler(LogHandler):
    def __init__(
        self,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
    ) -> None: ...

class ConsoleHandler(LogHandler):
    max_stdout_level: LogLevel
    min_level: LogLevel

    def __init__(
        self,
        color: bool = True,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        max_stdout_level: LogLevel = LogLevel.INFO,
        min_level: LogLevel = LogLevel.TRACE,
    ) -> None: ...

class FileHandler(LogHandler):
    filename: str
    overwrite: bool

    def __init__(
        self,
        filename: str,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
        overwrite: bool = False,
    ) -> None: ...

class RotatingFileHandler(FileHandler):
    max_size: int
    max_files: int

    def __init__(
        self,
        filename: str,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
        max_size: int = 1048576,
        max_files: int = 3,
    ) -> None: ...

class DailyFileHandler(FileHandler):
    def __init__(
        self,
        filename: str,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
        rotation_hour: int = 0,
        rotation_minute: int = 0,
        truncate: bool = False,
        max_files: int = 0,
    ) -> None: ...

class TcpSocketHandler(UserSinkBase):
    def __init__(
        self,
        host: str,
        port: int,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
        queue_capacity: int = 4096,
        max_msg_size: int = 4096,
        overflow_policy: OverflowPolicy = OverflowPolicy.DROP_OLDEST,
        keepalive: bool = True,
        reconnect_on_failure: bool = True,
        connect_timeout: float = 5.0,
        read_timeout: float = 5.0,
        write_timeout: float = 5.0,
        close_timeout_ms: int = -1,
        detach: bool = False,
    ) -> None: ...
    def close(self) -> None: ...

class UdpSocketHandler(UserSinkBase):
    def __init__(
        self,
        host: str,
        port: int,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.TRACE,
        queue_capacity: int = 4096,
        max_msg_size: int = 4096,
        overflow_policy: OverflowPolicy = OverflowPolicy.DROP_OLDEST,
        recv_timeout_sec: float = 5.0,
        send_timeout_sec: float = 5.0,
        close_timeout_ms: int = -1,
        detach: bool = False,
    ) -> None: ...
    def close(self) -> None: ...

class HttpHandler(UserSinkBase):
    def __init__(
        self,
        host: str,
        port: int = 80,
        path: str = "/",
        content_type: str = "text/plain",
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.WARN,
        queue_capacity: int = 512,
        max_msg_size: int = 65536,
        overflow_policy: OverflowPolicy = OverflowPolicy.DROP_OLDEST,
        keepalive: bool = False,
        use_tls: bool = False,
        connect_timeout: float = 10.0,
        tls_timeout: float = 10.0,
        write_timeout: float = 30.0,
        read_timeout: float = 30.0,
        body_timeout: float = 60.0,
        total_timeout: float = 0.0,
        pool_idle_timeout: float = 0.0,
        verify_tls: bool = True,
        verify_hostname: bool = True,
        ca_file: str = "",
        ca_path: str = "",
        cert_file: str = "",
        key_file: str = "",
        key_password: str = "",
        min_tls_version: int = 0,
        allow_http2: bool = False,
        retry_max_attempts: int = 3,
        retry_initial_delay: float = 1.0,
        retry_backoff: float = 2.0,
        retry_max_delay: float = 30.0,
        retry_jitter: float = 0.1,
        ka_idle_sec: int = 60,
        ka_interval_sec: int = 10,
        ka_probe_count: int = 5,
        ka_max_requests: int = 1000,
        ka_max_age_sec: float = 300.0,
        user_agent: str = "cylogger",
        max_redirects: int = 10,
        close_timeout_ms: int = -1,
        detach: bool = False,
    ) -> None: ...
    def close(self) -> None: ...

class SmtpHandler(UserSinkBase):
    def __init__(
        self,
        smtp_host: str,
        smtp_port: int = 587,
        client_name: str = "localhost",
        from_addr: str = "",
        to_addr: str = "",
        subject: str = "Log Alert",
        username: str = "",
        password: str = "",
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: LogLevel = LogLevel.ERROR,
        queue_capacity: int = 128,
        max_msg_size: int = 65536,
        overflow_policy: OverflowPolicy = OverflowPolicy.DROP_OLDEST,
        keepalive: bool = False,
        smtp_mode: SmtpSecurityMode = SmtpSecurityMode.STARTTLS,
        smtp_auth: SmtpAuthMethod = SmtpAuthMethod.LOGIN,
        max_send_attempts: int = 3,
        connect_timeout: float = 5.0,
        tls_timeout: float = 5.0,
        banner_timeout: float = 5.0,
        command_timeout: float = 5.0,
        data_timeout: float = 10.0,
        response_timeout: float = 5.0,
        oauth2_client_id: str = "",
        oauth2_secret: str = "",
        oauth2_refresh: str = "",
        oauth2_endpoint: str = "",
        close_timeout_ms: int = -1,
        detach: bool = False,
    ) -> None: ...
    def close(self) -> None: ...

class ColorScheme:
    trace_color: int
    debug_color: int
    info_color: int
    warn_color: int
    error_color: int
    critical_color: int

    def __init__(
        self,
        trace_color: int = -1,
        debug_color: int = -1,
        info_color: int = -1,
        warn_color: int = -1,
        error_color: int = -1,
        critical_color: int = -1,
    ) -> None: ...

class Logger:
    def __init__(
        self,
        name: str,
        level: LogLevel = LogLevel.TRACE,
        handlers: Optional[List] = [],
        color_scheme: Optional[ColorScheme] = None,
        set_default: bool = False,
        intercept_stdlib_logging: bool = True,
    ) -> None: ...
    """
    intercept_stdlib_logging will work only when set_default= True
    """
    def trace(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def debug(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def info(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def warn(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def error(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def critical(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...

class DefaultLogger:
    def trace(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def debug(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def info(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def warn(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def error(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def critical(
        self,
        msg: object,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
