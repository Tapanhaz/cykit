from cykit.cylogger import (
    ConsoleHandler,
    Logger,
    LogLevel,
    OverflowPolicy,
    SmtpHandler,
)  # noqa E501

smtp_handler = SmtpHandler(
    smtp_host="smtp.gmail.com",
    smtp_port=587,
    from_addr="from username@gmail.com",
    to_addr="to username@gmail.com",
    subject="Log Alert from CyKit",
    pattern="[%Y-%m-%d %H:%M:%S.%e] [%l] %v",
    level=LogLevel.CRITICAL,
    username="from username@gmail.com",
    password="",
    smtp_mode=1,
    smtp_auth=3,  # plain SMTP
    queue_capacity=128,
    max_msg_size=65536,
    overflow_policy=OverflowPolicy.DROP_OLDEST,
    keepalive=False,
    oauth2_client_id="oauth2_client_id",
    oauth2_secret="oauth2_secret",
    oauth2_refresh="oauth2_refresh_token",
    oauth2_endpoint="https://oauth2.googleapis.com/token",
    queue_close_timeout=10000,  # optional
)

console_handler = ConsoleHandler()

logger = Logger(
    name="smtp_demo",
    level=LogLevel.TRACE,
    handlers=[smtp_handler, console_handler],
    intercept_stdlib_logging=True,
    set_default=True,
)

# Only CRITICAL will be sent
logger.info("This info will NOT be sent")
logger.error("Error: disk space low")
logger.critical("Critical: system failure")
