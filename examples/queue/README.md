# BroadcastQueue Example – `cykit.queue`

Example script demonstrating thread-safe message broadcasting using the `cykit.queue.BroadcastQueue` class in MPMC (Multiple Producers, Multiple Consumers) mode.

---


---

## Queue Modes

The `BroadcastQueue` module supports three operational modes:
- **SPSC** – Single Producer, Single Consumer
- **SPMC** – Single Producer, Multiple Consumers
- **MPSC** – Multiple Producers, Single Consumer
- **MPMC** – Multiple Producers, Multiple Consumers *(Demonstrated in example)*

---

## Important Usage Notes

- **Thread-Local Registration:** Every worker thread for SPMC, MPSC and MPMC modes **must** explicitly call `q.register_producer()` or 
`q.register_consumer()` inside its own thread context before pushing or popping messages.
- **Cleanup:** Always unregister producers/consumers (`q.unregister_producer()` / `q.unregister_consumer()`) upon worker exit, and invoke 
`q.close()` to cleanly release queue resources and signal closure to waiting workers.

---

## How to Run

Execute the example script to run a 5-second broadcast session featuring 2 producers and 2 consumers:

```shell
python mpmc_queue.py
```

---