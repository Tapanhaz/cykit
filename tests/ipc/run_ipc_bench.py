#!

import hashlib
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import _bench_ipc_loader

HERE = Path(__file__).resolve().parent
PY = sys.executable
RESULT_MARKER = "RESULT_JSON:"
READY_MARKER = "READY"


FIXED_PAYLOAD = 64
VAR_PAYLOAD = 1024

NUM_MSG = 2_000_0000

MODE_NAME = {
    0: "SPMC",
    1: "MPSC",
    2: "MPMC",
}

PAIR_NAME = {
    0: "PUSH_POP",
    1: "PUSH_BORROW_COMMIT",
    2: "PUSH_VAR_POP_VAR",
    3: "TRY_PUSH_POP",
    4: "TRY_PUSH_VAR_POP_VAR",
}


PAIR_ABBR = {
    0: "P_P",
    1: "PBC",
    2: "PV_PV",
    3: "TP_TP",
    4: "TPV_TPV",
}

IS_CI = os.environ.get("GITHUB_ACTIONS", "").strip().lower() in ("1", "true", "yes")

MODE_COUNTS = (
    [(0, 1, 2), (1, 2, 1), (2, 2, 2)] if IS_CI else [(0, 1, 3), (1, 3, 1), (2, 2, 2)]
)


def _short_id(tag):
    return hashlib.blake2b(tag.encode("utf-8"), digest_size=2).hexdigest()


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
        print(
            f"PROCESS EXIT pid={self.proc.pid} rc={self.proc.wait()}",
            flush=True,
        )

    def wait_ready(self, timeout):
        if not self.ready.wait(timeout):
            self.proc.kill()
            raise TimeoutError("did not signal READY")

    def wait_done(self, timeout):
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(
                f"[STUCK] pid={self.proc.pid} no exit within {timeout}s\n"
                f"--- last output ---\n{self.tail(80)}\n--- end ---",
                flush=True,
            )
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            raise
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


def run_ipc_pair(
    mode,
    pair,
    n_prod,
    n_cons,
    num_messages=20_000,
    tag="",
    timeout=30,
    payload_size=None,
):
    if payload_size is None:
        payload_size = VAR_PAYLOAD if pair in (2, 4) else FIXED_PAYLOAD

    base = f"{MODE_NAME[mode]}_{PAIR_ABBR[pair]}_{_short_id(tag)}"
    shm = f"{base}_shm"
    sem = f"{base}_sem"

    all_readers = []

    def _kill_all():
        for r in all_readers:
            try:
                if r.proc.poll() is None:
                    r.proc.kill()
            except Exception:  # noqa: S110
                pass
        for r in all_readers:
            try:
                r.proc.wait(timeout=5)
            except Exception:  # noqa: S110
                pass

    try:
        cons_readers = []
        for _ in range(n_cons):
            p = subprocess.Popen(
                [
                    PY,
                    str(HERE / "worker_ipc_consumer.py"),
                    shm,
                    sem,
                    str(mode),
                    str(pair),
                    str(num_messages),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            print(f"LAUNCHED CONSUMER pid={p.pid} mode={mode} pair={pair}", flush=True)
            reader = _ProcReader(p)
            cons_readers.append(reader)
            all_readers.append(reader)

        for i, r in enumerate(cons_readers):
            try:
                r.wait_ready(timeout)
            except TimeoutError as e:
                for other in cons_readers:
                    other.proc.kill()
                raise RuntimeError(
                    f"Consumer[{i}] did not signal READY within {timeout}s"
                ) from e

        for i, r in enumerate(cons_readers):
            print(
                f"CONSUMER[{i}] pid={r.proc.pid} alive={r.proc.poll() is None} rc={r.proc.poll()}",
                flush=True,
            )

        prod_readers = []
        for pidx in range(n_prod):
            p = subprocess.Popen(
                [
                    PY,
                    str(HERE / "worker_ipc_producer.py"),
                    shm,
                    sem,
                    str(mode),
                    str(pair),
                    str(num_messages),
                    str(payload_size),
                    str(pidx),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                stdin=subprocess.PIPE,
            )
            print(f"LAUNCHED PRODUCER pid={p.pid} mode={mode} pair={pair}", flush=True)
            reader = _ProcReader(p)
            prod_readers.append(reader)
            all_readers.append(reader)

        for i, r in enumerate(prod_readers):
            print(
                f"PRODUCER[{i}] pid={r.proc.pid} alive={r.proc.poll() is None} rc={r.proc.poll()}",
                flush=True,
            )

        for i, r in enumerate(prod_readers):
            try:
                r.wait_ready(timeout)
            except TimeoutError as e:
                raise RuntimeError(
                    f"Producer[{i}] did not signal READY within {timeout}s"
                ) from e

        for r in prod_readers:
            r.proc.stdin.write("go\n")
            r.proc.stdin.flush()

        prod_results = []
        for r in prod_readers:
            rc = r.wait_done(timeout)
            if rc != 0:
                raise RuntimeError(f"Producer failed (rc={rc}):\n{r.tail()}")
            result = r.result_json()
            if result is not None:
                prod_results.append(result)

        cons_results = []
        for r in cons_readers:
            rc = r.wait_done(timeout)
            if rc != 0:
                raise RuntimeError(f"Consumer failed (rc={rc}):\n{r.tail()}")
            result = r.result_json()
            if result is not None:
                cons_results.append(result)

        return prod_results, cons_results

    except Exception:
        _kill_all()
        raise
    finally:
        _kill_all()


if __name__ == "__main__":
    PAIRS = [
        (mode, pair, n_prod, n_cons)
        for mode, n_prod, n_cons in MODE_COUNTS
        for pair in range(5)
    ]

    print("\n")

    for idx, (mode, pair, n_prod, n_cons) in enumerate(PAIRS):
        payload = VAR_PAYLOAD if pair in (2, 4) else FIXED_PAYLOAD

        try:
            prod_r, cons_r = run_ipc_pair(
                mode,
                pair,
                n_prod,
                n_cons,
                num_messages=NUM_MSG,
                tag="manual",
                payload_size=payload,
                timeout=90,
            )
        except Exception as exc:
            print(f"mode={mode}, pair={pair}: FAILED\n{exc}")
            continue

        print("  " * 10, f"{MODE_NAME[mode]} <=====> {PAIR_NAME[pair]}\n")

        for i, r in enumerate(prod_r):
            print(
                f"  producer[{i}]: {r["sent"]} msgs  {r['mps']/1e6:.2f} M/s  {r['gbps']:.3f} GB/s   Total: {r["bytes"]/1048576:.3f} MB"
            )
        for i, r in enumerate(cons_r):
            print(
                f"  consumer[{i}]: {r["received"]} msgs  {r['mps']/1e6:.2f} M/s  {r['gbps']:.3f} GB/s   Total: {r["bytes"]/1048576:.3f} MB"
            )

        if idx != len(PAIRS) - 1:
            print("\n", "==X=" * 20, "\n")

        time.sleep(0.5)
