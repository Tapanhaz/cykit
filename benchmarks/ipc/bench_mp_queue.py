import multiprocessing as mp
import time

MSG_SIZE = 64
NUM_MSGS = 2_000_000

payload = b"x" * MSG_SIZE


def producer(q, start_evt):
    start_evt.wait()

    t0 = time.perf_counter_ns()

    for _ in range(NUM_MSGS):
        q.put(payload)

    q.put(None)

    t1 = time.perf_counter_ns()

    print(f"Producer time : {(t1-t0)/1e9:.6f} sec")


def consumer(q, start_evt):
    start_evt.wait()

    first = None
    count = 0

    while True:
        msg = q.get()

        if first is None:
            first = time.perf_counter_ns()

        if msg is None:
            break

        count += 1

    end = time.perf_counter_ns()

    elapsed = (end - first) / 1e9

    msgs_per_sec = count / elapsed
    mb_per_sec = (count * MSG_SIZE) / (1024 * 1024) / elapsed
    latency_us = elapsed * 1e6 / count

    print()
    print("========== multiprocessing.Queue ==========")
    print(f"Messages      : {count:,}")
    print(f"Elapsed       : {elapsed:.6f} sec")
    print(f"Throughput    : {msgs_per_sec:,.0f} msg/sec")
    print(f"Bandwidth     : {mb_per_sec:.2f} MiB/sec")
    print(f"Avg Latency   : {latency_us:.3f} us/msg")


if __name__ == "__main__":
    mp.set_start_method("fork")

    q = mp.Queue(maxsize=4096)

    evt = mp.Event()

    p = mp.Process(target=producer, args=(q, evt))
    c = mp.Process(target=consumer, args=(q, evt))

    p.start()
    c.start()

    time.sleep(1)
    evt.set()

    p.join()
    c.join()
