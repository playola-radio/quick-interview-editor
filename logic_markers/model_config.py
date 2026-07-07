"""Offline model contract: resolve model locations + offline flags from env.

The engine loads two model artifacts at runtime:

- the faster-whisper CTranslate2 ASR model (``Systran/faster-whisper-large-v2``),
- the torchaudio wav2vec2 alignment model (``WAV2VEC2_ASR_BASE_960H``).

In **dev** (no ``QIE_*`` env set) both download to the default HuggingFace/torch
caches on first use — exactly the behavior this project has always had. In the
**packaged app** the models are pre-downloaded into Application Support as data
and the app sets ``QIE_WHISPER_MODEL_DIR`` / ``QIE_ALIGN_MODEL_DIR`` /
``QIE_NLTK_DATA`` / ``QIE_OFFLINE=1`` so the engine loads from those absolute
paths and never touches the network.

Keeping this a pure ``env -> config`` mapping lets it be unit-tested without
torch (see ``tests/test_model_config.py``).
"""

from __future__ import annotations

import os
from dataclasses import dataclass

_TRUTHY = {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class ModelConfig:
    """Where the models live and whether to run offline."""

    whisper_model_dir: str | None
    align_model_dir: str | None
    offline: bool
    nltk_data_dir: str | None

    @property
    def whisper_arch(self) -> str:
        """The model handle passed to ``whisperx.load_model``.

        faster-whisper treats a directory path as a local model (no download),
        so the absolute model dir *is* the arch when packaged; otherwise the
        named model the engine downloads in dev.
        """
        return self.whisper_model_dir or "large-v2"

    def validate(self) -> None:
        """Fail fast (with the offending env var name) if a configured model
        directory is missing, instead of surfacing an opaque torch error deep in
        model loading."""
        for name, path in (
            ("QIE_WHISPER_MODEL_DIR", self.whisper_model_dir),
            ("QIE_ALIGN_MODEL_DIR", self.align_model_dir),
            ("QIE_NLTK_DATA", self.nltk_data_dir),
        ):
            if path is not None and not os.path.isdir(path):
                raise FileNotFoundError(
                    f"{name} points at a missing directory: {path}"
                )

    def apply_offline_env(self, env: dict[str, str] | None = None) -> None:
        """Set HuggingFace/transformers/NLTK env vars **before** whisperx is
        imported. ``HF_HUB_OFFLINE`` is read at import time, so callers must run
        this prior to ``import whisperx``.
        """
        target = os.environ if env is None else env
        if self.offline:
            target.setdefault("HF_HUB_OFFLINE", "1")
            target.setdefault("TRANSFORMERS_OFFLINE", "1")
        if self.nltk_data_dir:
            existing = target.get("NLTK_DATA", "")
            # Bundled data wins: prepend so the shipped punkt_tab is found first
            # and NLTK never falls back to its network download.
            target["NLTK_DATA"] = (
                self.nltk_data_dir + os.pathsep + existing
                if existing
                else self.nltk_data_dir
            )


def load_from_env(env: dict[str, str] | None = None) -> ModelConfig:
    """Build a ``ModelConfig`` from ``QIE_*`` env vars (defaults to ``os.environ``)."""
    source = os.environ if env is None else env

    def clean(key: str) -> str | None:
        value = source.get(key)
        if value is None:
            return None
        value = value.strip()
        return value or None

    return ModelConfig(
        whisper_model_dir=clean("QIE_WHISPER_MODEL_DIR"),
        align_model_dir=clean("QIE_ALIGN_MODEL_DIR"),
        offline=(source.get("QIE_OFFLINE", "").strip().lower() in _TRUTHY),
        nltk_data_dir=clean("QIE_NLTK_DATA"),
    )
