import sys
import os

if sys.platform == "win32":
    from cykit._build.config import config

    _bin = config._get_openssl_bin_dir()
    if _bin:
        os.add_dll_directory(_bin)

from cykit.cylogger import Logger, LogLevel

logger = Logger("default", level=LogLevel.DEBUG)


def test_log_objects():
    r, w = os.pipe()

    os.dup2(w, 1)

    logger.info({"a": 1})

    os.close(w)
    output = os.read(r, 1024).decode()

    assert "{'a': 1}" in output
