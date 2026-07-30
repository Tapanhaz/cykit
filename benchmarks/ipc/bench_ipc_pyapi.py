"""
Benchmark for cykit's Python-facing IPC API (ipc.pyx: Producer / Consumer),
SPMC mode, one producer / one consumer, fixed 64-byte payload.
"""

import sys
import json
import threading
import subprocess
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
PY = sys.executable

RESULT_MARKER = "RESULT_JSON:"
READY_MARKER = "READY"

NAME = "cykit_bench_pyapi"
BLOCK_COUNT = 16384
BLOCK_SIZE = 2048
MSG_SIZE = 64
NUM_MSGS = 2_000_000
TIMEOUT = 120


class _ProcReader:
    def __init__(self, proc):
        self.proc = proc
        self.lines = []
        self.ready = threading.Event()
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._drain, daemon=True)
        self._thread.start()

    def _drain(self):
        for line in self.proc.stdout:
            with self._lock:
                self.lines.append(line)
            if line.strip() == READY_MARKER:
                self.ready.set()

    def wait_ready(self, timeout):
        if not self.ready.wait(timeout):
            self.proc.kill()
            raise TimeoutError("did not signal READY")

    def wait_done(self, timeout):
        rc = self.proc.wait(timeout=timeout)
        self._thread.join(timeout=5)
        return rc

    def result_json(self):
        with self._lock:
            for line in self.lines:
                if line.startswith(RESULT_MARKER):
                    return json.loads(line[len(RESULT_MARKER) :])
        return None

    def tail(self, n=40):
        with self._lock:
            return "".join(self.lines[-n:])


def main():
    cons_proc = subprocess.Popen(
        [
            PY,
            str(HERE / "pyapi_worker_consumer.py"),
            NAME,
            str(BLOCK_COUNT),
            str(BLOCK_SIZE),
            str(NUM_MSGS),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    cons_reader = _ProcReader(cons_proc)

    try:
        cons_reader.wait_ready(TIMEOUT)
    except TimeoutError as e:
        raise RuntimeError(
            f"consumer did not signal READY:\n{cons_reader.tail()}"
        ) from e

    prod_proc = subprocess.Popen(
        [
            PY,
            str(HERE / "pyapi_worker_producer.py"),
            NAME,
            str(BLOCK_COUNT),
            str(BLOCK_SIZE),
            str(NUM_MSGS),
            str(MSG_SIZE),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    prod_reader = _ProcReader(prod_proc)

    prc = prod_reader.wait_done(TIMEOUT)
    if prc != 0:
        raise RuntimeError(f"producer failed (rc={prc}):\n{prod_reader.tail()}")
    prod = prod_reader.result_json()

    crc = cons_reader.wait_done(TIMEOUT)
    if crc != 0:
        raise RuntimeError(f"consumer failed (rc={crc}):\n{cons_reader.tail()}")
    cons = cons_reader.result_json()

    mib_per_sec = cons["gbps"] * 1e9 / (1024 * 1024) if cons["gbps"] else 0.0
    latency_us = 1e6 / cons["mps"] if cons["mps"] else 0.0

    print(f"Producer time : {prod['elapsed_s']:.6f} sec")
    print()
    print("========== cykit.ipc (Python API, SPMC push/pop) ==========")
    print(f"Messages      : {cons['received']:,}")
    print(f"Throughput    : {cons['mps']:,.0f} msg/sec")
    print(f"Bandwidth     : {mib_per_sec:.2f} MiB/sec")
    print(f"Avg Latency   : {latency_us:.3f} us/msg")


if __name__ == "__main__":
    main()
