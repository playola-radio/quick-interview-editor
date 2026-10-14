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
_FAT_MAGICS = {0xCAFEBABE: (">5I", 20), 0xCAFEBABF: (">2I2Q2I", 32)}  # 32/64-bit fat_arch
_LC_BUILD_VERSION = 0x32
_LC_VERSION_MIN_MACOSX = 0x24
_PLATFORM_MACOS = 1


def _decode(value):
    return (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def _format(version):
    return ".".join(str(part) for part in version)


def _unpack(file, fmt, offset):
    if offset < 0:
        raise ValueError("truncated Mach-O")
    file.seek(offset)
    data = file.read(struct.calcsize(fmt))
    if len(data) != struct.calcsize(fmt):
        raise ValueError("truncated Mach-O")
    return struct.unpack(fmt, data)


def _thin_minimum(file, start):
    (magic,) = _unpack(file, "<I", start)
    ncmds = _unpack(file, "<I", start + 16)[0]
    offset = start + _THIN_MAGICS[magic]
    found = []
    for _ in range(ncmds):
        cmd, size = _unpack(file, "<2I", offset)
        needed = {_LC_BUILD_VERSION: 24, _LC_VERSION_MIN_MACOSX: 16}.get(cmd, 8)
        if size < needed:
            raise ValueError("malformed load command")
        _unpack(file, f"{size}s", offset)  # the whole command must be present
        if cmd == _LC_BUILD_VERSION:
            platform, minos = _unpack(file, "<2I", offset + 8)
            if platform == _PLATFORM_MACOS:
                found.append(_decode(minos))
        elif cmd == _LC_VERSION_MIN_MACOSX:
            found.append(_decode(_unpack(file, "<I", offset + 8)[0]))
        offset += size
    return max(found, default=None)


def minimum_versions(path):
    """Minimum macOS of each slice (None where unrecorded), or None if not a Mach-O."""
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return None
        if struct.unpack("<I", head[:4])[0] in _THIN_MAGICS:
            return [_thin_minimum(f, 0)]
        magic, nfat = struct.unpack(">2I", head)
        # Java class files share 0xCAFEBABE; a real fat header has a handful of arches.
        if magic not in _FAT_MAGICS or not 0 < nfat < 32:
            return None
        fmt, size = _FAT_MAGICS[magic]
        found = []
        for i in range(nfat):
            offset = _unpack(f, fmt, 8 + i * size)[2]
            found.append(_thin_minimum(f, offset))
        return found


def find_problems(bundle, target):
    problems, checked = [], 0
    def fail(error):
        raise error

    for root, _, files in os.walk(bundle, onerror=fail):
        for name in sorted(files):
            path = Path(root) / name
            if path.is_symlink():
                continue
            minimums = minimum_versions(path)
            if minimums is None:
                continue
            checked += 1
            rel = path.relative_to(bundle)
            if None in minimums:
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
