"""afconvert failures carry afconvert's own reason, not just an exit status."""

import subprocess

import pytest

from logic_markers import audio, whisperx_backend


def _failing_afconvert(monkeypatch, module):
    def run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="Error: unsupported file type\n")

    monkeypatch.setattr(module.subprocess, "run", run)


def test_transcription_decode_failure_includes_afconvert_stderr(monkeypatch, tmp_path):
    pytest.importorskip("numpy")
    _failing_afconvert(monkeypatch, whisperx_backend)
    with pytest.raises(RuntimeError, match=r"afconvert failed \(1\): Error: unsupported file type$"):
        whisperx_backend._load_audio_16k_mono(tmp_path / "in.m4a")


def test_aiff_conversion_failure_includes_afconvert_stderr(monkeypatch, tmp_path):
    _failing_afconvert(monkeypatch, audio)
    with pytest.raises(RuntimeError, match=r"afconvert failed \(1\): Error: unsupported file type$"):
        audio.convert_to_aiff(tmp_path / "in.m4a", tmp_path / "out.aiff")
