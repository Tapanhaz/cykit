# conftest.py
import sys
import os

if sys.platform == "win32":
    from cykit._build.config import config
    _bin = config._get_openssl_bin_dir()
    if _bin:
        os.add_dll_directory(_bin)
        
import json
import socket
import subprocess
import sys
import threading
import time
import pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


import pytest

TESTS_DIR = pathlib.Path(__file__).resolve().parent
PYTHON = sys.executable
RUN_PY_TIMEOUT = 15


def wait_until(predicate, timeout=3.0, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


class TCPServer:
    def __init__(self, host="127.0.0.1", port=9001):
        self.messages = []
        self._lock = threading.Lock()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind((host, port))
        self._sock.listen()
        self._sock.settimeout(0.2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)

    def start(self):
        self._thread.start()

    def _accept_loop(self):
        while not self._stop.is_set():
            try:
                conn, addr = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self._handle, args=(conn, addr), daemon=True).start()

    def _handle(self, conn, addr):
        connected_at = time.time()
        conn.settimeout(2.0)
        chunks = []
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                chunks.append(data)
        except socket.timeout:
            pass
        finally:
            conn.close()
        with self._lock:
            self.messages.append({
                "data": b"".join(chunks),
                "client_port": addr[1],
                "connected_at": connected_at,
                "disconnected_at": time.time(),
            })

    def stop(self):
        self._stop.set()
        self._sock.close()
        self._thread.join(timeout=2)


class UDPServer:
    def __init__(self, host="127.0.0.1", port=4096):
        self.messages = []
        self._lock = threading.Lock()
        self._sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.bind((host, port))
        self._sock.settimeout(0.2)
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._recv_loop, daemon=True)

    def start(self):
        self._thread.start()

    def _recv_loop(self):
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            with self._lock:
                self.messages.append({"data": data, "received_at": time.time()})

    def stop(self):
        self._stop.set()
        self._sock.close()
        self._thread.join(timeout=2)


class HTTPServer:
    def __init__(self, host="0.0.0.0", port=8080):
        self.requests = []
        lock = threading.Lock()
        requests = self.requests

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(length).decode("utf-8", errors="replace")
                with lock:
                    requests.append({
                        "path": self.path,
                        "headers": dict(self.headers.items()),
                        "body": body,
                        "client_port": self.client_address[1],
                        "received_at": time.time(),
                    })
                payload = json.dumps({"status": "received"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                self.wfile.write(payload)
                self.wfile.flush()

            def log_message(self, fmt, *args):
                pass

        self._server = ThreadingHTTPServer((host, port), Handler)
        self._server.allow_reuse_address = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)


class SMTPServer:
    def __init__(self, host="127.0.0.1", port=1025):
        import socketserver

        self.emails = []
        lock = threading.Lock()
        emails = self.emails

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                connected_at = time.time()
                envelope = {"from": None, "to": None}
                self.wfile.write(b"220 localhost  SMTP\r\n")
                self.wfile.flush()
                while True:
                    line = self.rfile.readline()
                    if not line:
                        return
                    cmd = line.decode("utf-8", errors="replace").strip()
                    upper = cmd.upper()
                    if upper.startswith(("HELO", "EHLO")):
                        self._send(b"250 localhost\r\n")
                    elif upper.startswith("MAIL FROM"):
                        envelope["from"] = cmd.split(":", 1)[1].strip()
                        self._send(b"250 OK\r\n")
                    elif upper.startswith("RCPT TO"):
                        envelope["to"] = cmd.split(":", 1)[1].strip()
                        self._send(b"250 OK\r\n")
                    elif upper == "DATA":
                        self._send(b"354 End data with <CR><LF>.<CR><LF>\r\n")
                        lines = []
                        while True:
                            data = self.rfile.readline()
                            if not data or data == b".\r\n":
                                break
                            lines.append(data)
                        raw = b"".join(lines).decode("utf-8", errors="replace")
                        headers, _, body = raw.partition("\r\n\r\n")
                        with lock:
                            emails.append({
                                "envelope_from": envelope["from"],
                                "envelope_to": envelope["to"],
                                "headers": headers,
                                "body": body.strip(),
                                "connected_at": connected_at,
                            })
                        self._send(b"250 Message accepted\r\n")
                    elif upper == "QUIT":
                        self._send(b"221 Bye\r\n")
                        return
                    else:
                        self._send(b"250 OK\r\n")

            def _send(self, data):
                self.wfile.write(data)
                self.wfile.flush()

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True

            def handle_error(self, request, client_address):
                pass

        self._server = Server((host, port), Handler)
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=2)


@pytest.fixture(scope="module")
def _servers():
    tcp = TCPServer()
    udp = UDPServer()
    http = HTTPServer()
    smtp = SMTPServer()

    for s in (tcp, udp, http, smtp):
        s.start()

    yield {"tcp": tcp, "udp": udp, "http": http, "smtp": smtp}

    for s in (tcp, udp, http, smtp):
        s.stop()


@pytest.fixture(scope="module")
def run_logger(_servers):
    result = subprocess.run(
        [PYTHON, "-u", "run.py"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=RUN_PY_TIMEOUT,
        cwd= TESTS_DIR,
    )

    tcp, udp, http, smtp = (_servers[k] for k in ("tcp", "udp", "http", "smtp"))
    wait_until(lambda: len(tcp.messages) >= 6, timeout=3)
    wait_until(lambda: len(udp.messages) >= 6, timeout=3)
    wait_until(lambda: len(http.requests) >= 6, timeout=3)
    wait_until(lambda: len(smtp.emails) >= 2, timeout=3)

    return {
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stdout,
        **_servers,
    }