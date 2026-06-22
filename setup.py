import os
import sys
import platform
import subprocess
import multiprocessing
from pathlib import Path
from Cython.Build import cythonize
from setuptools.command.build_ext import build_ext
from setuptools import setup, Extension, find_namespace_packages

sys.path.insert(0, str(Path(__file__).parent))

from cykit._build.config import config  # noqa E402

if config.use_sys_boost:
    print("===> USE_SYS_BOOST: Skipping Boost vendoring; using system Boost headers")

if config.debug:
    print("===> DEBUG Mode is enabled")

if config.ext_debug:
    print("===> EXTENDED DEBUG (ASAN/UBSAN) Mode is enabled")

FORCE_BOOST_DOWNLOAD = config.get_env_flag("FORCE_BOOST_DOWNLOAD")

if FORCE_BOOST_DOWNLOAD:
    print("===> FORCE_BOOST_DOWNLOAD: Selected headers of boost will be downloaded")


class BuildExt(build_ext):

    def run(self):
        self.build_all_cmake_subprojects()
        self._patch_extensions_with_openssl()
        super().run()

    def _patch_extensions_with_openssl(self):
        config._openssl_cache.clear()
        for ext in self.extensions:
            if "cylogger" not in ext.name:
                continue

            for d in config._get_openssl_include_dirs():
                if d not in ext.include_dirs:
                    ext.include_dirs.append(d)

            for d in config._get_openssl_lib_dirs():
                if d not in ext.library_dirs:
                    ext.library_dirs.append(d)

            if platform.system() == "Windows":
                objs = config._get_openssl_extra_objects()
                if objs:
                    ext.extra_objects = list(getattr(ext, "extra_objects", [])) + [
                        o for o in objs if o not in getattr(ext, "extra_objects", [])
                    ]
            else:
                for name in config._get_openssl_link_names():
                    if name not in ext.libraries:
                        ext.libraries.append(name)
            print(f"[OpenSSL] Patched extension: {ext.name}")

    def build_extension(self, ext):
        system = platform.system()
        if system != "Windows" and ext.library_dirs:
            ext_pkg_dir = Path(*ext.name.split(".")[:-1])
            seen = {"."}
            # if system == "Darwin":
            #    ext.extra_link_args.append("-Wl,-rpath,@loader_path/.")
            # else:
            if system != "Darwin":
                ext.extra_link_args.append("-Wl,-rpath,$ORIGIN")
            for lib_dir in ext.library_dirs:
                lib_pkg_dir = Path(lib_dir)
                rel = os.path.relpath(lib_pkg_dir, ext_pkg_dir)
                if rel in seen:
                    continue
                seen.add(rel)
                if system == "Darwin":
                    # rpath = f"@loader_path/{rel}"
                    rpath = str(lib_pkg_dir.resolve())
                else:
                    rpath = f"$ORIGIN/{rel}"
                ext.extra_link_args.append(f"-Wl,-rpath,{rpath}")
                print(f"Injecting rpath {rpath} → {ext.name}")
        super().build_extension(ext)

    def build_all_cmake_subprojects(self):
        project_root = Path(__file__).resolve().parent
        cmake_dirs = [
            project_root / "cmake" / "spdlog",
            project_root / "cmake" / "boost",
            project_root / "cmake" / "openssl",
        ]

        for cmake_source_dir in cmake_dirs:
            if not (cmake_source_dir / "CMakeLists.txt").exists():
                continue

            if cmake_source_dir.name == "boost":
                if config.use_sys_boost:
                    print(
                        f"===> USE_SYS_BOOST: skipping CMake build for {cmake_source_dir}"
                    )
                    continue

                if not FORCE_BOOST_DOWNLOAD:
                    boost_include = (
                        project_root / "cykit" / "_vendor" / "include" / "boost"
                    )
                    if boost_include.exists() and any(boost_include.iterdir()):
                        print(
                            f"===> Boost headers already present at {boost_include}, "
                            f"skipping. Set FORCE_BOOST_DOWNLOAD=1 to re-download."
                        )
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

        project_root = Path(__file__).resolve().parent
        vendor_include_dir = str(project_root / "cykit" / "_vendor" / "include")

        cmake_args = [
            "cmake",
            str(cmake_source_dir),
            (
                "-DCMAKE_BUILD_TYPE=Debug"
                if config.ext_debug
                else "-DCMAKE_BUILD_TYPE=Release"
            ),
        ]

        if cmake_source_dir.name in ("spdlog", "boost"):
            cmake_args.append(f"-DVENDOR_INCLUDE_DIR={vendor_include_dir}")

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

            if cmake_source_dir.name != "openssl":
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

        if cmake_source_dir.name == "openssl" and platform.system() == "Windows":
            openssl_bin = config._get_openssl_bin_dir()
            github_env = os.environ.get("GITHUB_ENV")
            if openssl_bin and github_env:
                with open(github_env, "a", encoding="utf-8") as f:
                    f.write(f"CYKIT_OPENSSL_BIN_DIR={openssl_bin}\n")
                print(
                    f"[OpenSSL] Wrote CYKIT_OPENSSL_BIN_DIR={openssl_bin} to GITHUB_ENV"
                )

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

                rel_path = cmake_source_dir.relative_to(project_root)
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

                    rel_path = cmake_source_dir.relative_to(project_root)
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

                    rel_path = cmake_source_dir.relative_to(project_root)
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
                                # f"@loader_path/{dylib_file.name}",
                                str(cmake_source_dir / dylib_file.name),
                                str(cmake_source_dir / dylib_file.name),
                            ]
                        )
                        print(f"Fixed install name for {dylib_file.name}")

                        rel_path = cmake_source_dir.relative_to(project_root)
                        build_dylib = Path(self.build_lib) / rel_path / dylib_file.name
                        if build_dylib.exists():
                            subprocess.check_call(
                                [
                                    "install_name_tool",
                                    "-id",
                                    # f"@loader_path/{dylib_file.name}",
                                    str(build_dylib),
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

        project_root = Path(__file__).resolve().parent
        vendor_include_dst = project_root / "cykit" / "_vendor" / "include"
        vendor_include_dst.mkdir(parents=True, exist_ok=True)

        for dep_dir in deps_dir.iterdir():
            src_inc = dep_dir / "include"
            if not src_inc.exists():
                continue

            for src_file in src_inc.rglob("*"):
                if src_file.is_file():
                    rel_path = src_file.relative_to(src_inc)

                    dst_file = vendor_include_dst / rel_path
                    dst_file.parent.mkdir(parents=True, exist_ok=True)
                    dst_file.write_bytes(src_file.read_bytes())

                    build_include = (
                        Path(self.build_lib)
                        / "cykit"
                        / "_vendor"
                        / "include"
                        / rel_path
                    )
                    build_include.parent.mkdir(parents=True, exist_ok=True)
                    build_include.write_bytes(src_file.read_bytes())

            print(f"Vendored headers from {dep_dir.name} to {vendor_include_dst}")


base_ext_kwargs = config.get_base_ext_kwargs()
cylogger_ext_kwargs = config.get_extension_kwargs()

extensions = [
    Extension(
        "cykit.cylogger.cylogger",
        sources=["cykit/cylogger/cylogger.pyx"],
        **cylogger_ext_kwargs,
    ),
    Extension(
        "cykit.queue.queue",
        sources=["cykit/queue/queue.pyx"],
        **base_ext_kwargs,
    ),
    Extension(
        "cykit.utils.msgbridge.msgbridge",
        sources=["cykit/utils/msgbridge/msgbridge.pyx"],
        **base_ext_kwargs,
    ),
]


setup(
    name="cykit",
    version="0.0.9",
    packages=find_namespace_packages(
        exclude=[
            "examples",
            "examples.*",
            "build",
            "dist",
            "cmake",
            "cmake.*",
            "tests",
            "tests.*",
        ]
    ),
    ext_modules=cythonize(
        extensions,
        compiler_directives=config.get_compiler_directives(),
        nthreads=multiprocessing.cpu_count(),
    ),
    cmdclass={"build_ext": BuildExt},
    include_package_data=True,
    zip_safe=False,
)
