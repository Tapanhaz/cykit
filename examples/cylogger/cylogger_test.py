from cykit.cylogger import Logger, ColorScheme, FileHandler, ConsoleHandler
from cykit.cylogger.color import AnsiColor, TextEffect
from py_module import py_module_func
from cy_module import cy_func

logger = Logger("xyz")

logger.trace("This is an TRACE msg from python main module")
logger.debug("This is an DEBUG msg from python main module")
logger.info("This is an INFO msg from python main module")
logger.warn("This is an WARN msg from python main module")
logger.error("This is an ERROR msg from python main module")
logger.critical(
    "This is an CRITICAL msg from python main module", effect=TextEffect.BLINK
)  # noqa E501


# the portion inside %^  %$ will be colored.
pattern = "[%H:%M:%S] [file: %s] [line: %#] [func: %!] [%l]  %^%v%$"

console_handler = ConsoleHandler(pattern=pattern)
file_handler = FileHandler("test.log", pattern=pattern)

# Optional Custom color scheme
color_scheme = ColorScheme(
    trace_color=AnsiColor.GREY70,
    debug_color=AnsiColor.AQUAMARINE1_B,
    info_color=AnsiColor.BLUEVIOLET,
    warn_color=AnsiColor.ORANGE1,
    error_color=AnsiColor.RED1,
    critical_color=AnsiColor.MAGENTA1,
)

logger_2 = Logger(
    "abc",
    handlers=[console_handler, file_handler],
    color_scheme=color_scheme,
    # If no defaults set, all logging depends on default logger will be silent.  # noqa E501
    set_default=True,
)


def py_func():
    logger_2.trace("This is an TRACE msg from python main module")
    logger_2.debug("This is an DEBUG msg from python main module")
    logger_2.info("This is an INFO msg from python main module")
    logger_2.warn("This is an WARN msg from python main module")
    logger_2.error("This is an ERROR msg from python main module")
    logger_2.critical("This is an CRITICAL msg from python main module")


if __name__ == "__main__":
    py_func()
    py_module_func()
    cy_func()
