
from Cython.Build import cythonize
from setuptools import setup, Extension
from cykit._build.config import config

extensions = [
    Extension(
        "cy_module", 
        sources=["cy_module.pyx"], 
        **config.get_extension_kwargs()
        )
]

setup(
    name="cy_module",
    ext_modules=cythonize(extensions, language_level=3),
)
