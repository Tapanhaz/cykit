# cykit

[![PyPI version](https://badge.fury.io/py/cykit.svg?v=0.0.9)](https://badge.fury.io/py/cykit)
[![Build Status](https://github.com/Tapanhaz/cykit/actions/workflows/release.yml/badge.svg)](https://github.com/Tapanhaz/cykit/actions)
[![Python Versions](https://img.shields.io/badge/python-3.9%7C3.10%7C3.11%7C3.12%7C3.13%7C3.14-green)](https://pypi.org/project/cykit/)
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

### [cykit.queue (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/queue)

- Lock-free queue based on ring buffer with support for SPSC, SPMC, MPSC and MPMC modes.

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

This project is licensed under the [MIT License](LICENSE-MIT) and/or
[Apache License 2.0](LICENSE-APACHE). See the license files for details.

### Vendored Dependencies

This project vendors header‑only dependencies (Boost, spdlog, fmtlib) to simplify
builds and ensure compatibility across platforms. All vendored code retains its
original copyright and license terms.

- **[Boost 1.87.0](https://www.boost.org/)** – [Boost Software License 1.0](https://www.boost.org/LICENSE_1_0.txt)  
- **[spdlog 1.16.0](https://github.com/gabime/spdlog)** – [MIT License](https://github.com/gabime/spdlog/blob/v1.x/LICENSE)  
- **[fmtlib](https://github.com/fmtlib/fmt)** – [MIT License](https://github.com/fmtlib/fmt/blob/master/LICENSE)

All third‑party code retains its original copyright and license notices.  
The full license texts are included in the [`NOTICE.md`](NOTICE.md) file at the root of this repository.