import pathlib
import sys

import pytest
import pyximport
from setuptools import Extension
from Cython.Distutils import build_ext
from cykit._build.config import config

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
                name="queuetest",
                sources=[str(TESTS_DIR / "queuetest.pyx")],
                **kwargs,
            )
        ],
        "cmdclass": {"build_ext": build_ext},
    },
)

import queuetest as qmod


@pytest.fixture(scope="session")
def queue_module():
    return qmod
