import sys
import os

if sys.platform == "win32":
    from cykit._build.config import config

    _bin = config._get_openssl_bin_dir()
    if _bin:
        os.add_dll_directory(_bin)

from cykit.cylogger import Logger, LogLevel


def test_log_objects():
    old_stdout_fd = os.dup(1)
    old_stderr_fd = os.dup(2)

    r, w = os.pipe()

    try:
        os.dup2(w, 1)
        os.dup2(w, 2)

        logger = Logger("default", level=LogLevel.DEBUG)
        logger.info({"a": 1})

        sys.stdout.flush()
        sys.stderr.flush()
    finally:
        os.dup2(old_stdout_fd, 1)
        os.dup2(old_stderr_fd, 2)
        os.close(old_stdout_fd)
        os.close(old_stderr_fd)
        os.close(w)

    output = os.read(r, 1024).decode()
    assert "{'a': 1}" in output
    os.close(r)
