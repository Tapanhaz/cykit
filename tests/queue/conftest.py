import pathlib
import sys

import pytest
import pyximport
from setuptools import Extension
from Cython.Distutils import build_ext
from cykit._build.config import config

TESTS_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TESTS_DIR))

pyximport.install(
    language_level=3,
    inplace=True,
    setup_args={
        "ext_modules": [
            Extension(
                name="queuetest",
                sources=[str(TESTS_DIR / "queuetest.pyx")],
                **config.get_extension_kwargs(),
            )
        ],
        "cmdclass": {"build_ext": build_ext},
    },
)

import queuetest as qmod


@pytest.fixture(scope="session")
def queue_module():
    return qmod
