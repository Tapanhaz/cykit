import sys
import json
import time

from cykit.ipc import Consumer, ShmMode

RESULT_MARKER = "RESULT_JSON:"
READY_MARKER = "READY"


def main(name, block_count, block_size, num_messages):
    cons = Consumer(
        name, block_count=block_count, block_size=block_size, mode=ShmMode.SPMC
    )

    print(READY_MARKER, flush=True)

    first = None
    count = 0
    total_bytes = 0

    while count < num_messages:
        msg = cons.pop()

        if first is None:
            first = time.perf_counter_ns()

        total_bytes += len(msg)
        count += 1

    end = time.perf_counter_ns()
    elapsed_ns = end - first
    elapsed_s = elapsed_ns / 1e9

    return {
        "received": count,
        "bytes": total_bytes,
        "elapsed_s": elapsed_s,
        "mps": count / elapsed_s if elapsed_s else 0.0,
        "gbps": (total_bytes / elapsed_ns) if elapsed_ns else 0.0,
    }


if __name__ == "__main__":
    name, block_count, block_size, n_msgs = sys.argv[1:5]
    result = main(name, int(block_count), int(block_size), int(n_msgs))
    sys.stdout.flush()
    print(RESULT_MARKER + json.dumps(result))
