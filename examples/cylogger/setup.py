import sys
import cykit
from pathlib import Path
from Cython.Build import cythonize
from setuptools import setup, Extension
from cykit.build_config import config

extensions = [
    Extension("cy_module", sources=["cy_module.pyx"], **config.get_extension_kwargs())
]

setup(
    name="cy_module",
    ext_modules=cythonize(extensions, language_level=3),
)
