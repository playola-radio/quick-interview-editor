"""logic-markers: transcribe an audio file and embed word markers for Logic Pro.

Pipeline: transcribe original -> convert to AIFF -> map words to sample-frame
positions -> write MARK chunk -> emit `<name>.markers.aiff` next to the source.
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import tempfile
from pathlib import Path

from . import aiff_markers
from .audio import convert_to_aiff, read_aiff_mono
from .boundaries import snap_boundaries
from .editplan import (
    ResolvedSegment,
    _word_end,
    boundary_limits,
    build_edit_plan,
    parse_edit_file,
    resolve_blocks,
)
from .silence import detect_silences
from .slicer import slice_aiff
from .transcribe import Word
from .words import Transcript, Word as RichWord, render_transcript

SNAP_PARAMS = {"search_radius_ms": 800.0, "roll_ms": 20.0, "pad_ms": 100.0, "tail_ms": 250.0}
SILENCE_PARAMS = {"min_silence_ms": 120.0, "margin_db": 8.0, "floor_percentile": 20.0}


def _emit_event(event: dict) -> None:
    """One machine event per stderr line; stdout stays pure JSON."""
    print(f"QIE_EVENT {json.dumps(event)}", file=sys.stderr, flush=True)


def _progress(phase: str, message: str) -> None:
    _emit_event({"type": "progress", "phase": phase, "message": message})


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


def _load_or_transcribe_transcript_in(source: Path, work_dir: Path, refresh: bool) -> Transcript:
    """Same as `_load_or_transcribe_transcript`, but cached in `work_dir` (never beside source)."""
    from .whisperx_backend import transcribe_transcript

    cache = work_dir / (source.name + ".transcript.json")
    if cache.exists() and not refresh:
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


def run_cut(source: Path, edit_path: Path):
    """Cut the source into per-block AIFFs based on the edited transcript."""
    cache = source.with_suffix(source.suffix + ".transcript.json")
    if not cache.exists():
        raise RuntimeError(
            f"no transcript for {source.name}; run `logic-markers transcript` first"
        )
    transcript = Transcript.from_dict(json.loads(cache.read_text()))
    blocks = resolve_blocks(parse_edit_file(edit_path.read_text()), transcript)
    if not blocks:
        raise RuntimeError("nothing to export — the edited transcript has no words left")

    # Convert to a full linear-PCM AIFF once; slice it per block.
    fd, tmp = tempfile.mkstemp(suffix=".aiff")
    os.close(fd)
    try:
        convert_to_aiff(source, Path(tmp), 44100)
        aiff_bytes = Path(tmp).read_bytes()
    finally:
        os.unlink(tmp)

    sr = aiff_markers.read_sample_rate(aiff_bytes)
    _, _chunks = aiff_markers.parse_chunks(aiff_bytes)
    channels = struct.unpack(">h", dict(_chunks)[b"COMM"][0:2])[0]
    mono, _ = read_aiff_mono(aiff_bytes)
    total_samples = len(mono)
    silences = detect_silences(mono, sr, **SILENCE_PARAMS)

    # Every word is a marker candidate; the slicer keeps those inside each
    # slice. build_markers enforces strictly-increasing positions so colliding
    # timestamps can't stack or reorder inside a slice.
    all_markers = build_markers(transcript.words, sr)

    kept_ids = {wid for b in blocks for wid in b.word_ids}
    by_id = {w.id: w for w in transcript.words}
    resolved = []
    for b in blocks:
        limit_start, limit_end = boundary_limits(b.word_ids, transcript, sr)
        # A fade tail may bleed into the next KEPT chunk, but never into a
        # deleted word (that would re-export removed audio).
        next_word = by_id.get(b.word_ids[-1] + 1)
        hard_end = (
            round(next_word.start * sr)
            if next_word is not None and next_word.id not in kept_ids
            else None
        )
        bnd = snap_boundaries(
            b.start, b.end, silences, sr, total_samples,
            limit_start_sample=limit_start, limit_end_sample=limit_end,
            hard_end_sample=hard_end, **SNAP_PARAMS,
        )
        resolved.append((b, bnd))

    outputs: list[Path] = []
    segments: list[ResolvedSegment] = []
    for i, (block, bnd) in enumerate(resolved):
        prev_end = resolved[i - 1][1].end_sample if i > 0 else None
        next_start = resolved[i + 1][1].start_sample if i < len(resolved) - 1 else None
        name = f"{source.stem}.{block.index + 1}.aiff"
        out_path = source.parent / name
        out_path.write_bytes(slice_aiff(aiff_bytes, bnd.start_sample, bnd.end_sample, all_markers))
        outputs.append(out_path)
        segments.append(
            ResolvedSegment(
                index=block.index,
                output_name=name,
                word_ids=block.word_ids,
                content_start_sample=round(block.start * sr),
                content_end_sample=round(block.end * sr),
                start_sample=bnd.start_sample,
                end_sample=bnd.end_sample,
                start_status=bnd.start_status,
                end_status=bnd.end_status,
                overlaps_previous=prev_end is not None and bnd.start_sample < prev_end,
                overlaps_next=next_start is not None and bnd.end_sample > next_start,
                segment_ids=block.segment_ids,
                warnings=block.warnings,
            )
        )

    plan = build_edit_plan(
        source_path=source, sample_rate=sr, channels=channels,
        total_samples=total_samples, params={**SNAP_PARAMS, **SILENCE_PARAMS},
        transcript=transcript, silences=silences, segments=segments,
    )
    plan_path = source.with_suffix(source.suffix + ".edit-plan.json")
    plan_path.write_text(json.dumps(plan, indent=2))
    return outputs, plan_path, segments


def _cmd_cut(args) -> int:
    if not args.edit.exists():
        print(f"error: no such edit file: {args.edit}", file=sys.stderr)
        return 2
    outputs, plan_path, segments = run_cut(args.input, args.edit)
    print(f"Wrote {len(outputs)} file(s):")
    for out, seg in zip(outputs, segments):
        flags = []
        if seg.end_status == "padded":
            flags.append("tight end join (fade tail added)")
        if seg.start_status == "padded":
            flags.append("tight start")
        note = f"  [{'; '.join(flags)}]" if flags else "  [clean silence boundaries]"
        print(f"  {out.name}{note}")
        for w in seg.warnings:
            print(f"      warning: {w}")
    print(f"\nEdit plan: {plan_path.name}")
    print("Drag the .aiff files into Logic (markers travel with each file).")
    return 0


def _cmd_transcript(args) -> int:
    print(f"Transcribing {args.input.name} (WhisperX)...")
    transcript = _load_or_transcribe_transcript(args.input, args.refresh)
    out = args.input.with_suffix(".txt")
    out.write_text(render_transcript(transcript))
    print(f"      {len(transcript.words)} words in {len(transcript.segments)} segments.")
    print(f"\nEdit this, then run `logic-markers cut`:\n  {out}")
    return 0


def run_plan(source: Path, work_dir: Path, sample_rate: int, refresh: bool = False) -> dict:
    """Analyze (no cut): transcript + canonical AIFF + samples + silences → edit-plan dict."""
    work_dir.mkdir(parents=True, exist_ok=True)

    _progress("transcribing", "Transcribing with WhisperX (first run downloads models)")
    transcript = _load_or_transcribe_transcript_in(source, work_dir, refresh)

    _progress("converting", "Converting audio")
    aiff_path = work_dir / (source.stem + ".plan.aiff")
    convert_to_aiff(source, aiff_path, sample_rate)
    aiff_bytes = aiff_path.read_bytes()
    sr = aiff_markers.read_sample_rate(aiff_bytes)
    _, chunks = aiff_markers.parse_chunks(aiff_bytes)
    channels = struct.unpack(">h", dict(chunks)[b"COMM"][0:2])[0]
    mono, _ = read_aiff_mono(aiff_bytes)
    total_samples = len(mono)

    # WhisperX occasionally omits a word's end. Fill it with the engine's own
    # fallback, clamped to the audio duration so a trailing word's assumed
    # duration can't push end_sample past the end of the clip (which would poison
    # later selection/export math). Done here, after conversion, so the clip
    # duration is known.
    duration_sec = total_samples / sr
    by_id = {w.id: w for w in transcript.words}
    filled = tuple(
        w if w.end is not None
        else RichWord(id=w.id, text=w.text, start=w.start,
                      end=min(_word_end(w, by_id), duration_sec))
        for w in transcript.words
    )
    transcript = Transcript(words=filled, segments=transcript.segments)

    _progress("analyzing_silence", "Finding silence")
    silences = detect_silences(mono, sr, **SILENCE_PARAMS)

    _progress("writing_plan", "Preparing transcript")
    return build_edit_plan(
        source_path=source, sample_rate=sr, channels=channels,
        total_samples=total_samples, params={**SNAP_PARAMS, **SILENCE_PARAMS},
        transcript=transcript, silences=silences, segments=[],
    )


def run_render(source: Path, request_path: Path, work_dir: Path, sample_rate: int) -> dict:
    """Stateless render: convert the source once, then slice per request.

    The request (written by the app) carries canonical-rate word markers with
    ABSOLUTE sample positions and the slices to cut ({id, start_sample, end_sample}).
    Markers are taken as-is — the engine never rebuilds them from seconds, so no
    rounding drift is reintroduced. Each slice becomes `<work-dir>/<id>.aiff`; the
    returned dict is keyed by slice id (not request order). Writes only into
    `work_dir`.
    """
    work_dir.mkdir(parents=True, exist_ok=True)
    request = json.loads(request_path.read_text())
    req_rate = int(request.get("sample_rate", sample_rate))

    # Incoming ids are ignored (slice_aiff renumbers per slice); positions are
    # authoritative and preserved.
    markers = [
        aiff_markers.Marker(id=i + 1, position=int(m["position"]), name=str(m["name"]))
        for i, m in enumerate(request.get("markers", []))
    ]
    slices = request.get("slices", [])
    total = len(slices)

    _emit_event({"type": "progress", "phase": "rendering", "message": "Converting audio",
                 "index": 0, "total": total})
    aiff_path = work_dir / "render.aiff"
    convert_to_aiff(source, aiff_path, req_rate)
    aiff_bytes = aiff_path.read_bytes()

    out_slices = []
    for i, spec in enumerate(slices):
        _emit_event({"type": "progress", "phase": "rendering",
                     "message": f"Rendering slice {i + 1} of {total}",
                     "index": i + 1, "total": total})
        start = int(spec["start_sample"])
        end = int(spec["end_sample"])
        out_path = work_dir / f"{spec['id']}.aiff"
        out_path.write_bytes(slice_aiff(aiff_bytes, start, end, markers))
        out_slices.append({"id": spec["id"], "path": str(out_path),
                           "start_sample": start, "end_sample": end})

    return {"slices": out_slices}


def _redirect_stdout_during(func):
    """Run `func`, keeping stdout a pure-JSON channel (see `_cmd_plan`'s note).

    afconvert output is captured elsewhere, but redirecting fd 1 → 2 for the whole
    render is cheap insurance against any library writing to stdout, and mirrors the
    proven `plan` path exactly."""
    sys.stdout.flush()
    saved_stdout_fd = os.dup(1)
    try:
        os.dup2(2, 1)
        return func()
    finally:
        sys.stdout.flush()
        os.dup2(saved_stdout_fd, 1)
        os.close(saved_stdout_fd)


def _cmd_render(args) -> int:
    if not args.request.exists():
        print(f"error: no such request file: {args.request}", file=sys.stderr)
        return 2
    result = _redirect_stdout_during(
        lambda: run_render(args.input, args.request, args.work_dir, args.sample_rate)
    )
    json.dump(result, sys.stdout)
    sys.stdout.flush()
    return 0


def _cmd_plan(args) -> int:
    # stdout is a pure-JSON channel the app decodes wholesale. WhisperX/pyannote
    # emit `logging` INFO records to stdout during transcription, which would
    # corrupt that JSON. Redirect fd 1 to stderr for the whole analysis (progress
    # already flows over stderr as QIE_EVENT lines, and the app ignores any stderr
    # line without that prefix), then restore the real stdout and write only the
    # plan JSON to it. Operating at the fd level catches Python- and C-level writes.
    sys.stdout.flush()
    saved_stdout_fd = os.dup(1)
    try:
        os.dup2(2, 1)
        plan = run_plan(args.input, args.work_dir, args.sample_rate, args.refresh)
    finally:
        sys.stdout.flush()
        os.dup2(saved_stdout_fd, 1)
        os.close(saved_stdout_fd)
    json.dump(plan, sys.stdout)
    sys.stdout.flush()
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

    c = sub.add_parser("cut", help="split audio into AIFFs from an edited transcript")
    c.add_argument("input", type=Path, help="source audio (must match the transcript)")
    c.add_argument("edit", type=Path, help="the edited transcript .txt")
    c.set_defaults(func=_cmd_cut)

    p = sub.add_parser("plan", help="analyze audio into an edit-plan (no cut); JSON to stdout")
    p.add_argument("input", type=Path, help="source audio (wav/mp3/m4a/aiff)")
    p.add_argument("--work-dir", type=Path, required=True, help="scratch dir for caches (NOT next to source)")
    p.add_argument("--sample-rate", type=int, default=44100)
    p.add_argument("--refresh", action="store_true", help="ignore cached transcript")
    p.set_defaults(func=_cmd_plan)

    r = sub.add_parser("render", help="render slices to AIFFs from a request file; JSON to stdout")
    r.add_argument("input", type=Path, help="source audio (wav/mp3/m4a/aiff)")
    r.add_argument("--request", type=Path, required=True, help="request.json (markers + slices)")
    r.add_argument("--work-dir", type=Path, required=True, help="scratch dir for AIFFs (NOT next to source)")
    r.add_argument("--sample-rate", type=int, default=44100, help="fallback canonical rate")
    r.set_defaults(func=_cmd_render)

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
