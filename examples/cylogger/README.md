## Quick start ::

```python
from cykit.cylogger import Logger

logger = Logger("app")

logger.debug("This is a debug message.")
```

# Cross-module logging ::

```python
# In python sub module ::
from cykit.cylogger import DefaultLogger

# Uses the logger that set as default in main | null logger
log = DefaultLogger()

def py_func():
    log.debug("Debug message from py sub module.")

# In cython sub module
from cykit.cylogger cimport TRACE, DEBUG, INFO, WARN, ERROR, CRITICAL

"""
Logging Macros for using in cython ::

- TRACE, DEBUG, INFO, WARN, ERROR, CRITICAL:
    Basic logging macros using the default logger.

- Macros with suffixes:
    - L: (e.g., TRACE_L, TRACE_CL, TRACE_FXL) Use with a specific logger instance
    - M: Use with a logger name
    - C: Individual custom colored log (Colors work on terminals only, File logs are plain text.)
    - FX: Macros with effects option
"""

cpdef cy_func():
    TRACE("This is a trace msg from cython sub module")

# In main module ::

from cykit.cylogger import Logger
# Import py_func and cy_func from the sub modules

logger = Logger("app", set_default= True)

logger.info("This is an info message from main.")

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
