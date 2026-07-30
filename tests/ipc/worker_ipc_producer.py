import json
import sys

import _bench_ipc_loader
from bench_ipc import run_producer

RESULT_MARKER = "RESULT_JSON:"


def main(shm, sem, mode, pair, num_messages, payload_size, producer_id=0):
    return run_producer(
        shm.encode(),
        sem.encode(),
        mode=mode,
        pair=pair,
        num_messages=num_messages,
        payload_size=payload_size,
        producer_id=producer_id,
    )


if __name__ == "__main__":
    shm, sem, mode, pair, n_msgs, pay_sz = sys.argv[1:7]
    producer_id = int(sys.argv[7]) if len(sys.argv) > 7 else 0
    result = main(shm, sem, int(mode), int(pair), int(n_msgs), int(pay_sz), producer_id)
    sys.stdout.flush()
    print(RESULT_MARKER + json.dumps(result))
