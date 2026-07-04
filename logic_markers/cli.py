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


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="logic-markers",
        description="Transcribe audio and embed word markers Logic Pro can import.",
    )
    parser.add_argument("input", type=Path, help="source audio (wav/mp3/m4a/aiff)")
    parser.add_argument(
        "--engine",
        choices=["whisperx", "openai"],
        default="whisperx",
        help="whisperx = local forced alignment (accurate); openai = Whisper API",
    )
    parser.add_argument("--sample-rate", type=int, default=44100)
    parser.add_argument("--refresh", action="store_true", help="ignore cached transcript")
    parser.add_argument(
        "--api-key",
        default=os.environ.get("OPENAI_KEY") or os.environ.get("OPENAI_API_KEY"),
        help="OpenAI API key for --engine openai (defaults to $OPENAI_KEY)",
    )
    args = parser.parse_args(argv)

    if not args.input.exists():
        print(f"error: no such file: {args.input}", file=sys.stderr)
        return 2
    if args.engine == "openai" and not args.api_key:
        print(
            "error: --engine openai needs a key. Pass --api-key or set OPENAI_KEY.",
            file=sys.stderr,
        )
        return 2

    try:
        dest = run(args.input, args.engine, args.api_key, args.sample_rate, args.refresh)
    except Exception as exc:  # fail fast with a clear message
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(f"\nDone -> {dest}")
    print("In Logic: Navigate > Other > Import Markers from Audio File, pick that AIFF.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
