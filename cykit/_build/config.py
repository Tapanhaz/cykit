import os
import platform
from pathlib import Path
from dataclasses import dataclass, field
import subprocess


@dataclass
class BuildConfig:
    use_sys_boost: bool
    debug: bool
    ext_debug: bool
    optimize: bool

    _openssl_cache: dict = field(
                            default_factory=dict, 
                            repr=False, 
                            compare=False
                        )

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
    
    def _get_openssl_paths_file(self) -> "Path":
        return (
            self.get_package_root()
            / "cmake" / "openssl" / "build" / "openssl_paths.txt"
        )

    def _parse_openssl_paths(self) -> dict:
        if self._openssl_cache:
            return self._openssl_cache
        p = self._get_openssl_paths_file()
        if not p.exists():
            return {}
        data = {}
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                data[k.strip()] = v.strip()
        self._openssl_cache = data
        return data

    def _get_openssl_include_dirs(self) -> list:
        raw = self._parse_openssl_paths().get("OPENSSL_INCLUDE_DIR", "")
        return [d for d in raw.split(";") if d and Path(d).exists()]

    def _get_openssl_lib_dirs(self) -> list:
        dirs = []
        for key in ("OPENSSL_SSL_LIBRARY", "OPENSSL_CRYPTO_LIBRARY"):
            p = self._parse_openssl_paths().get(key, "")
            if p:
                d = str(Path(p).parent)
                if d not in dirs:
                    dirs.append(d)
        return dirs

    def _get_openssl_link_names(self) -> list:
        names = []
        for key in ("OPENSSL_SSL_LIBRARY", "OPENSSL_CRYPTO_LIBRARY"):
            p = self._parse_openssl_paths().get(key, "")
            if not p:
                continue
            stem = Path(p).stem 
            name = stem[3:] if stem.startswith("lib") else stem
            if name not in names:
                names.append(name)
                
        if not names:
            names = self._pkgconfig_openssl_names()
        return names or ["ssl", "crypto"]

    def _pkgconfig_openssl_names(self) -> list:
        try:
            out = subprocess.check_output(
                ["pkg-config", "--libs", "openssl"],
                stderr=subprocess.DEVNULL, text=True
            )
            return [t[2:] for t in out.split() if t.startswith("-l")]
        except Exception:
            return []

    def _get_openssl_extra_objects(self) -> list:
        if platform.system() != "Windows":
            return []
        objs = []
        for key in ("OPENSSL_SSL_LIBRARY", "OPENSSL_CRYPTO_LIBRARY"):
            p = self._parse_openssl_paths().get(key, "")
            if p and Path(p).exists():
                objs.append(p)
        if objs:
            return objs
        
        for root in [
            Path(os.environ.get("OPENSSL_ROOT_DIR", "")),
            Path("C:/Program Files/OpenSSL-Win64"),
            Path("C:/Program Files/OpenSSL"),
            Path("C:/OpenSSL-Win64"),
            Path("C:/OpenSSL"),
        ]:
            if not str(root):
                continue
            for sub in ("lib/VC/x64/MD", "lib"):
                for names in (("libssl.lib","libcrypto.lib"), ("ssl.lib","crypto.lib")):
                    ssl_p = root / sub / names[0]
                    cry_p = root / sub / names[1]
                    if ssl_p.exists() and cry_p.exists():
                        return [str(ssl_p), str(cry_p)]
        return []

    def get_package_root(self) -> Path:
        return Path(__file__).resolve().parent.parent.parent

    def get_vendor_include_dir(self) -> str:
        vendored = self.get_package_root() / "cykit" / "_vendor" / "include"
        return str(vendored) if vendored.exists() else ""

    def get_include_dirs(self) -> list:
        root = self.get_package_root()
        inc_dirs = [
            str(root / "cykit" / "cylogger"), 
            str(root / "cykit" / "utils" / "transport")
        ]
        vendor_inc = self.get_vendor_include_dir()
        if vendor_inc:
            inc_dirs.append(vendor_inc)
        return inc_dirs

    def get_library_dirs(self) -> list:
        #lib_dirs = self.get_package_root() / "cylogger"
        dirs = [] # [str(lib_dirs)] if lib_dirs.exists() else []
        for d in self._get_openssl_lib_dirs():
            if d not in dirs:
                dirs.append(d)
        return dirs

    def get_libraries(self) -> list:
        if platform.system() == "Windows":
            #return ["cylogger"]
            return []
        #return ["cylogger"] + self._get_openssl_link_names()
        return self._get_openssl_link_names()

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

    def get_extension_kwargs(self, ssl: bool = False) -> dict:
        base = self.get_base_ext_kwargs()
        kwargs = {
            **base,
            "libraries":    self.get_libraries(),
            "library_dirs": self.get_library_dirs(),
        }
        if ssl:
            for d in self._get_openssl_include_dirs():
                if d not in kwargs["include_dirs"]:
                    kwargs["include_dirs"].append(d)
            extra_objs = self._get_openssl_extra_objects()
            if extra_objs:
                kwargs["extra_objects"] = extra_objs
        return kwargs


config = BuildConfig.from_env()
