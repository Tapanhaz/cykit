from cykit.cylogger import *

http_handler = HttpHandler(
    host="localhost",
    port=8080,
    path="/logs",
    pattern="[%Y-%m-%d %H:%M:%S.%e] [%l] %v",
    level=Level.TRACE,
    queue_capacity=1024,
    max_msg_size=65536,
    overflow_policy=OverflowPolicy.DROP_OLDEST,
    use_tls=False,      
    retry_max_attempts= 3,
    pool_idle_timeout = 5,
    keepalive= True
)

smtp_handler = SmtpHandler(
    smtp_host="127.0.0.1",
    smtp_port=1025,
    from_addr="logger@test.local",
    to_addr="admin@test.local",
    subject="Log Alert from cylogger",
    pattern="[%Y-%m-%d %H:%M:%S.%e] [%l] %v",
    level=Level.ERROR,          
    username="",                
    password="",
    smtp_mode = 0, 
    connect_timeout= 2,    
    banner_timeout= 2,
    command_timeout= 1,
    max_send_attempts=1,
    queue_capacity=128,
    max_msg_size=65536,
    overflow_policy=OverflowPolicy.DROP_OLDEST,
    keepalive= False,
)

tcp_handler = TcpSocketHandler(
    host= "127.0.0.1", 
    port = 9001, 
    keepalive= False
)

udp_handler = UdpSocketHandler(
    host="127.0.0.1",
    port=4096,
    pattern="[%Y-%m-%d %H:%M:%S.%e] [%l] %v",  
    level=Level.TRACE,
    queue_capacity=1024,
    max_msg_size=65536,
    overflow_policy=OverflowPolicy.DROP_OLDEST
)

console_handler = ConsoleHandler()

log = Logger(
        "test",
        handlers= [
            console_handler, smtp_handler, 
            http_handler, tcp_handler, 
            udp_handler
            ],
        set_default=True,
        diag=True
        )

log.trace("Trace: cylogger test")
log.debug("Debug: sending data")
log.info("Info: regular log")
log.warn("Warning: something")
log.error("Error: occurred")
log.critical("Critical: shutdown")