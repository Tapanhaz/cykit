from Cython.Build import cythonize
from setuptools import setup, Extension
from cykit._build.config import config

extensions = [
    Extension("bench", sources=["bench.pyx"], **config.get_extension_kwargs())
]

setup(
    name="bench",
    ext_modules=cythonize(extensions, language_level=3),
)
