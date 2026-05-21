import os
import platform
from pathlib import Path
from dataclasses import dataclass


@dataclass
class BuildConfig:
    use_sys_boost: bool
    debug: bool
    ext_debug: bool
    optimize: bool

    @staticmethod
    def get_env_flag(name: str) -> bool:
        return os.getenv(name) == "1"

    @classmethod
    def from_env(cls):
        return cls(
            use_sys_boost=cls.get_env_flag("USE_SYS_BOOST"),
            debug=cls.get_env_flag("DEBUG"),
            ext_debug=cls.get_env_flag("EXT_DEBUG"),
            optimize=cls.get_env_flag("OPTIMIZE"),
        )

    def __repr__(self) -> str:
        return (
            f"BuildConfig(use_sys_boost={self.use_sys_boost}, "
            f"debug={self.debug}, ext_debug={self.ext_debug}, "
            f"optimize={self.optimize})"
        )

    def get_package_root(self) -> Path:
        return Path(__file__).parent

    def get_boost_include_dir(self) -> str:
        if self.use_sys_boost:
            return ""

        vendored = self.get_package_root() / "utils/boost/include"

        return str(vendored) if vendored.exists() else ""

    def get_include_dirs(self) -> list:
        root = self.get_package_root()
        inc_dirs = [str(root / "cylogger"), str(root / "cylogger/include")]
        boost_inc = self.get_boost_include_dir()

        if boost_inc:
            inc_dirs.append(boost_inc)
        return inc_dirs

    def get_library_dirs(self) -> list:
        lib_dirs = self.get_package_root() / "cylogger"
        return [str(lib_dirs)] if lib_dirs.exists() else []

    def get_libraries(self) -> list:
        return ["cylogger"]

    def get_compile_flags(self) -> list:
        system = platform.system()

        if system == "Windows":
            flags = [
                "/utf-8",
                "/std:c++latest",
                "/arch:AVX2",
                "/W3",
            ]

            if self.ext_debug:
                flags.extend(["/Od", "/Zi", "/RTC1", "/fsanitize=address", "/MDd"])

            else:
                flags.extend(
                    [
                        "/O2",
                        "/GL",
                    ]
                )

                if not self.debug:
                    flags.append("/DNDEBUG")

            return flags
        else:
            flags = [
                "-std=c++20",
                "-Wall",
                "-fvisibility=hidden",
                "-ffunction-sections",
                "-fdata-sections",
            ]

            if not self.debug:
                flags.extend(
                    [
                        "-DNDEBUG",
                        "-g0",
                    ]
                )

            if self.ext_debug:
                flags.extend(
                    [
                        "-O1",
                        "-g",
                        "-fno-omit-frame-pointer",
                        "-fsanitize=address,undefined",
                        "-fno-sanitize-recover=all",
                    ]
                )
            else:
                flags.append("-O3")

                if self.optimize:
                    if system == "Linux":
                        flags.extend(
                            [
                                "-march=native",
                                "-mtune=native",
                                "-flto",
                                "-funroll-loops",
                            ]
                        )

                    else:
                        flags.extend(["-march=native", "-flto"])

            if system == "Darwin":
                flags.append("-mmacosx-version-min=13.0")

        return flags

    def get_link_flags(self) -> list:

        system = platform.system()

        if system == "Windows":
            if self.ext_debug:
                return [
                    "/DEBUG",
                    "/INCREMENTAL:NO",
                    "/fsanitize=address",
                ]
            else:
                return [
                    "/LTCG",
                    "/OPT:REF",
                    "/OPT:ICF",
                ]

        flags = ["-Wl,-O1"]

        if self.ext_debug:
            flags.extend(
                [
                    "-fsanitize=address,undefined",
                ]
            )

        if system == "Darwin":
            flags.extend(
                [
                    "-mmacosx-version-min=13.0",
                    "-Wl,-dead_strip",
                ]
            )
        else:
            flags.append("-Wl,--gc-sections")

            if not self.debug and not self.ext_debug:
                flags.append("-s")

        if self.optimize and not self.ext_debug and not self.debug:
            flags.append("-flto")

        return flags

    def get_compiler_directives(self) -> dict:
        comp_directives = {
            "language_level": "3",
            "embedsignature": True,
        }

        if self.optimize and not self.ext_debug and not self.debug:
            comp_directives.update(
                {
                    "boundscheck": False,
                    "wraparound": False,
                    "cdivision": True,
                    "initializedcheck": False,
                    "nonecheck": False,
                }
            )

        return comp_directives

    def get_define_macros(self) -> list:
        macros = []
        if platform.system() == "Windows":
            macros.extend(
                [
                    ("_WIN32_WINNT", "0x0A00"),
                    ("WIN32_LEAN_AND_MEAN", None),
                    ("NOMINMAX", None),
                ]
            )

        return macros

    def get_base_ext_kwargs(self) -> dict:
        return {
            "language": "c++",
            "include_dirs": self.get_include_dirs(),
            "define_macros": self.get_define_macros(),
            "extra_compile_args": self.get_compile_flags(),
            "extra_link_args": self.get_link_flags(),
        }

    def get_extension_kwargs(self) -> dict:
        return {
            **self.get_base_ext_kwargs(),
            "libraries": self.get_libraries(),
            "library_dirs": self.get_library_dirs(),
        }


config = BuildConfig.from_env()
