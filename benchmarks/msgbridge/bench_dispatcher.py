"""
Cykit msgbridge (SyncDispatcher / AsyncDispatcher) benchmark.
"""

import os  # noqa: I001
import sys
import time
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parents[1]
TESTS_MSGBRIDGE_DIR = PROJECT_ROOT / "tests" / "msgbridge"

sys.path.insert(0, str(TESTS_MSGBRIDGE_DIR))

os.chdir(TESTS_MSGBRIDGE_DIR)
import conftest  # noqa: E402, F401, I001

from dispatcher_bench import (  # type: ignore
    run_async_dispatcher_bench,
    run_sync_dispatcher_bench,
)

NUM_MESSAGES_SYNC = 2_000_000
NUM_MESSAGES_ASYNC = 2_000_000

PAYLOAD_FIXED = 64
PAYLOAD_VARIABLE = 128

SYNC_CASES = [
    (variable_size, nonblocking)
    for variable_size in (False, True)
    for nonblocking in (True, False)
]
ASYNC_CASES = [False, True]


import uvloop

uvloop.install()


def _mps(msgs, elapsed_s):
    return (msgs / elapsed_s / 1e6) if elapsed_s > 0 else 0.0


def _gbps(total_bytes, elapsed_s):
    return (total_bytes / elapsed_s / 1e9) if elapsed_s > 0 else 0.0


def _run_sync_case(variable_size, nonblocking):
    label = f"sync  variable={variable_size!s:<5} nonblocking={nonblocking!s:<5}"
    t0 = time.perf_counter()
    r = run_sync_dispatcher_bench(
        num_messages=NUM_MESSAGES_SYNC,
        payload_size=PAYLOAD_VARIABLE if variable_size else PAYLOAD_FIXED,
        variable_size=variable_size,
        nonblocking=nonblocking,
        raw=True,
    )
    wall_s = time.perf_counter() - t0

    if r["timed_out"] or r["sent"] != NUM_MESSAGES_SYNC or r["received"] != r["sent"]:
        return label, None

    producer_mps = _mps(r["sent"], r["elapsed_ns"] / 1e9)
    e2e_mps = _mps(r["received"], wall_s)
    e2e_gbps = _gbps(r["bytes"], wall_s)
    return label, (producer_mps, e2e_mps, e2e_gbps)


def _run_async_case(variable_size):
    label = f"async variable={variable_size!s:<5}"
    t0 = time.perf_counter()
    r = run_async_dispatcher_bench(
        num_messages=NUM_MESSAGES_ASYNC,
        payload_size=PAYLOAD_VARIABLE if variable_size else PAYLOAD_FIXED,
        variable_size=variable_size,
        raw=True,
    )
    wall_s = time.perf_counter() - t0

    if r["timed_out"] or r["sent"] != NUM_MESSAGES_ASYNC or r["received"] != r["sent"]:
        return label, None

    producer_mps = _mps(r["sent"], r["elapsed_ns"] / 1e9)
    e2e_mps = _mps(r["received"], wall_s)
    e2e_gbps = _gbps(r["bytes"], wall_s)
    return label, (producer_mps, e2e_mps, e2e_gbps)


def main():
    rows = []

    for variable_size, nonblocking in SYNC_CASES:
        rows.append(_run_sync_case(variable_size, nonblocking))

    for variable_size in ASYNC_CASES:
        rows.append(_run_async_case(variable_size))

    print()
    print("========== cykit.msgbridge (SyncDispatcher / AsyncDispatcher) ==========")
    print(f"{'case':<38} {'producer M/s':>14} {'end-to-end M/s':>16} {'GB/s':>8}")
    print("-" * 80)
    for label, result in rows:
        if result is None:
            print(f"{label:<38} {'FAILED':>14}")
            continue
        producer_mps, e2e_mps, e2e_gbps = result
        print(f"{label:<38} {producer_mps:>14,.2f} {e2e_mps:>16,.2f} {e2e_gbps:>8.3f}")
    print("-" * 80)
    print(
        f"payload sizes: fixed={PAYLOAD_FIXED}B, variable~{PAYLOAD_VARIABLE}B  "
        f"|  messages: sync={NUM_MESSAGES_SYNC:,}, async={NUM_MESSAGES_ASYNC:,}"
    )


if __name__ == "__main__":
    main()
