# cykit

[![PyPI version](https://badge.fury.io/py/cykit.svg)](https://badge.fury.io/py/cykit)
[![Build Status](https://github.com/Tapanhaz/cykit/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/Tapanhaz/cykit/actions)
[![Python Versions](https://img.shields.io/badge/python-3.9%7C3.10%7C3.11%7C3.12%7C3.13-green)](https://pypi.org/project/cykit/)
[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/Tapanhaz/cykit/blob/main/LICENSE-MIT)
[![Apache License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://github.com/Tapanhaz/cykit/blob/main/LICENSE-APACHE)
[![Code style: black](https://img.shields.io/badge/code%20style-black-000000.svg)](https://github.com/psf/black)
[![Downloads](https://pepy.tech/badge/cykit)](https://pepy.tech/project/cykit)

`cykit` is a collection cython utilities.

⚠️ **Warning:** This package is currently in an early phase of development.
APIs are unstable and may change without notice.

## Installation

`cykit` requires python 3.9 or greater. It is available on pypi. For installation run :

```bash
pip install cykit
```

## Components

### [cykit.cylogger](https://github.com/Tapanhaz/cykit/tree/main/cykit/cylogger)

`cylogger` is the initial component of the `cykit` collection.  
It is a thin wrapper around [spdlog](https://github.com/gabime/spdlog).

Detailed examples can be found here: [cykit/examples/cylogger](https://github.com/Tapanhaz/cykit/tree/main/examples/cylogger)

### [cykit.spsc_queue (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/spsc_queue)

Lock-free SPSC queue. (detailed documentation coming in a later update)

### [cykit.utils.msgbridge (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/utils/msgbridge)

Multi-mode message dispatcher to bridge Cython and Python, built on a lock-free SPSC queue.
(detailed documentation coming in a later update)

### [cykit.utils.signal_handler (cython only)](https://github.com/Tapanhaz/cykit/tree/main/cykit/utils/signal_handler)

Boost.Asio based cross platform signal handler
(detailed documentation to follow)

### [cykit.utils.boost](https://github.com/Tapanhaz/cykit/tree/main/cykit/utils/boost)

A vendored, dependency-resolved subset of Boost headers. Boost is provided as a curated header set to support Cython/C++
interop modules and to allow reuse across other projects without requiring a system-wide Boost installation..

Current version :: Boost 1.87.0

## Contribution

Contributions are welcome! Any kind of help — bug reports / suggestions, feature requests, or pull requests—is appreciated.

## License

This project is licensed under the [MIT License](LICENSE-MIT) and/or
[Apache License 2.0](LICENSE-APACHE). See the license files for details.
