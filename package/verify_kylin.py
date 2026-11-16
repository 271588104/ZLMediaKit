import os
import re
import subprocess
import sys


GLIBC_LIBRARIES = {
    "libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2",
    "librt.so.1", "libresolv.so.2", "ld-linux-x86-64.so.2",
}


def validate_reports(header, dynamic, versions, dependencies):
    errors = []
    if not re.search(r"Class:\s+ELF64\b", header) or not re.search(r"Machine:\s+Advanced Micro Devices X86-64\s*$", header, re.MULTILINE):
        errors.append("Expected an x86_64 ELF64 binary")

    needed = set(re.findall(r"\(NEEDED\).*\[([^\]]+)\]", dynamic))
    resolved = set(re.findall(r"^\s*(\S+)\s+=>", dependencies, re.MULTILINE))
    for library in sorted((needed | resolved) - GLIBC_LIBRARIES):
        errors.append("External runtime dependency: " + library)
    if "libc.so.6" not in needed or "libc.so.6" not in resolved:
        errors.append("Missing dynamic glibc dependency information")
    if re.search(r"\((?:RPATH|RUNPATH)\).*\[[^\]]+\]", dynamic):
        errors.append("Unexpected runtime library search path")

    required_versions = set(re.findall(r"Name:\s+(GLIBC_[\w.]+)", versions))
    if not required_versions:
        errors.append("Missing GLIBC version requirements")
    for version in sorted(required_versions):
        numeric = re.fullmatch(r"GLIBC_(\d+(?:\.\d+)+)", version)
        if numeric is None or tuple(map(int, numeric.group(1).split("."))) > (2, 28):
            errors.append("Unsupported version: " + version)

    if "not found" in dependencies or "undefined symbol:" in dependencies:
        errors.append("Unresolved runtime dependency or symbol:\n" + dependencies)
    return errors


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: verify_kylin.py MediaServer [libmk_api.so ...]")
    environment = dict(os.environ, LC_ALL="C")
    for binary in sys.argv[1:]:
        reports = []
        for command in (["readelf", "-h", binary], ["readelf", "-d", binary],
                        ["readelf", "--version-info", binary], ["ldd", "-r", binary]):
            reports.append(subprocess.check_output(command, stderr=subprocess.STDOUT,
                                                   universal_newlines=True, env=environment))
        print("=== {} ===\n{}".format(binary, reports[-1]))
        errors = validate_reports(*reports)
        if errors:
            sys.exit("{}:\n{}".format(binary, "\n".join(errors)))
        print("PASS: x86_64, GLIBC <= 2.28, glibc-only dynamic dependencies")


if __name__ == "__main__":
    main()
