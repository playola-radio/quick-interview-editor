"""WhisperX transcription + wav2vec2 forced alignment.

Whisper guesses word times from attention and can collapse or reorder adjacent
words. WhisperX instead force-aligns the transcript to the audio with an
acoustic model, giving precise per-word start/end times. Runs locally on CPU
(Apple Silicon: faster-whisper is CPU-only via CTranslate2; that's fine for
short clips).
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import wave
from pathlib import Path

from .transcribe import Word

SAMPLE_RATE = 16000  # WhisperX / Whisper operate on 16 kHz mono


def _load_audio_16k_mono(source: Path):
    """Decode audio to a 16 kHz mono float32 array using afconvert (no ffmpeg).

    WhisperX's own load_audio() shells out to ffmpeg; we avoid that dependency
    by leaning on macOS's built-in afconvert, matching the array shape/scaling
    whisperx expects.
    """
    import numpy as np

    fd, wav_path = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    try:
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1",
             str(source), wav_path],
            check=True,
            capture_output=True,
        )
        with wave.open(wav_path, "rb") as w:
            frames = w.readframes(w.getnframes())
    finally:
        os.unlink(wav_path)
    return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0


def transcribe_words(
    source: Path,
    model_name: str = "large-v2",
    device: str = "cpu",
    compute_type: str = "int8",
) -> list[Word]:
    import whisperx  # imported lazily; heavy import

    audio = _load_audio_16k_mono(source)

    model = whisperx.load_model(model_name, device, compute_type=compute_type)
    result = model.transcribe(audio, batch_size=16)
    language = result["language"]

    align_model, metadata = whisperx.load_align_model(
        language_code=language, device=device
    )
    aligned = whisperx.align(
        result["segments"],
        align_model,
        metadata,
        audio,
        device,
        return_char_alignments=False,
    )

    words: list[Word] = []
    for segment in aligned["segments"]:
        for w in segment.get("words", []):
            text = w.get("word", "").strip()
            start = w.get("start")
            if text and start is not None:
                words.append(Word(text=text, start=float(start)))
    return words
