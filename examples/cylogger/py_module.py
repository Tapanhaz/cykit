from cykit import cylogger

logger = cylogger.get_logger(__name__)


def py_module_func():
    logger.trace("This is an TRACE msg from python sub module")
    logger.debug("This is an DEBUG msg from python sub module")
    logger.info("This is an INFO msg from python sub module")
    logger.warn("This is an WARN msg from python sub module")  # noqa: G010
    logger.error("This is an ERROR msg from python sub module")
    logger.critical("This is an CRITICAL msg from python sub module")
