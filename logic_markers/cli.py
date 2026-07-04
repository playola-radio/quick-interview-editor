"""logic-markers: transcribe an audio file and embed word markers for Logic Pro.

Pipeline: transcribe original -> convert to AIFF -> map words to sample-frame
positions -> write MARK chunk -> emit `<name>.markers.aiff` next to the source.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from . import aiff_markers
from .audio import convert_to_aiff
from .transcribe import Word
from .words import Transcript, render_transcript


def _load_or_transcribe_transcript(source: Path, refresh: bool) -> Transcript:
    """Full WhisperX transcript (words + segments), cached next to the source."""
    from .whisperx_backend import transcribe_transcript

    cache = source.with_suffix(source.suffix + ".transcript.json")
    if cache.exists() and not refresh:
        print(f"      using cached transcript ({cache.name}); pass --refresh to redo.")
        return Transcript.from_dict(json.loads(cache.read_text()))

    transcript = transcribe_transcript(source)
    cache.write_text(json.dumps(transcript.to_dict(), indent=2))
    return transcript


def _transcribe(source: Path, engine: str, api_key: str | None) -> list[Word]:
    if engine == "whisperx":
        from .whisperx_backend import transcribe_words

        return transcribe_words(source)
    elif engine == "openai":
        from .transcribe import transcribe_words

        return transcribe_words(source, api_key)
    raise ValueError(f"unknown engine: {engine}")


def _load_or_transcribe(
    source: Path, engine: str, api_key: str | None, refresh: bool
) -> list[Word]:
    """Transcribe, caching the words next to the source (keyed by engine).

    Re-running while iterating on the marker format shouldn't repeat an
    expensive transcription. `--refresh` forces a new one.
    """
    cache = source.with_suffix(source.suffix + f".{engine}.json")
    if cache.exists() and not refresh:
        data = json.loads(cache.read_text())
        print(f"      using cached transcript ({cache.name}); pass --refresh to redo.")
        return [Word(text=w["text"], start=w["start"]) for w in data]

    words = _transcribe(source, engine, api_key)
    cache.write_text(
        json.dumps([{"text": w.text, "start": w.start} for w in words], indent=2)
    )
    return words


def build_markers(words, sample_rate: int) -> list[aiff_markers.Marker]:
    """Map words to markers with strictly increasing, order-preserving positions.

    Accurate (forced-aligned) timestamps rarely collide, but as a safety net we
    still walk words in spoken order and nudge any tie one frame forward so two
    markers never stack on the same sample position or get reordered by Logic.
    """
    markers = []
    last_position = -1
    for i, w in enumerate(words):
        position = round(w.start * sample_rate)
        if position <= last_position:
            position = last_position + 1
        last_position = position
        markers.append(
            aiff_markers.Marker(
                id=i + 1,  # positive, unique
                position=position,
                name=w.text.strip(),
            )
        )
    return markers


def run(
    source: Path,
    engine: str,
    api_key: str | None,
    sample_rate: int,
    refresh: bool = False,
) -> Path:
    dest = source.with_suffix("").with_name(source.stem + ".markers.aiff")

    print(f"[1/4] Transcribing {source.name} ({engine}, word timestamps)...")
    words = _load_or_transcribe(source, engine, api_key, refresh)
    print(f"      {len(words)} words.")

    print(f"[2/4] Converting to linear PCM AIFF @ {sample_rate} Hz...")
    convert_to_aiff(source, dest, sample_rate)

    aiff_bytes = dest.read_bytes()
    actual_rate = aiff_markers.read_sample_rate(aiff_bytes)
    if actual_rate != sample_rate:
        print(f"      note: AIFF reports {actual_rate} Hz; using that for positions.")

    print(f"[3/4] Building {len(words)} markers...")
    markers = build_markers(words, actual_rate)

    print("[4/4] Writing MARK chunk...")
    dest.write_bytes(aiff_markers.add_markers(aiff_bytes, markers))

    return dest


def _cmd_markers(args) -> int:
    if args.engine == "openai" and not args.api_key:
        print(
            "error: --engine openai needs a key. Pass --api-key or set OPENAI_KEY.",
            file=sys.stderr,
        )
        return 2
    dest = run(args.input, args.engine, args.api_key, args.sample_rate, args.refresh)
    print(f"\nDone -> {dest}")
    print("In Logic: Navigate > Other > Import Markers from Audio File, pick that AIFF.")
    return 0


def _cmd_transcript(args) -> int:
    print(f"Transcribing {args.input.name} (WhisperX)...")
    transcript = _load_or_transcribe_transcript(args.input, args.refresh)
    out = args.input.with_suffix(".txt")
    out.write_text(render_transcript(transcript))
    print(f"      {len(transcript.words)} words in {len(transcript.segments)} segments.")
    print(f"\nEdit this, then run `logic-markers cut`:\n  {out}")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="logic-markers",
        description="Transcribe audio, embed Logic markers, and chunk by transcript.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    m = sub.add_parser("markers", help="embed word markers into an AIFF")
    m.add_argument("input", type=Path, help="source audio (wav/mp3/m4a/aiff)")
    m.add_argument("--engine", choices=["whisperx", "openai"], default="whisperx")
    m.add_argument("--sample-rate", type=int, default=44100)
    m.add_argument("--refresh", action="store_true", help="ignore cached transcript")
    m.add_argument(
        "--api-key",
        default=os.environ.get("OPENAI_KEY") or os.environ.get("OPENAI_API_KEY"),
        help="OpenAI API key for --engine openai (defaults to $OPENAI_KEY)",
    )
    m.set_defaults(func=_cmd_markers)

    t = sub.add_parser("transcript", help="write an editable transcript for chunking")
    t.add_argument("input", type=Path, help="source audio (wav/mp3/m4a/aiff)")
    t.add_argument("--refresh", action="store_true", help="ignore cached transcript")
    t.set_defaults(func=_cmd_transcript)

    args = parser.parse_args(argv)

    if not args.input.exists():
        print(f"error: no such file: {args.input}", file=sys.stderr)
        return 2

    try:
        return args.func(args)
    except Exception as exc:  # fail fast with a clear message
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
