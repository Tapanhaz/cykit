import multiprocessing as mp
from multiprocessing import shared_memory
import struct
import time

BLOCK_COUNT = 16384
BLOCK_SIZE = 2048

MSG_SIZE = 64
NUM_MSGS = 2_000_000

HEAD_OFF = 0
TAIL_OFF = 8
DATA_OFF = 16

SHM_SIZE = DATA_OFF + BLOCK_COUNT * BLOCK_SIZE

payload = b"x" * MSG_SIZE


def producer(name, cond, evt):
    shm = shared_memory.SharedMemory(name=name)
    buf = shm.buf

    evt.wait()

    t0 = time.perf_counter_ns()

    for _ in range(NUM_MSGS):

        with cond:

            head = struct.unpack_from("Q", buf, HEAD_OFF)[0]
            tail = struct.unpack_from("Q", buf, TAIL_OFF)[0]

            while (head + 1) % BLOCK_COUNT == tail:
                cond.wait()
                head = struct.unpack_from("Q", buf, HEAD_OFF)[0]
                tail = struct.unpack_from("Q", buf, TAIL_OFF)[0]

            off = DATA_OFF + head * BLOCK_SIZE
            buf[off : off + MSG_SIZE] = payload

            head = (head + 1) % BLOCK_COUNT
            struct.pack_into("Q", buf, HEAD_OFF, head)

            cond.notify(1)

    t1 = time.perf_counter_ns()

    print(f"Producer time : {(t1 - t0)/1e9:.6f} sec")

    shm.close()


def consumer(name, cond, evt):
    shm = shared_memory.SharedMemory(name=name)
    buf = shm.buf

    evt.wait()

    first = None
    count = 0

    while count < NUM_MSGS:

        with cond:

            head = struct.unpack_from("Q", buf, HEAD_OFF)[0]
            tail = struct.unpack_from("Q", buf, TAIL_OFF)[0]

            while head == tail:
                cond.wait()
                head = struct.unpack_from("Q", buf, HEAD_OFF)[0]
                tail = struct.unpack_from("Q", buf, TAIL_OFF)[0]

            if first is None:
                first = time.perf_counter_ns()

            off = DATA_OFF + tail * BLOCK_SIZE

            msg = bytes(buf[off : off + MSG_SIZE])

            tail = (tail + 1) % BLOCK_COUNT
            struct.pack_into("Q", buf, TAIL_OFF, tail)

            cond.notify(1)

        count += 1

    end = time.perf_counter_ns()

    elapsed = (end - first) / 1e9

    print()
    print("========== multiprocessing.shared_memory (ring) ==========")
    print(f"Messages      : {count:,}")
    print(f"Elapsed       : {elapsed:.6f} sec")
    print(f"Throughput    : {count/elapsed:,.0f} msg/sec")
    print(f"Bandwidth     : {(count*MSG_SIZE)/(1024*1024)/elapsed:.2f} MiB/sec")
    print(f"Avg Latency   : {elapsed*1e6/count:.3f} us/msg")

    shm.close()


if __name__ == "__main__":

    mp.set_start_method("fork")

    shm = shared_memory.SharedMemory(create=True, size=SHM_SIZE)

    struct.pack_into("Q", shm.buf, HEAD_OFF, 0)
    struct.pack_into("Q", shm.buf, TAIL_OFF, 0)

    cond = mp.Condition()
    evt = mp.Event()

    p = mp.Process(target=producer, args=(shm.name, cond, evt))
    c = mp.Process(target=consumer, args=(shm.name, cond, evt))

    p.start()
    c.start()

    time.sleep(1)
    evt.set()

    p.join()
    c.join()

    shm.close()
    shm.unlink()
