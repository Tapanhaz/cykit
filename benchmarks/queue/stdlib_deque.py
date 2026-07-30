import collections
import threading
import time

MSG_SIZE = 64
NUM_MSGS = 2_000_000

payload = b"x" * MSG_SIZE

dq = collections.deque()
cond = threading.Condition()


def producer(evt):

    evt.wait()

    t0 = time.perf_counter_ns()

    for _ in range(NUM_MSGS):

        with cond:
            dq.append(payload)
            cond.notify()

    with cond:
        dq.append(None)
        cond.notify()

    t1 = time.perf_counter_ns()

    print(f"Producer time : {(t1-t0)/1e9:.6f} sec")


def consumer(evt):

    evt.wait()

    first = None
    count = 0

    while True:

        with cond:
            while not dq:
                cond.wait()

            msg = dq.popleft()

        if first is None:
            first = time.perf_counter_ns()

        if msg is None:
            break

        count += 1

    end = time.perf_counter_ns()

    elapsed = (end - first) / 1e9

    print()
    print("========== collections.deque ==========")
    print(f"Messages      : {count:,}")
    print(f"Elapsed       : {elapsed:.6f} sec")
    print(f"Throughput    : {count/elapsed:,.0f} msg/sec")
    print(f"Bandwidth     : {(count*MSG_SIZE)/(1024*1024)/elapsed:.2f} MiB/sec")
    print(f"Avg Latency   : {elapsed*1e6/count:.3f} us/msg")


evt = threading.Event()

tp = threading.Thread(target=producer, args=(evt,))
tc = threading.Thread(target=consumer, args=(evt,))

tp.start()
tc.start()

time.sleep(1)
evt.set()

tp.join()
tc.join()
