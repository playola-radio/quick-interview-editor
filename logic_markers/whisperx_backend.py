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
from .words import Segment, Transcript
from .words import Word as RichWord

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


def _aligned_segments(
    source: Path, model_name: str, device: str, compute_type: str
) -> list[dict]:
    import whisperx  # imported lazily; heavy import

    audio = _load_audio_16k_mono(source)
    model = whisperx.load_model(model_name, device, compute_type=compute_type)
    result = model.transcribe(audio, batch_size=16)
    align_model, metadata = whisperx.load_align_model(
        language_code=result["language"], device=device
    )
    aligned = whisperx.align(
        result["segments"], align_model, metadata, audio, device,
        return_char_alignments=False,
    )
    return aligned["segments"]


def transcribe_transcript(
    source: Path,
    model_name: str = "large-v2",
    device: str = "cpu",
    compute_type: str = "int8",
) -> Transcript:
    """Full transcription with per-word start/end grouped into segments."""
    segments_raw = _aligned_segments(source, model_name, device, compute_type)

    words: list[RichWord] = []
    segments: list[Segment] = []
    for seg in segments_raw:
        word_ids: list[int] = []
        for w in seg.get("words", []):
            text = w.get("word", "").strip()
            start = w.get("start")
            if not text or start is None:
                continue  # alignment dropped this token; skip
            wid = len(words) + 1
            end = w.get("end")
            words.append(
                RichWord(
                    id=wid,
                    text=text,
                    start=float(start),
                    end=float(end) if end is not None else None,
                )
            )
            word_ids.append(wid)
        if word_ids:
            seg_text = " ".join(words[i - 1].text for i in word_ids)
            segments.append(
                Segment(id=len(segments) + 1, word_ids=tuple(word_ids), text=seg_text)
            )
    return Transcript(words=tuple(words), segments=tuple(segments))


def transcribe_words(
    source: Path,
    model_name: str = "large-v2",
    device: str = "cpu",
    compute_type: str = "int8",
) -> list[Word]:
    """Flat word list (back-compat for the markers command)."""
    transcript = transcribe_transcript(source, model_name, device, compute_type)
    return [Word(text=w.text, start=w.start) for w in transcript.words]
