import json
import sys

import _bench_ipc_loader
from bench_ipc import run_consumer

RESULT_MARKER = "RESULT_JSON:"


def main(shm, sem, mode, pair, num_messages):
    return run_consumer(
        shm.encode(),
        sem.encode(),
        mode=mode,
        pair=pair,
        num_messages=num_messages,
    )


if __name__ == "__main__":
    shm, sem, mode, pair, n_msgs = sys.argv[1:6]
    result = main(shm, sem, int(mode), int(pair), int(n_msgs))
    sys.stdout.flush()
    print(RESULT_MARKER + json.dumps(result))
