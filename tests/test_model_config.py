"""Tests for the offline model contract (QIE_* env -> ModelConfig).

These stay torch-free: they exercise the pure env->config mapping and the
offline-env side effects, never loading a model.
"""

import os

import pytest

from logic_markers.model_config import ModelConfig, load_from_env


def test_dev_defaults_when_no_env():
    """No QIE_* env -> download defaults (today's dev behavior), online."""
    config = load_from_env(env={})
    assert config.whisper_model_dir is None
    assert config.align_model_dir is None
    assert config.nltk_data_dir is None
    assert config.offline is False
    # Falls back to the named model the engine has always downloaded.
    assert config.whisper_arch == "large-v2"


def test_packaged_env_sets_local_dirs_and_offline():
    env = {
        "QIE_WHISPER_MODEL_DIR": "/Models/faster-whisper-large-v2",
        "QIE_ALIGN_MODEL_DIR": "/Models/align",
        "QIE_NLTK_DATA": "/Models/nltk_data",
        "QIE_OFFLINE": "1",
    }
    config = load_from_env(env=env)
    assert config.whisper_model_dir == "/Models/faster-whisper-large-v2"
    assert config.align_model_dir == "/Models/align"
    assert config.nltk_data_dir == "/Models/nltk_data"
    assert config.offline is True
    # When a model dir is given, that absolute path IS the arch handed to
    # faster-whisper (it loads a directory directly, no download).
    assert config.whisper_arch == "/Models/faster-whisper-large-v2"


def test_blank_env_values_are_treated_as_unset():
    """Empty/whitespace env vars must not become bogus paths."""
    env = {"QIE_WHISPER_MODEL_DIR": "  ", "QIE_ALIGN_MODEL_DIR": ""}
    config = load_from_env(env=env)
    assert config.whisper_model_dir is None
    assert config.align_model_dir is None


@pytest.mark.parametrize("raw,expected", [("1", True), ("true", True), ("True", True),
                                          ("0", False), ("", False), ("no", False)])
def test_offline_flag_parsing(raw, expected):
    assert load_from_env(env={"QIE_OFFLINE": raw}).offline is expected


def test_apply_offline_env_sets_hf_and_transformers_flags():
    config = ModelConfig(whisper_model_dir=None, align_model_dir=None,
                         offline=True, nltk_data_dir=None)
    env: dict[str, str] = {}
    config.apply_offline_env(env=env)
    assert env["HF_HUB_OFFLINE"] == "1"
    assert env["TRANSFORMERS_OFFLINE"] == "1"


def test_apply_offline_env_noop_when_online():
    config = ModelConfig(whisper_model_dir=None, align_model_dir=None,
                         offline=False, nltk_data_dir=None)
    env: dict[str, str] = {}
    config.apply_offline_env(env=env)
    assert "HF_HUB_OFFLINE" not in env
    assert "TRANSFORMERS_OFFLINE" not in env


def test_apply_offline_env_prepends_nltk_data():
    config = ModelConfig(whisper_model_dir=None, align_model_dir=None,
                         offline=True, nltk_data_dir="/Models/nltk_data")
    env = {"NLTK_DATA": "/existing"}
    config.apply_offline_env(env=env)
    # Bundled data wins (prepended), existing path preserved after it.
    assert env["NLTK_DATA"] == "/Models/nltk_data" + os.pathsep + "/existing"


def test_validate_raises_on_missing_configured_dir(tmp_path):
    missing = str(tmp_path / "nope")
    config = ModelConfig(whisper_model_dir=missing, align_model_dir=None,
                         offline=True, nltk_data_dir=None)
    with pytest.raises(FileNotFoundError, match="QIE_WHISPER_MODEL_DIR"):
        config.validate()


def test_validate_passes_when_dirs_exist(tmp_path):
    wdir = tmp_path / "whisper"
    wdir.mkdir()
    config = ModelConfig(whisper_model_dir=str(wdir), align_model_dir=None,
                         offline=True, nltk_data_dir=None)
    config.validate()  # does not raise
