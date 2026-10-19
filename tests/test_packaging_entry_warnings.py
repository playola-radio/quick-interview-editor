"""The frozen entry points say on stderr when their bundled setup data is missing."""

import importlib.util
import sys
from pathlib import Path

import pytest

PACKAGING = Path(__file__).resolve().parent.parent / "packaging"


def _load(name):
    spec = importlib.util.spec_from_file_location(name, PACKAGING / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def frozen(monkeypatch):
    monkeypatch.setattr(sys, "frozen", True, raising=False)


def test_missing_certifi_is_reported(frozen, monkeypatch, capsys):
    monkeypatch.setitem(sys.modules, "certifi", None)
    _load("cut_suggester_entry")._wire_bundled_ca_bundle()
    assert "warning: certifi is not bundled" in capsys.readouterr().err


def test_missing_ca_file_is_reported(frozen, monkeypatch, tmp_path, capsys):
    fake = type(sys)("certifi")
    fake.where = lambda: str(tmp_path / "missing.pem")
    monkeypatch.setitem(sys.modules, "certifi", fake)
    _load("cut_suggester_entry")._wire_bundled_ca_bundle()
    assert f"warning: bundled CA file is missing: {tmp_path / 'missing.pem'}" in capsys.readouterr().err


def test_missing_nltk_data_is_reported(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    _load("engine_entry")._wire_bundled_nltk_data()
    assert f"warning: bundled NLTK data is missing: {tmp_path / 'nltk_data'}" in capsys.readouterr().err
