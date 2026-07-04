"""Parse an edited transcript and resolve each block to a word range.

Robustness comes from the `[n]` line tags: a kept line is matched only against
its own segment's words, so repeated phrases elsewhere in the transcript can't
cause a mismatch. Fuzzy matching (difflib) is used only inside that known range
to honor intra-line word deletions.
"""

from __future__ import annotations

import difflib
import re
from dataclasses import dataclass, field

from .silence import Silence
from .words import Transcript

SCHEMA_VERSION = 1
DEFAULT_MAX_GAP_SEC = 1.0  # deletions longer than this split a block into files


@dataclass(frozen=True)
class ParsedLine:
    segment_id: int | None
    text: str


@dataclass
class Block:
    index: int              # output order (which file)
    word_ids: list[int]     # surviving words, in order
    start: float            # content start (seconds)
    end: float              # content end (seconds)
    segment_ids: list[int]
    warnings: list[str] = field(default_factory=list)


_TAG = re.compile(r"^\[(\d+)\]\s*(.*)$")


def _norm(token: str) -> str:
    return re.sub(r"[^a-z0-9]", "", token.lower())


def _tokens(text: str) -> list[str]:
    return [t for t in (_norm(x) for x in text.split()) if t]


def parse_edit_file(text: str) -> list[list[ParsedLine]]:
    """Split into blocks (blank-line separated); drop comments; parse `[n]` tags."""
    blocks: list[list[ParsedLine]] = []
    current: list[ParsedLine] = []
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("#"):
            continue
        if line == "":
            if current:
                blocks.append(current)
                current = []
            continue
        m = _TAG.match(line)
        if m:
            current.append(ParsedLine(int(m.group(1)), m.group(2)))
        else:
            current.append(ParsedLine(None, line))
    if current:
        blocks.append(current)
    return blocks


def _match(original_ids: list[int], edited_tokens: list[str], transcript: Transcript) -> list[int]:
    original = [_norm(transcript.word(wid).text) for wid in original_ids]
    matcher = difflib.SequenceMatcher(None, original, edited_tokens, autojunk=False)
    kept: list[int] = []
    for a, _b, size in matcher.get_matching_blocks():
        kept.extend(original_ids[a : a + size])
    return kept


def resolve_blocks(
    parsed: list[list[ParsedLine]],
    transcript: Transcript,
    max_gap_sec: float = DEFAULT_MAX_GAP_SEC,
) -> list[Block]:
    seg_by_id = {seg.id: seg for seg in transcript.segments}
    by_id = {w.id: w for w in transcript.words}
    all_ids = [w.id for w in transcript.words]
    out: list[Block] = []

    def word_end(word) -> float:
        # WhisperX occasionally omits a word's end; the next word's start is a
        # safe upper bound so we never shrink the span onto the word's start.
        if word.end is not None:
            return word.end
        nxt = by_id.get(word.id + 1)
        return nxt.start if nxt else word.start

    for block in parsed:
        kept: list[int] = []
        segment_ids: list[int] = []
        warnings: list[str] = []

        for line in block:
            tokens = _tokens(line.text)
            if line.segment_id is None:
                kept.extend(_match(all_ids, tokens, transcript))
                warnings.append(
                    f"line without [n] tag matched globally (may be ambiguous): {line.text!r}"
                )
                continue
            segment = seg_by_id.get(line.segment_id)
            if segment is None:
                warnings.append(f"unknown segment [{line.segment_id}] ignored")
                continue
            segment_ids.append(segment.id)
            kept.extend(_match(list(segment.word_ids), tokens, transcript))

        if not kept:
            continue  # whole block deleted / unresolvable

        # Split at large deletions so removed audio is never re-exported.
        runs: list[list[int]] = [[kept[0]]]
        for prev_id, cur_id in zip(kept, kept[1:]):
            deleted_between = cur_id > prev_id + 1
            gap = by_id[cur_id].start - word_end(by_id[prev_id])
            if deleted_between and gap > max_gap_sec:
                runs.append([cur_id])
            else:
                runs[-1].append(cur_id)

        for run_i, run in enumerate(runs):
            words = [by_id[wid] for wid in run]
            run_warnings = list(warnings)
            if len(runs) > 1:
                run_warnings.append(
                    f"auto-split into {len(runs)} files at deletions > {max_gap_sec}s"
                )
            out.append(
                Block(
                    index=len(out),
                    word_ids=run,
                    start=min(w.start for w in words),
                    end=max(word_end(w) for w in words),
                    segment_ids=segment_ids,
                    warnings=run_warnings,
                )
            )
    return out


@dataclass
class ResolvedSegment:
    index: int
    output_name: str
    word_ids: list[int]
    content_start_sample: int
    content_end_sample: int
    start_sample: int
    end_sample: int
    start_status: str
    end_status: str
    overlaps_previous: bool
    overlaps_next: bool
    segment_ids: list[int]
    warnings: list[str]


def _sample(seconds: float | None, sr: int) -> int | None:
    return None if seconds is None else round(seconds * sr)


def build_edit_plan(
    *,
    source_path,
    sample_rate: int,
    channels: int,
    total_samples: int,
    params: dict,
    transcript: Transcript,
    silences: list[Silence],
    segments: list[ResolvedSegment],
) -> dict:
    """Assemble the versioned, reproducible edit-plan the GUI will also consume."""
    return {
        "schema_version": SCHEMA_VERSION,
        "source": {
            "path": str(source_path),
            "sample_rate": sample_rate,
            "channels": channels,
            "duration_samples": total_samples,
        },
        "params": params,
        "words": [
            {
                "id": w.id,
                "text": w.text,
                "start": w.start,
                "end": w.end,
                "start_sample": _sample(w.start, sample_rate),
                "end_sample": _sample(w.end, sample_rate),
            }
            for w in transcript.words
        ],
        "silences": [{"start": s.start, "end": s.end} for s in silences],
        "segments": [
            {
                "index": s.index,
                "output_name": s.output_name,
                "word_ids": s.word_ids,
                "content_start_sample": s.content_start_sample,
                "content_end_sample": s.content_end_sample,
                "source_start_sample": s.start_sample,
                "source_end_sample": s.end_sample,
                "start_status": s.start_status,
                "end_status": s.end_status,
                "overlaps_previous": s.overlaps_previous,
                "overlaps_next": s.overlaps_next,
                "segment_ids": s.segment_ids,
                "warnings": s.warnings,
            }
            for s in segments
        ],
    }
