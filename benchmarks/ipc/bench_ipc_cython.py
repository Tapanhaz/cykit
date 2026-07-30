"""
Driver for the cykit IPC cython-cython benchmark.

Reuses the existing tests/ipc/run_ipc_bench.py.
"""

import os
import sys
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
PROJECT_ROOT = HERE.parents[1]
TESTS_IPC_DIR = PROJECT_ROOT / "tests" / "ipc"

sys.path.insert(0, str(TESTS_IPC_DIR))

os.chdir(TESTS_IPC_DIR)
import _bench_ipc_loader  # noqa: E402,F401

from run_ipc_bench import run_ipc_pair  # noqa: E402

MSG_SIZE = 64
NUM_MSGS = 2_000_000

MODE_SPMC = 0
PAIR_PUSH_POP = 0


def main():
    prod_r, cons_r = run_ipc_pair(
        MODE_SPMC,
        PAIR_PUSH_POP,
        n_prod=1,
        n_cons=1,
        num_messages=NUM_MSGS,
        tag="global_bench",
        payload_size=MSG_SIZE,
    )

    prod = prod_r[0]
    cons = cons_r[0]

    prod_time = prod["sent"] / prod["mps"] if prod["mps"] else 0.0
    mib_per_sec = cons["gbps"] * 1e9 / (1024 * 1024) if cons["gbps"] else 0.0
    latency_us = 1e6 / cons["mps"] if cons["mps"] else 0.0

    print(f"Producer time : {prod_time:.6f} sec")
    print()
    print("========== cykit.ipc (Cython-Cython, SPMC push/pop) ==========")
    print(f"Messages      : {cons['received']:,}")
    print(f"Throughput    : {cons['mps']:,.0f} msg/sec")
    print(f"Bandwidth     : {mib_per_sec:.2f} MiB/sec")
    print(f"Avg Latency   : {latency_us:.3f} us/msg")
    if cons.get("corrupt"):
        print(f"WARNING       : {cons['corrupt']} corrupt messages detected")


if __name__ == "__main__":
    main()
