import sys
import time
import conftest
from bench import run_queue_bench

FIXED_PAYLOAD = 64
VAR_PAYLOAD   = 1024
NUM_MSG       = 2_000_000

MODE_NAME = {
    0: "SPSC",
    1: "SPMC",
    2: "MPSC",
    3: "MPMC",
}

PAIR_NAME = {
    0: "PUSH_POP",
    1: "PUSH_BORROW_COMMIT",
    2: "PUSH_VAR_POP_VAR",
    3: "TRY_PUSH_POP",
    4: "TRY_PUSH_VAR_POP_VAR",
}


def run_bench_pair(mode, pair, n_prod, n_cons, num_messages=NUM_MSG, payload_size=None):
    if payload_size is None:
        payload_size = VAR_PAYLOAD if pair in (2, 4) else FIXED_PAYLOAD
    return run_queue_bench(mode, pair, n_prod, n_cons,
                            num_messages=num_messages, payload_size=payload_size)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("usage: python3 run_bench.py <mode> <pair> <n_prod> <n_cons>")
        sys.exit(1)

    mode, pair, n_prod, n_cons = (int(a) for a in sys.argv[1:5])

    prod_r, cons_r = run_bench_pair(mode, pair, n_prod, n_cons)

    print()
    print("  " * 10, f"{MODE_NAME[mode]} <=====> {PAIR_NAME[pair]}"
          f"  (producers: {n_prod}, consumers: {n_cons})\n")
    for i, r in enumerate(prod_r):
        print(f"  producer[{i}]: {r['sent']} msgs  {r['mps']/1e6:.2f} M/s  "
              f"{r['gbps']:.3f} GB/s   Total: {r['bytes']/1048576:.3f} MB")
    for i, r in enumerate(cons_r):
        print(f"  consumer[{i}]: {r['received']} msgs  {r['mps']/1e6:.2f} M/s  "
              f"{r['gbps']:.3f} GB/s discards :: {r['discards']} resyncs :: {r['resyncs']} Total: {r['bytes']/1048576:.3f} MB")
