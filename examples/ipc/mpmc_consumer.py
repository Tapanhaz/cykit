from cykit.ipc import Consumer, ShmMode, IPCClosed
import msgspec

decoder = msgspec.msgpack.Decoder()

# The producer and consumer should be configured with same config
# and should use same push / pop methods

cons = Consumer("demo_shm", block_size=64)

while True:
    try:
        msg_b = cons.pop()
        msg = decoder.decode(msg_b)
        print(msg)
    except IPCClosed:
        break
