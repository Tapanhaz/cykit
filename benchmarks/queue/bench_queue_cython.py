"""
Driver for the cykit queue cython-cython benchmark.
"""

import os
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parents[1]
TESTS_QUEUE_DIR = PROJECT_ROOT / "tests" / "queue"

sys.path.insert(0, str(TESTS_QUEUE_DIR))

os.chdir(TESTS_QUEUE_DIR)
import conftest  # noqa: E402,F401

from run_bench import run_bench_pair  # noqa: E402

MSG_SIZE = 64
NUM_MSGS = 2_000_0000

MODE_SPSC = 0
PAIR_PUSH_POP = 0


def main():
    prod_r, cons_r = run_bench_pair(
        MODE_SPSC,
        PAIR_PUSH_POP,
        n_prod=1,
        n_cons=1,
        num_messages=NUM_MSGS,
        payload_size=MSG_SIZE,
    )

    prod = prod_r[0]
    cons = cons_r[0]

    prod_time = prod["sent"] / prod["mps"] if prod["mps"] else 0.0
    mib_per_sec = cons["gbps"] * 1e9 / (1024 * 1024) if cons["gbps"] else 0.0
    latency_us = 1e6 / cons["mps"] if cons["mps"] else 0.0

    print(f"Producer time : {prod_time:.6f} sec")
    print()
    print("========== cykit.queue (Cython-Cython, SPSC push/pop) ==========")
    print(f"Messages      : {cons['received']:,}")
    print(f"Throughput    : {cons['mps']:,.0f} msg/sec")
    print(f"Bandwidth     : {mib_per_sec:.2f} MiB/sec")
    print(f"Avg Latency   : {latency_us:.3f} us/msg")
    if cons.get("discards"):
        print(f"Discards      : {cons['discards']}")
    if cons.get("resyncs"):
        print(f"Resyncs       : {cons['resyncs']}")


if __name__ == "__main__":
    main()
