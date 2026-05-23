import os
from cykit.cylogger import Logger, Level

logger = Logger("default", level=Level.DEBUG)

def test_log_objects():
    r, w = os.pipe()

    os.dup2(w, 1) 

    logger.info({"a": 1})

    os.close(w)
    output = os.read(r, 1024).decode()

    assert "{'a': 1}" in output
