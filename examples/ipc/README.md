# IPC Example Scripts – `cykit.ipc` Producer/Consumer

Example scripts demonstrating inter-process communication (IPC) via shared memory using the `cykit.ipc` module. 

The module supports three queue modes:
- **SPMC** – Single Producer, Multiple Consumers (default)
- **MPMC** – Multiple Producers, Multiple Consumers
- **MPSC** – Multiple Producers, Single Consumer

Providing examples for spmc and mpmc modes. mpsc usage is also almost identical but it supports only one consumer.
---



---

## Mode Overview

| Mode | Configuration | Scripts | Description |
| :--- | :--- | :--- | :--- |
| **SPMC** | `ShmMode.SPMC` | `spmc_producer.py`, `spmc_consumer.py` | Only **one** producer process is allowed. |
| **MPMC** | `ShmMode.MPMC` | `mpmc_producer.py`, `mpmc_consumer.py` | **Multiple** producer processes can write concurrently. |

> **Important: Processes connect to shared memory blocks by name (multiple isolated blocks can be instantiated using distinct names). Producers and consumers intending to share a queue must use the exact same name, block_size, and mode—parameter mismatches on the same block will cause undefined behavior.

---

## How to Run

1. **Start consumers first** (in separate terminals). They will block and wait for messages.
2. **Start producer(s)** (in separate terminals). They push messages and cleanly detach.
3. Consumers exit gracefully once all messages are processed and the queue shuts down.

### SPMC Example

```bash
# Terminal 1 & 2 (Consumers)
python spmc_consumer.py

# Terminal 3 (Only ONE Producer)
python spmc_producer.py
```

### MPMC Example

```bash
# Terminal 1 & 2 (Consumers)
python mpmc_consumer.py

# Terminal 3 & 4 (Multiple Producers)
python mpmc_producer.py
```

---


## Cleanup & Resource Management

- **Automatic destruction:** The shared memory block is removed when the last attached process disconnects. The first process to connect (producer or consumer) creates the shared memory block, and the last process to detach destroys it—creation and cleanup are not restricted to either role
- **Graceful termination:** The final producer marks the queue as closed using `shutdown(-1)`, causing `cons.pop()` full drain on all active consumers to raise `IPCClosed` and exit cleanly.