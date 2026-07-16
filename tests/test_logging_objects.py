import subprocess
import sys
from pathlib import Path


def test_log_objects():
    tests_dir = Path(__file__).resolve().parent
    script = """
import os
import sys

if sys.platform == "win32":
    from cykit._build.config import config

    _bin = config._get_openssl_bin_dir()
    if _bin:
        os.add_dll_directory(_bin)

from cykit.cylogger import Logger, LogLevel
logger = Logger("default", level=LogLevel.DEBUG)
logger.info({"a": 1})
"""
    result = subprocess.run(
        [sys.executable, "-u", "-c", script],
        capture_output=True,
        text=True,
        cwd=tests_dir,
        timeout=5,
    )
    assert result.returncode == 0, f"Subprocess failed:\n{result.stderr}"
    assert "{'a': 1}" in result.stdout
