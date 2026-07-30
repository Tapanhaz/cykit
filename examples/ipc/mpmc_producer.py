from cykit.ipc import Producer, ShmMode

# the default msg kind is object, it uses msgspec encoder internally
prod = Producer("demo_shm", block_size=64, mode=ShmMode.MPMC)

for i in range(2000000):
    prod.push(i + 1)

prod_count = prod.detach()
if prod_count <= 0:  # Last producer
    prod.shutdown(-1)  # Last producer will do shm shutdown
# It will wait upto full drain of each consumer and set the closing flag
# In general the shm block will be available until the last process attached to it closes.
