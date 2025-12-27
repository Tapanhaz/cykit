import os
import sys
import platform
import subprocess
import multiprocessing
from pathlib import Path
from Cython.Build import cythonize
from setuptools.command.build_ext import build_ext
from setuptools import setup, Extension, find_packages


class BuildExt(build_ext):

    def run(self):
        self.build_all_cmake_subprojects()
        self.add_cmake_deps_to_extensions()
        super().run()

    def add_cmake_deps_to_extensions(self):
        for ext in self.extensions:
            ext_source_dir = Path(ext.sources[0]).parent
            cmake_build_dir = ext_source_dir / "build"

            if not cmake_build_dir.exists():
                continue

            deps_dir = cmake_build_dir / "_deps"
            if deps_dir.exists():
                for dep_dir in deps_dir.iterdir():
                    if dep_dir.is_dir():
                        include_dir = dep_dir / "include"
                        if include_dir.exists():
                            ext.include_dirs.append(str(include_dir))
                            print(f"Added {dep_dir.name} include to {ext.name}")

    def build_all_cmake_subprojects(self):
        for cmake_file in Path(".").rglob("CMakeLists.txt"):
            cmake_source_dir = cmake_file.parent

            if "build" in cmake_source_dir.parts:
                continue
            self.build_cmake(cmake_source_dir)

    def build_cmake(self, cmake_source_dir: Path):
        cmake_source_dir = cmake_source_dir.resolve()
        cmake_build_dir = cmake_source_dir / "build"
        cmake_build_dir.mkdir(exist_ok=True)

        num_jobs = multiprocessing.cpu_count()

        print(
            f"Building {cmake_source_dir.name} with CMake (using {num_jobs} cores)..."
        )

        cmake_args = [
            "cmake",
            str(cmake_source_dir),
            "-DCMAKE_BUILD_TYPE=Release",
        ]

        if platform.system() == "Windows":
            try:
                subprocess.run(
                    ["clang-cl", "--version"], capture_output=True, check=True
                )
                cmake_args.extend(
                    [
                        "-DCMAKE_C_COMPILER=clang-cl",
                        "-DCMAKE_CXX_COMPILER=clang-cl",
                    ]
                )

                print("Using clang-cl on Windows")
            except (subprocess.CalledProcessError, FileNotFoundError):
                print("Using MSVC on Windows")
                pass
        else:

            if platform.system() == "Darwin":
                archs = os.environ.get("CIBW_ARCHS_MACOS", "")
                if archs:
                    if archs == "native":
                        archs = platform.machine()
                    else:
                        archs = archs.replace(" ", ";")
                    cmake_args.append(f"-DCMAKE_OSX_ARCHITECTURES={archs}")

                deployment_target = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "13.0")
                cmake_args.append(f"-DCMAKE_OSX_DEPLOYMENT_TARGET={deployment_target}")

            cc = os.environ.get("CC")
            cxx = os.environ.get("CXX")

            if cc:
                cmake_args.append(f"-DCMAKE_C_COMPILER={cc}")
            if cxx:
                cmake_args.append(f"-DCMAKE_CXX_COMPILER={cxx}")

            cmake_args.append("-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON")

        build_args = [
            "cmake",
            "--build",
            ".",
            "--config",
            "Release",
            "--parallel",
            str(num_jobs),
        ]

        try:
            subprocess.check_call(cmake_args, cwd=cmake_build_dir)
            subprocess.check_call(build_args, cwd=cmake_build_dir)
        except subprocess.CalledProcessError:
            print(
                f"CMake build failed for {cmake_source_dir}", file=sys.stderr
            )  # noqa E501
            raise

        self.vendor_headers(cmake_source_dir)

        print(f"{cmake_source_dir.name} built successfully")

        #print(f"\n{'='*60}")
        #print(f"DEBUG: Contents of {cmake_build_dir}:")
        #for item in cmake_build_dir.rglob("*"):
        #    if item.is_file():
        #        print(f"  {item.relative_to(cmake_build_dir)}")
        #print(f"{'='*60}\n")

        if platform.system() == "Windows":
            search_paths = [cmake_build_dir / "Release", cmake_build_dir]
        else:
            search_paths = [cmake_build_dir]

        if platform.system() == "Windows":
            lib_pattern = "*.dll"
        elif platform.system() == "Darwin":
            lib_pattern = "lib*.dylib*"
        else:
            lib_pattern = "lib*.so*"

        for search_path in search_paths:
            if not search_path.exists():
                continue

            for lib_file in search_path.glob(lib_pattern):
                dest_source = cmake_source_dir / lib_file.name
                dest_source.write_bytes(lib_file.read_bytes())
                dest_source.chmod(lib_file.stat().st_mode)
                print(f"Copied {lib_file.name} to {dest_source}")

                rel_path = cmake_source_dir.relative_to(Path.cwd())
                build_lib = Path(self.build_lib) / rel_path
                build_lib.mkdir(parents=True, exist_ok=True)
                dest_build = build_lib / lib_file.name
                dest_build.write_bytes(lib_file.read_bytes())
                dest_build.chmod(lib_file.stat().st_mode)
                print(f"Copied {lib_file.name} to {dest_build}")

        if platform.system() == "Windows":
            for search_path in search_paths:
                if not search_path.exists():
                    continue

                for lib_file in search_path.glob("*.lib"):
                    if lib_file.name in ["fmt.lib", "spdlog.lib"]:
                        continue

                    dest_source = cmake_source_dir / lib_file.name
                    dest_source.write_bytes(lib_file.read_bytes())
                    print(f"Copied {lib_file.name} to {dest_source}")

                    rel_path = cmake_source_dir.relative_to(Path.cwd())
                    build_lib = Path(self.build_lib) / rel_path
                    build_lib.mkdir(parents=True, exist_ok=True)
                    dest_build = build_lib / lib_file.name
                    dest_build.write_bytes(lib_file.read_bytes())
                    print(f"Copied {lib_file.name} to {dest_build}")

                if any(search_path.glob("*.lib")):
                    break

        if platform.system() == "Darwin":
            for search_path in search_paths:
                if not search_path.exists():
                    continue

                dylib_files = []
                dylib_files.extend(search_path.glob("*.dylib"))
                dylib_files.extend(search_path.glob("*.*.dylib"))
                dylib_files.extend(search_path.glob("*.*.*.dylib"))

                for lib_file in dylib_files:
                    dest_source = cmake_source_dir / lib_file.name
                    dest_source.write_bytes(lib_file.read_bytes())
                    dest_source.chmod(lib_file.stat().st_mode)
                    print(f"Copied dylib variant: {lib_file.name} to {dest_source}")

                    rel_path = cmake_source_dir.relative_to(Path.cwd())
                    build_lib = Path(self.build_lib) / rel_path
                    build_lib.mkdir(parents=True, exist_ok=True)
                    dest_build = build_lib / lib_file.name
                    dest_build.write_bytes(lib_file.read_bytes())
                    dest_build.chmod(lib_file.stat().st_mode)
                    print(f"Copied dylib variant: {lib_file.name} to {dest_build}")

                for dylib_file in search_path.glob("libcylogger*.dylib"):
                    try:
                        subprocess.check_call(
                            [
                                "install_name_tool",
                                "-id",
                                f"@loader_path/{dylib_file.name}",
                                str(cmake_source_dir / dylib_file.name),
                            ]
                        )
                        print(f"Fixed install name for {dylib_file.name}")

                        rel_path = cmake_source_dir.relative_to(Path.cwd())
                        build_dylib = Path(self.build_lib) / rel_path / dylib_file.name
                        if build_dylib.exists():
                            subprocess.check_call(
                                [
                                    "install_name_tool",
                                    "-id",
                                    f"@loader_path/{dylib_file.name}",
                                    str(build_dylib),
                                ]
                            )
                    except subprocess.CalledProcessError as e:
                        print(
                            f"Warning: Could not fix install name for {dylib_file.name}: {e}"
                        )

    def vendor_headers(self, cmake_source_dir: Path):
        cmake_build_dir = cmake_source_dir / "build"
        deps_dir = cmake_build_dir / "_deps"

        if not deps_dir.exists():
            return

        package_include_dst = cmake_source_dir / "include"
        package_include_dst.mkdir(parents=True, exist_ok=True)

        for dep_dir in deps_dir.iterdir():
            src_inc = dep_dir / "include"
            if not src_inc.exists():
                continue

            for src_file in src_inc.rglob("*"):
                if src_file.is_file():
                    rel_path = src_file.relative_to(src_inc)

                    dst_file = package_include_dst / rel_path
                    dst_file.parent.mkdir(parents=True, exist_ok=True)
                    dst_file.write_bytes(src_file.read_bytes())

                    rel_cmake_path = cmake_source_dir.relative_to(Path.cwd())
                    build_include = (
                        Path(self.build_lib) / rel_cmake_path / "include" / rel_path
                    )
                    build_include.parent.mkdir(parents=True, exist_ok=True)
                    build_include.write_bytes(src_file.read_bytes())

            print(f"Vendored headers from {dep_dir.name} to {package_include_dst}")


def get_compile_flags():
    """Get platform-specific compile flags"""
    if platform.system() == "Windows":
        return [
            "/utf-8",
            "/std:c++latest",
            "/O2",
            "/GL",
            "/arch:AVX2",
            "/DNDEBUG",
            "/W3",
        ]
    else:
        flags = [
            "-std=c++20",
            "-O3",
            "-DNDEBUG",
            "-Wall",
        ]

        if platform.system() == "Darwin":
            flags.append("-mmacosx-version-min=13.0")
        return flags


def get_link_flags():
    """Get platform-specific link flags"""
    if platform.system() == "Windows":
        return ["/LTCG"]
    else:
        flags = ["-Wl,-O1"]
        if platform.system() == "Darwin":
            flags.append("-mmacosx-version-min=13.0")
        return flags


cylogger_lib_dir = "cykit/cylogger"

compile_flags = get_compile_flags()
link_flags = get_link_flags()


extensions = [
    Extension(
        "cykit.cylogger.cylogger",
        sources=["cykit/cylogger/cylogger.pyx"],
        language="c++",
        extra_compile_args=compile_flags,
        extra_link_args=link_flags,
        libraries=["cylogger"],
        library_dirs=[cylogger_lib_dir],
        runtime_library_dirs=["$ORIGIN"] if platform.system() != "Windows" else None,
        include_dirs=[cylogger_lib_dir, f"{cylogger_lib_dir}/include"],
    ),
    Extension(
        "cykit.common",
        sources=["cykit/common.pyx"],
        extra_compile_args=compile_flags,
        extra_link_args=link_flags,
        language="c++",
    ),
    Extension(
        "cykit.spsc_queue.spsc_queue",
        sources=["cykit/spsc_queue/spsc_queue.pyx"],
        extra_compile_args=compile_flags,
        extra_link_args=link_flags,
        language="c++",
    ),
    Extension(
        "cykit.utils.msgbridge.msgbridge",
        sources=["cykit/utils/msgbridge/msgbridge.pyx"],
        extra_compile_args=compile_flags,
        extra_link_args=link_flags,
        language="c++",
    ),
]

cython_directives = {
    "language_level": "3",
    "embedsignature": True,
}

if "CYKIT_OPTIMIZE" in __import__("os").environ:
    print("===> Enabling Optimizations")

    if sys.platform.startswith("linux"):
        compile_flags.extend(
            [
                "-march=native",
                "-mtune=native",
                "-flto",
                "-funroll-loops",
            ]
        )
        link_flags.append("-flto")

    cython_directives.update(
        {
            "boundscheck": False,
            "wraparound": False,
            "cdivision": True,
            "initializedcheck": False,
            "nonecheck": False,
        }
    )

setup(
    name="cykit",
    version="0.0.4",
    packages=find_packages(),
    ext_modules=cythonize(
        extensions,
        compiler_directives=cython_directives,
        nthreads=multiprocessing.cpu_count(),
    ),
    cmdclass={"build_ext": BuildExt},
    include_package_data=True,
    package_data={
        "cykit": [
            "*.pxd",
            "*.pyi",
        ],
        "cykit.cylogger": [
            "*.pxd",
            "*.pyi",
            "*.hpp",
            "*.so",
            "*.so.*",
            "*.dll",
            "*.dylib",
            "*.*.dylib",
            "*.*.*.dylib",
            "*.lib",
            "cylogger.lib",
            "libcylogger.so*",
            "libcylogger.dylib*",
            "libcylogger.0.dylib",
            "cylogger.dll",
            "include/**/*.h",
            "include/**/*.hpp",
        ],
    },
    zip_safe=False,
)
