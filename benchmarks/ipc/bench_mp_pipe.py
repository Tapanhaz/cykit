import multiprocessing as mp
import time

MSG_SIZE = 64
NUM_MSGS = 2_000_000

payload = b"x" * MSG_SIZE


def producer(conn, evt):
    evt.wait()

    t0 = time.perf_counter_ns()

    for _ in range(NUM_MSGS):
        conn.send_bytes(payload)

    conn.send_bytes(b"")

    t1 = time.perf_counter_ns()

    print(f"Producer time : {(t1 - t0) / 1e9:.6f} sec")


def consumer(conn, evt):
    evt.wait()

    first = None
    count = 0

    while True:
        msg = conn.recv_bytes()

        if first is None:
            first = time.perf_counter_ns()

        if len(msg) == 0:
            break

        count += 1

    end = time.perf_counter_ns()

    elapsed = (end - first) / 1e9

    print()
    print("========== multiprocessing.Pipe ==========")
    print(f"Messages      : {count:,}")
    print(f"Elapsed       : {elapsed:.6f} sec")
    print(f"Throughput    : {count / elapsed:,.0f} msg/sec")
    print(f"Bandwidth     : {(count * MSG_SIZE) / (1024 * 1024) / elapsed:.2f} MiB/sec")
    print(f"Avg Latency   : {elapsed * 1e6 / count:.3f} us/msg")


if __name__ == "__main__":
    mp.set_start_method("fork")

    parent, child = mp.Pipe(duplex=False)

    evt = mp.Event()

    p = mp.Process(target=producer, args=(child, evt))
    c = mp.Process(target=consumer, args=(parent, evt))

    p.start()
    c.start()

    time.sleep(1)
    evt.set()

    p.join()
    c.join()
