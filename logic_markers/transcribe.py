"""Word-level transcription via OpenAI's Whisper API.

Sends the ORIGINAL (compressed) audio file, not the converted AIFF, because an
uncompressed AIFF quickly exceeds Whisper's 25 MB upload limit.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import requests

WHISPER_URL = "https://api.openai.com/v1/audio/transcriptions"
MAX_UPLOAD_BYTES = 25 * 1024 * 1024  # Whisper hard limit


@dataclass(frozen=True)
class Word:
    text: str
    start: float  # seconds


def transcribe_words(source: Path, api_key: str, timeout: int = 300) -> list[Word]:
    size = source.stat().st_size
    if size > MAX_UPLOAD_BYTES:
        raise ValueError(
            f"{source.name} is {size / 1e6:.1f} MB, over Whisper's 25 MB limit. "
            "Trim the clip or transcode to a smaller compressed file first."
        )

    with source.open("rb") as fh:
        response = requests.post(
            WHISPER_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            data={
                "model": "whisper-1",
                "response_format": "verbose_json",
                "timestamp_granularities[]": "word",
            },
            files={"file": (source.name, fh)},
            timeout=timeout,
        )

    if response.status_code != 200:
        raise RuntimeError(
            f"Whisper API error {response.status_code}: {response.text[:500]}"
        )

    payload = response.json()
    words = payload.get("words")
    if not words:
        raise RuntimeError(
            "Whisper returned no word timestamps. Response keys: "
            f"{list(payload.keys())}"
        )
    return [Word(text=w["word"], start=float(w["start"])) for w in words]
