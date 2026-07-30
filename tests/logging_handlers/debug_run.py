import sys
import os
import subprocess

script_dir = os.path.dirname(os.path.abspath(__file__))
os.chdir(script_dir)
sys.path.insert(0, script_dir)
from conftest import TCPServer, UDPServer, HTTPServer, SMTPServer

servers = [TCPServer(), UDPServer(), HTTPServer(), SMTPServer()]
for s in servers:
    s.start()

subprocess.run(
    [
        "gdb",
        "-batch",
        "-ex",
        "set pagination off",
        "-ex",
        "run",
        "-ex",
        "thread apply all bt full",
        "-ex",
        "quit",
        "--args",
        sys.executable,
        "-u",
        "run.py",
    ],
    cwd=script_dir,
)

for s in servers:
    s.stop()
