import sys
import pathlib
import pyximport
from setuptools import Extension
from Cython.Compiler import Options
from Cython.Distutils import build_ext
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
            Extension(
                name="bench_ipc", sources=[str(TESTS_DIR / "bench_ipc.pyx")], **kwargs
            )
        ],
        "cmdclass": {"build_ext": build_ext},
    },
)

import bench_ipc  # noqa E402
