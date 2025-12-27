from cykit.cylogger import DefaultLogger

log = DefaultLogger()


def py_module_func():
    log.trace("This is an TRACE msg from python sub module")
    log.debug("This is an DEBUG msg from python sub module")
    log.info("This is an INFO msg from python sub module")
    log.warn("This is an WARN msg from python sub module")
    log.error("This is an ERROR msg from python sub module")
    log.critical("This is an CRITICAL msg from python sub module")
