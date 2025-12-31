from typing import Optional, Literal, List
from enum import IntEnum

class Level(IntEnum):
    TRACE = ...
    DEBUG = ...
    INFO = ...
    WARN = ...
    ERROR = ...
    CRITICAL = ...
    OFF = ...

class LogHandler:
    color: bool
    pattern: str
    level: Level

    def __init__(
        self,
        color: bool = True,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: Level = Level.TRACE,
    ) -> None: ...

class StdoutHandler(LogHandler):
    max_level: Level

    def __init__(
        self,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: Level = Level.TRACE,
        max_level: Level = Level.INFO,
    ) -> None: ...

class StderrHandler(LogHandler):
    def __init__(
        self,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: Level = Level.WARN,
    ) -> None: ...

class BasicConsoleHandler(LogHandler):
    def __init__(
        self,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: Level = Level.TRACE,
    ) -> None: ...

class ConsoleHandler(LogHandler):
    max_stdout_level: Level
    min_level: Level

    def __init__(
        self,
        color: bool = True,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        max_stdout_level: Level = Level.INFO,
        min_level: Level = Level.TRACE,
    ) -> None: ...

class FileHandler(LogHandler):
    filename: str
    overwrite: bool

    def __init__(
        self,
        filename: str,
        color: bool = False,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: Level = Level.TRACE,
        overwrite: bool = False,
    ) -> None: ...

class RotatingFileHandler(FileHandler):
    max_size: int
    max_files: int

    def __init__(
        self,
        filename: str,
        pattern: str = "[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v",
        level: Level = Level.TRACE,
        max_size: int = 1048576,
        max_files: int = 3,
    ) -> None: ...

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
        level: Level = Level.TRACE,
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
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def debug(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def info(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def warn(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def error(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def critical(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...

class DefaultLogger:
    def trace(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def debug(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def info(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def warn(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def error(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
    def critical(
        self,
        msg: str,
        fg_color: int = -1,
        bg_color: int = -1,
        effect: int = -1,
    ) -> None: ...
