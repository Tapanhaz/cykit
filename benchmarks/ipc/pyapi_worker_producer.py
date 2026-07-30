import sys
import json
import time

from cykit.ipc import Producer, ShmMode

RESULT_MARKER = "RESULT_JSON:"


def main(name, block_count, block_size, num_messages, payload_size):
    prod = Producer(
        name, block_count=block_count, block_size=block_size, mode=ShmMode.SPMC
    )

    payload = b"x" * payload_size

    t0 = time.perf_counter_ns()
    for _ in range(num_messages):
        prod.push(payload)
    t1 = time.perf_counter_ns()

    elapsed_s = (t1 - t0) / 1e9

    return {
        "sent": num_messages,
        "bytes": num_messages * payload_size,
        "elapsed_s": elapsed_s,
        "mps": num_messages / elapsed_s if elapsed_s else 0.0,
    }


if __name__ == "__main__":
    name, block_count, block_size, n_msgs, pay_sz = sys.argv[1:6]
    result = main(name, int(block_count), int(block_size), int(n_msgs), int(pay_sz))
    sys.stdout.flush()
    print(RESULT_MARKER + json.dumps(result))
