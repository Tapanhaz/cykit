"""
2 producers + 2 consumers on cykit's BroadcastQueue (MPMC mode).
"""

import random
import threading
import time

from cykit.queue import BroadcastQueue, BroadcastMode, QueueClosed

RUN_SECONDS = 5


def producer_worker(q: BroadcastQueue, label: str, stop: threading.Event) -> None:
    # Must be called from *this* thread -- registration is thread-local.
    q.register_producer()
    try:
        while not stop.is_set():
            n = random.randint(0, 1000)
            try:
                q.push((label, n))
            except QueueClosed:
                break
            time.sleep(0.01)
    finally:
        q.unregister_producer()


def consumer_worker(
    q: BroadcastQueue, label: str, stop: threading.Event, verbose: bool
) -> None:
    # Must be called from *this* thread -- registration is thread-local.
    q.register_consumer()
    try:
        while not stop.is_set():
            try:
                msg = q.pop()
            except QueueClosed:
                break
            if verbose and msg is not None:
                who, value = msg
                print(f"[{label}] {who} -> {value}")
    finally:
        q.unregister_consumer()


def main() -> None:
    q = BroadcastQueue(
        capacity=1024,
        mode=BroadcastMode.MPMC,
        block_on_full=True,
    )
    stop = threading.Event()

    threads = [
        threading.Thread(target=producer_worker, args=(q, "P1", stop), daemon=True),
        threading.Thread(target=producer_worker, args=(q, "P2", stop), daemon=True),
        threading.Thread(
            target=consumer_worker, args=(q, "C1", stop, True), daemon=True
        ),
        threading.Thread(
            target=consumer_worker, args=(q, "C2", stop, True), daemon=True
        ),
    ]

    for t in threads:
        t.start()

    try:
        time.sleep(RUN_SECONDS)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        q.close(timeout_ms=1000)
        for t in threads:
            t.join(timeout=2)


if __name__ == "__main__":
    main()
