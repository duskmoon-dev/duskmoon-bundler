"""Reject native archives that require a newer glibc than the consumer baseline."""

import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def check(archive, maximum):
    with tarfile.open(archive, "r:gz") as bundle:
        libraries = [entry for entry in bundle if entry.isfile() and entry.name.endswith(".so")]
        if len(libraries) != 1:
            raise ValueError("expected exactly one shared library in the native archive")
        with tempfile.TemporaryDirectory(prefix="native-glibc-") as temp:
            library = Path(temp) / "native.so"
            library.write_bytes(bundle.extractfile(libraries[0]).read())
            symbols = subprocess.check_output(
                ["readelf", "--version-info", str(library)], text=True
            )

    requirements = set(re.findall(r"Name: GLIBC_(\S+)", symbols))
    if not requirements:
        raise ValueError("GNU native library has no glibc version requirements")
    for requirement in sorted(requirements):
        if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", requirement):
            raise ValueError(f"unsupported glibc requirement: GLIBC_{requirement}")
        if version(requirement) > version(maximum):
            raise ValueError(f"requires GLIBC_{requirement}, exceeding glibc {maximum}")
    print(f"{Path(archive).name}: all glibc requirements are <= {maximum}")


if __name__ == "__main__":
    try:
        check(*sys.argv[1:])
    except (ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
