# cykit

[![PyPI version](https://badge.fury.io/py/cykit.svg?v=0.0.9)](https://badge.fury.io/py/cykit)
[![Build Status](https://github.com/Tapanhaz/cykit/actions/workflows/release.yml/badge.svg)](https://github.com/Tapanhaz/cykit/actions)
[![Python Versions](https://img.shields.io/pypi/pyversions/cykit?color=green)](https://pypi.org/project/cykit/)
[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/Tapanhaz/cykit/blob/main/LICENSE-MIT)
[![Apache License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://github.com/Tapanhaz/cykit/blob/main/LICENSE-APACHE)
[![Code style: black](https://img.shields.io/badge/code%20style-black-000000.svg)](https://github.com/psf/black)
[![Downloads](https://pepy.tech/badge/cykit)](https://pepy.tech/project/cykit)

`cykit` is a collection Cython utilities.

## Installation

`cykit` requires python 3.9 or greater. It is available on pypi. To install, run:

```bash
pip install cykit
```

## Components

### [cykit.cylogger](https://github.com/Tapanhaz/cykit/tree/main/cykit/cylogger)

- `cylogger` is the initial component of the `cykit` collection.  
It is a thin wrapper around [spdlog](https://github.com/gabime/spdlog).

`cylogger` is designed to provide a unified logging interface across the entire stack — Python, underlying Cython layers,
and native C/C++ modules can all share the same logger instance and logging pipeline. This makes it easier to maintain consistent
formatting, sinks (console, file, rotating, daily, UDP, TCP, HTTP, SMTP), log levels, and tracing across mixed-language systems.

Detailed examples can be found here: [cykit/examples/cylogger](https://github.com/Tapanhaz/cykit/tree/main/examples/cylogger)

### [cykit.ipc](https://github.com/Tapanhaz/cykit/tree/main/cykit/ipc)

`cykit.ipc` provides a high-performance shared-memory IPC mechanism built around a ring-buffer design. 
It supports multiple producer/consumer topologies while exposing both a native Cython API and a Python-friendly API.

#### Features

- Shared-memory IPC for inter-process communication.
- Ring-buffer based message transport.
- Supports SPSC, SPMC, MPSC and MPMC modes.
- Native Cython API with an additional Python API.
- Blocking and non-blocking operations.
- Fixed-size and variable-size messages.
- Cross-platform (Linux, Windows and macOS).

Detailed examples can be found here: [cykit/examples/ipc](https://github.com/Tapanhaz/cykit/tree/main/examples/ipc)

#### Performance

Benchmark configuration:

- 1 Producer / 1 Consumer (separate processes)
- 64-byte fixed-size messages
- 2,000,000 messages
- Ubuntu Linux
- Python 3.12

> Results are measured on the author's development machine and are intended for relative comparison between implementations.

![cykit.ipc Benchmark](https://raw.githubusercontent.com/Tapanhaz/cykit/main/benchmarks/ipc/results/latest.png)
<!-- BENCH:IPC:START -->
| Implementation | msg/sec | MiB/sec | us/msg |
|---------------|--------:|--------:|-------:|
| **cykit.ipc (Cython-Cython)** | 12,641,965 | 771.60 | 0.079 |
| **cykit.ipc (Python API)** | 3,672,439 | 231.15 | 0.272 |
| multiprocessing.Pipe | 690,622 | 42.15 | 1.448 |
| multiprocessing.SimpleQueue | 234,203 | 14.29 | 4.270 |
| multiprocessing.shared_memory (ring) | 232,724 | 14.20 | 4.297 |
| multiprocessing.Queue | 172,548 | 10.53 | 5.796 |
<!-- BENCH:IPC:END -->

## [cykit.queue](https://github.com/Tapanhaz/cykit/tree/main/cykit/queue)

`cykit.queue` is a in-process Lock-free message queue based on ring buffer. It supports **SPSC**, **SPMC**, **MPSC**, and **MPMC** communication patterns while preserving **broadcast (fan-out)** semantics. 

### Features

- Broadcast (fan-out) semantics
- Supports SPSC, SPMC, MPSC, and MPMC
- Blocking and non-blocking operations
- Fixed-size message storage

Detailed examples can be found here: [cykit/examples/queue](https://github.com/Tapanhaz/cykit/tree/main/examples/queue)

### Performance

The following benchmark measures throughput using **64-byte fixed-size messages** with **2,000,000 messages** transferred between **one producer and one consumer (SPSC push/pop)**.

> **Note:** Python's standard library queues (`queue.Queue`, `queue.SimpleQueue`, and typical `collections.deque` implementations) provide **work-queue semantics**, where each message is consumed by only one consumer. `cykit.queue` provides **broadcast (fan-out)** semantics, allowing every consumer to receive every published message. To provide the closest comparable scenario, the benchmark below uses the **SPSC** configuration.

![cykit.queue Benchmark](https://raw.githubusercontent.com/Tapanhaz/cykit/main/benchmarks/queue/results/latest.png)
<!-- BENCH:QUEUE:START -->
| Implementation | Throughput | Bandwidth | Avg. Latency |
| :------------- | ---------: | --------: | -----------: |
| **cykit.queue (Cython API)** | 16.91 M msg/s | 1032.02 MiB/s | 0.059 μs |
| `queue.SimpleQueue` | 11.64 M msg/s | 710.17 MiB/s | 0.086 μs |
| **cykit.queue (Python API)** | 11.06 M msg/s | 675.29 MiB/s | 0.090 μs |
| `collections.deque` | 0.38 M msg/s | 23.28 MiB/s | 2.622 μs |
| `queue.Queue` | 0.32 M msg/s | 19.71 MiB/s | 3.097 μs |
<!-- BENCH:QUEUE:END -->


### [cykit.utils.msgbridge (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/utils/msgbridge)

- Multi-mode message dispatcher to bridge Cython and Python (Both synchronous and asynchronous), built on a lock-free SPSC queue.
(detailed documentation coming in a later update)

### [cykit.utils.transport (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/utils/transport)

- TCP, UDP, HTTP Synchronous Clients.
- SMTP client with OAuth2 (XOAUTH2) support.

### [cykit.utils.signal_handler (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/utils/signal_handler)

- Boost.Asio based cross platform signal handler. It register contexts to be notified on SIGINT/SIGTERM, with automatic 
cleanup and Python KeyboardInterrupt injection.
(detailed documentation to follow)

## Contribution

Contributions are welcome! Any kind of help — bug reports / suggestions, feature requests, or pull requests—is appreciated.

## License

This project is licensed under the [MIT License](https://github.com/Tapanhaz/cykit/blob/main/LICENSE-MIT) and/or
[Apache License 2.0](https://github.com/Tapanhaz/cykit/blob/main/LICENSE-APACHE). See the license files for details.

### Vendored Dependencies

This project vendors header‑only dependencies (Boost, spdlog, fmtlib) to simplify
builds and ensure compatibility across platforms. All vendored code retains its
original copyright and license terms.

- **[Boost 1.87.0](https://www.boost.org/)** – [Boost Software License 1.0](https://www.boost.org/LICENSE_1_0.txt)  
- **[spdlog 1.16.0](https://github.com/gabime/spdlog)** – [MIT License](https://github.com/gabime/spdlog/blob/v1.x/LICENSE)  
- **[fmtlib](https://github.com/fmtlib/fmt)** – [MIT License](https://github.com/fmtlib/fmt/blob/master/LICENSE)

All third‑party code retains its original copyright and license notices.  
The full license texts are included in the [`NOTICE.md`](https://github.com/Tapanhaz/cykit/blob/main/NOTICE.md) file at the root of this repository.