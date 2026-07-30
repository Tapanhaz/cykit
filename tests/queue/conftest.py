import pathlib  # noqa: EXE002
import sys

import pyximport
from Cython.Compiler import Options
from Cython.Distutils import build_ext
from setuptools import Extension

from cykit._build.config import config

Options.get_directive_defaults()["freethreading_compatible"] = True

TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]

kwargs = config.get_extension_kwargs()
kwargs["include_dirs"] = [str(PROJECT_ROOT), *kwargs.get("include_dirs", [])]

pyximport.install(
    language_level=3,
    inplace=True,
    setup_args={
        "ext_modules": [
            Extension(name="bench", sources=[str(TESTS_DIR / "bench.pyx")], **kwargs)
        ],
        "cmdclass": {"build_ext": build_ext},
    },
    build_in_temp=False,
)

import bench  # type: ignore  # noqa: E402, F401
