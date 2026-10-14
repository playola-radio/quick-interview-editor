"""Fail if any Mach-O in a frozen bundle needs a newer macOS than the app supports.

    python3 packaging/check_macos_compat.py packaging/dist/logic-markers-engine

The target is the app's deploymentTarget in QuickInterviewEditor/project.yml.
Reads each binary's own load commands (every slice of a universal binary) and
fails closed on anything it can't parse. Static archives are skipped: nothing
loads them at runtime.
"""

import os
import re
import struct
import sys
from pathlib import Path

_PROJECT_YML = Path(__file__).resolve().parent.parent / "QuickInterviewEditor" / "project.yml"

_THIN_MAGICS = {0xFEEDFACE: 28, 0xFEEDFACF: 32}  # header size, little-endian
_FAT_MAGICS = {0xCAFEBABE: (">5I", 20), 0xCAFEBABF: (">2Q2I", 32)}  # 32/64-bit fat_arch
_LC_BUILD_VERSION = 0x32
_LC_VERSION_MIN_MACOSX = 0x24
_PLATFORM_MACOS = 1


def _decode(value):
    return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def _format(version):
    return ".".join(str(part) for part in version)


def _unpack(fmt, data, offset):
    if offset < 0 or offset + struct.calcsize(fmt) > len(data):
        raise ValueError("truncated Mach-O")
    return struct.unpack_from(fmt, data, offset)


def _thin_minimums(data, start):
    (magic,) = _unpack("<I", data, start)
    ncmds = _unpack("<I", data, start + 16)[0]
    offset = start + _THIN_MAGICS[magic]
    found = []
    for _ in range(ncmds):
        cmd, size = _unpack("<2I", data, offset)
        if size < 8:
            raise ValueError("malformed load command")
        if cmd == _LC_BUILD_VERSION:
            platform, minos = _unpack("<2I", data, offset + 8)
            if platform == _PLATFORM_MACOS:
                found.append(_decode(minos))
        elif cmd == _LC_VERSION_MIN_MACOSX:
            found.append(_decode(_unpack("<I", data, offset + 8)[0]))
        offset += size
    return found


def minimum_versions(path):
    """Minimum macOS of every slice, [] if none recorded, None if not a Mach-O."""
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return None
        if struct.unpack("<I", head[:4])[0] in _THIN_MAGICS:
            return _thin_minimums(head + f.read(), 0)
        magic, nfat = struct.unpack(">2I", head)
        # Java class files share 0xCAFEBABE; a real fat header has a handful of arches.
        if magic not in _FAT_MAGICS or not 0 < nfat < 32:
            return None
        data = head + f.read()
    fmt, size = _FAT_MAGICS[magic]
    found = []
    for i in range(nfat):
        offset = _unpack(fmt, data, 8 + i * size)[2]
        found += _thin_minimums(data, offset)
    return found


def find_problems(bundle, target):
    problems, checked = [], 0
    for root, _, files in os.walk(bundle):
        for name in sorted(files):
            path = Path(root) / name
            if path.is_symlink():
                continue
            minimums = minimum_versions(path)
            if minimums is None:
                continue
            checked += 1
            rel = path.relative_to(bundle)
            if not minimums:
                problems.append(f"no minimum macOS recorded: {rel}")
            elif max(minimums) > target:
                problems.append(f"needs macOS {_format(max(minimums))}: {rel}")
    return problems, checked


def deployment_target(project_yml):
    match = re.search(r'^\s*macOS:\s*"(\d+(?:\.\d+){0,2})"', Path(project_yml).read_text(), re.M)
    if not match:
        raise ValueError(f"no macOS deploymentTarget in {project_yml}")
    return tuple((list(map(int, match.group(1).split("."))) + [0, 0])[:3])


def main(argv, project_yml=_PROJECT_YML):
    if len(argv) != 1:
        print("usage: check_macos_compat.py <bundle-dir>", file=sys.stderr)
        return 2
    bundle = Path(argv[0])
    target = deployment_target(project_yml)
    print(f"==> Checking every Mach-O in {bundle} runs on macOS {_format(target)}")
    problems, checked = find_problems(bundle, target)
    for problem in problems:
        print(f"    {problem}", file=sys.stderr)
    if checked == 0:
        print(f"error: found no Mach-O binaries under {bundle}", file=sys.stderr)
        return 1
    if problems:
        print(
            f"error: {len(problems)} of {checked} binaries may not run on macOS {_format(target)}.\n"
            "       Freeze from the python-build-standalone venv (packaging/make-build-venv.sh).",
            file=sys.stderr,
        )
        return 1
    print(f"    OK ({checked} binaries)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
