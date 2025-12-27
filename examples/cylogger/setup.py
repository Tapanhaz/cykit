import sys
import cykit
from pathlib import Path
from Cython.Build import cythonize
from setuptools import setup, Extension

cykit_path = Path(cykit.__file__).parent
cylogger_path = str(cykit_path / "cylogger")
include_dirs = [cylogger_path, f"{cylogger_path}/include"]

extra_compile_args = []
extra_link_args = []
runtime_library_dirs = []

if sys.platform.startswith("win"):
    extra_compile_args = ["/std:c++latest", "/utf-8", "/O2", "/W3"]
elif sys.platform.startswith("darwin"):
    extra_compile_args = ["-std=c++20", "-O3", "-Wall"]
    extra_link_args = [f"-Wl,-rpath,{cylogger_path}"]
else:
    extra_compile_args = ["-std=c++20", "-O3", "-Wall"]
    runtime_library_dirs = include_dirs

extensions = [
    Extension(
        "cy_module",
        sources=["cy_module.pyx"],
        language="c++",
        extra_compile_args=extra_compile_args,
        extra_link_args=extra_link_args,
        include_dirs=include_dirs,
        libraries=["cylogger"],
        library_dirs=include_dirs,
        runtime_library_dirs=runtime_library_dirs,
    )
]

setup(
    name="cy_module",
    ext_modules=cythonize(extensions, language_level=3),
)
