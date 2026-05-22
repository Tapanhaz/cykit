## Quick Start

```python
from cykit.cylogger import Logger

logger = Logger("app")

logger.debug("This is a debug message.")
```

`cylogger` allows the same logger instance to be shared across Python,
underlying Cython layers, and native C/C++ modules, providing unified
logging across the full stack.

---

## Cross-module Logging

### Python submodule

```python
from cykit.cylogger import DefaultLogger

# Uses the logger set as default in the main module.
# Falls back to a null logger if no default logger exists.
log = DefaultLogger()

def py_func():
    log.debug("Debug message from Python submodule.")
```

### Cython submodule

```cython
from cykit.cylogger cimport TRACE, DEBUG, INFO, WARN, ERROR, CRITICAL

"""
Logging Macros for using in cython ::

- TRACE, DEBUG, INFO, WARN, ERROR, CRITICAL:
  Basic logging macros using the default logger.

- Macros with suffixes: - L: (e.g., TRACE_L, TRACE_CL, TRACE_FXL) Use with a specific logger instance - M: Use with a logger name - C: Individual custom colored log (Colors work on terminals only, File logs are plain text.) - FX: Macros with effects option
  """

cpdef cy_func():
TRACE("Trace message from Cython submodule")

```

### C++ submodule

```cpp
#include <spdlog_logger.hpp>

INFO("Info message from C++ module");
```

### Main module

```python
from cykit.cylogger import Logger

# Import py_func and cy_func from submodules

logger = Logger("app", set_default=True)

logger.info("Info message from main module.")

py_func()
cy_func()

```

## Example Files ::

This folder contains example Python and Cython files for more detailed demonstration.

### Build & Run ::

```bash
# Compile Cython extensions in-place
python setup.py build_ext --inplace

# Run the example
python cylogger_test.py
```
