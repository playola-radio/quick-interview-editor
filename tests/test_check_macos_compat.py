import importlib.util
import struct
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "packaging" / "check_macos_compat.py"
_spec = importlib.util.spec_from_file_location("check_macos_compat", _SCRIPT)
compat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(compat)

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
PLATFORM_MACOS = 1


def encode(version):
    major, minor, patch = (list(version) + [0, 0])[:3]
    return (major << 16) | (minor << 8) | patch


def build_version(minos, platform=PLATFORM_MACOS):
    return struct.pack("<6I", LC_BUILD_VERSION, 24, platform, encode(minos), encode((26, 4)), 0)


def version_min(version):
    return struct.pack("<4I", LC_VERSION_MIN_MACOSX, 16, encode(version), encode((15, 0)))


def thin(*commands):
    body = b"".join(commands)
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 6, len(commands), len(body), 0, 0)
    return header + body


def fat(*slices, wide=False):
    offset = 4096
    arches, payload = b"", b""
    for s in slices:
        if wide:
            arches += struct.pack(">2I2Q2I", 0x0100000C, 0, offset + len(payload), len(s), 12, 0)
        else:
            arches += struct.pack(">5I", 0x0100000C, 0, offset + len(payload), len(s), 12)
        payload += s
    head = struct.pack(">2I", 0xCAFEBABF if wide else 0xCAFEBABE, len(slices)) + arches
    return head.ljust(offset, b"\0") + payload


def write(tmp_path, name, data):
    path = tmp_path / name
    path.write_bytes(data)
    return path


def test_minimum_versions_reads_build_version(tmp_path):
    path = write(tmp_path, "a.so", thin(build_version((15, 0))))
    assert compat.minimum_versions(path) == [(15, 0, 0)]


def test_minimum_versions_reads_legacy_version_min(tmp_path):
    path = write(tmp_path, "a.so", thin(version_min((10, 13))))
    assert compat.minimum_versions(path) == [(10, 13, 0)]


def test_minimum_versions_reads_every_fat_slice(tmp_path):
    path = write(tmp_path, "a.so", fat(thin(build_version((11, 0))), thin(build_version((26, 0)))))
    assert compat.minimum_versions(path) == [(11, 0, 0), (26, 0, 0)]


def test_minimum_versions_ignores_non_mach_o(tmp_path):
    assert compat.minimum_versions(write(tmp_path, "a.txt", b"hello world")) is None


def test_minimum_versions_ignores_static_archives(tmp_path):
    assert compat.minimum_versions(write(tmp_path, "a.a", b"!<arch>\n" + b"\0" * 64)) is None


def test_minimum_versions_reads_64_bit_fat_header(tmp_path):
    path = write(tmp_path, "a.so", fat(thin(build_version((11, 0))), wide=True))
    assert compat.minimum_versions(path) == [(11, 0, 0)]


def test_minimum_versions_ignores_other_platforms(tmp_path):
    path = write(tmp_path, "a.so", thin(build_version((26, 0), platform=2)))
    assert compat.minimum_versions(path) == [None]


def test_find_problems_flags_binary_newer_than_target(tmp_path):
    write(tmp_path, "new.so", thin(build_version((26, 0))))
    write(tmp_path, "old.so", thin(build_version((11, 0))))
    problems, checked = compat.find_problems(tmp_path, (15, 0, 0))
    assert (problems, checked) == (["needs macOS 26.0.0: new.so"], 2)


def test_find_problems_flags_newer_fat_slice(tmp_path):
    write(tmp_path, "fat.so", fat(thin(build_version((11, 0))), thin(build_version((26, 0)))))
    problems, _ = compat.find_problems(tmp_path, (15, 0, 0))
    assert problems == ["needs macOS 26.0.0: fat.so"]


def test_find_problems_compares_patch_versions_numerically(tmp_path):
    write(tmp_path, "a.so", thin(build_version((15, 0, 10))))
    problems, _ = compat.find_problems(tmp_path, (15, 0, 9))
    assert problems == ["needs macOS 15.0.10: a.so"]


def test_find_problems_flags_mach_o_without_minimum(tmp_path):
    write(tmp_path, "a.so", thin())
    problems, _ = compat.find_problems(tmp_path, (15, 0, 0))
    assert problems == ["no minimum macOS recorded: a.so"]


def test_find_problems_flags_fat_slice_without_minimum(tmp_path):
    write(tmp_path, "fat.so", fat(thin(build_version((11, 0))), thin()))
    problems, _ = compat.find_problems(tmp_path, (15, 0, 0))
    assert problems == ["no minimum macOS recorded: fat.so"]


def test_find_problems_fails_on_truncated_load_command(tmp_path):
    write(tmp_path, "a.so", thin(build_version((11, 0)))[:-8])
    with pytest.raises(ValueError):
        compat.find_problems(tmp_path, (15, 0, 0))


def test_find_problems_fails_on_undersized_build_version(tmp_path):
    short = struct.pack("<4I", LC_BUILD_VERSION, 16, PLATFORM_MACOS, encode((26, 0)))
    write(tmp_path, "a.so", thin(short))
    with pytest.raises(ValueError):
        compat.find_problems(tmp_path, (15, 0, 0))


def test_find_problems_fails_on_unreadable_directory(tmp_path):
    locked = tmp_path / "locked"
    locked.mkdir()
    write(locked, "a.so", thin(build_version((26, 0))))
    write(tmp_path, "b.so", thin(build_version((11, 0))))
    locked.chmod(0)
    try:
        with pytest.raises(PermissionError):
            compat.find_problems(tmp_path, (15, 0, 0))
    finally:
        locked.chmod(0o755)


def test_find_problems_accepts_binary_at_target(tmp_path):
    write(tmp_path, "a.so", thin(build_version((15, 0))))
    assert compat.find_problems(tmp_path, (15, 0, 0)) == ([], 1)


def test_find_problems_skips_symlinks(tmp_path):
    write(tmp_path, "a.so", thin(build_version((11, 0))))
    (tmp_path / "link.so").symlink_to(tmp_path / "a.so")
    assert compat.find_problems(tmp_path, (15, 0, 0)) == ([], 1)


def test_find_problems_fails_on_truncated_mach_o(tmp_path):
    write(tmp_path, "a.so", thin(build_version((11, 0)))[:40])
    with pytest.raises(ValueError):
        compat.find_problems(tmp_path, (15, 0, 0))


def test_deployment_target_reads_project_yml(tmp_path):
    yml = write(tmp_path, "project.yml", b'options:\n  deploymentTarget:\n    macOS: "15.0"\n')
    assert compat.deployment_target(yml) == (15, 0, 0)


def test_deployment_target_rejects_missing_value(tmp_path):
    yml = write(tmp_path, "project.yml", b"options: {}\n")
    with pytest.raises(ValueError):
        compat.deployment_target(yml)


def test_main_fails_on_empty_bundle(tmp_path):
    yml = write(tmp_path, "project.yml", b'    macOS: "15.0"\n')
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    assert compat.main([str(bundle)], project_yml=yml) == 1


def test_main_passes_compatible_bundle(tmp_path):
    yml = write(tmp_path, "project.yml", b'    macOS: "15.0"\n')
    bundle = tmp_path / "bundle"
    bundle.mkdir()
    write(bundle, "a.so", thin(build_version((11, 0))))
    assert compat.main([str(bundle)], project_yml=yml) == 0
