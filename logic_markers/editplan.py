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
LAST_WORD_FALLBACK_SEC = 0.4  # assumed duration when the final word lacks an end


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
    # Keep alphanumerics (Unicode-aware, so non-Latin words survive), drop
    # punctuation/whitespace.
    return "".join(c for c in token.lower() if c.isalnum())


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


def _word_end(word, by_id: dict) -> float:
    # WhisperX occasionally omits a word's end. The next word's start is a safe
    # upper bound; for the very last word (no successor) assume a short duration
    # rather than collapsing onto its start, which would clip it.
    if word.end is not None:
        return word.end
    nxt = by_id.get(word.id + 1)
    return nxt.start if nxt else word.start + LAST_WORD_FALLBACK_SEC


def boundary_limits(word_ids: list[int], transcript: Transcript, sr: int):
    """Sample bounds a block's snap must not cross: the adjacent transcript words.

    Prevents boundary snapping from reaching back over trimmed/previous words
    (or forward over the next block's / deleted words) and re-exporting them.
    """
    by_id = {w.id: w for w in transcript.words}
    prev_word = by_id.get(word_ids[0] - 1)
    next_word = by_id.get(word_ids[-1] + 1)
    limit_start = round(_word_end(prev_word, by_id) * sr) if prev_word else None
    limit_end = round(next_word.start * sr) if next_word else None
    return limit_start, limit_end


def _match(
    original_ids: list[int],
    edited_tokens: list[str],
    transcript: Transcript,
    *,
    allow_replace: bool = True,
) -> list[int]:
    """Map surviving edited tokens back to original word ids.

    With `allow_replace` (segment-constrained matching), a word the user
    *corrected* — e.g. "Hayes" -> "Haze" — is kept, not dropped. Global fallback
    matching stays exact-only, since a loose replace there could grab the wrong
    repeated word.
    """
    original = [_norm(transcript.word(wid).text) for wid in original_ids]
    matcher = difflib.SequenceMatcher(None, original, edited_tokens, autojunk=False)
    kept: list[int] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            kept.extend(original_ids[i1:i2])
        elif tag == "replace" and allow_replace:
            edited_span = edited_tokens[j1:j2]
            if (i2 - i1) == (j2 - j1):
                kept.extend(original_ids[i1:i2])  # 1:1 corrections -> keep all
            else:
                # many<->few: keep only originals that closely match an edited
                # token (a correction); the rest of the span is a deletion.
                for k in range(i1, i2):
                    if any(
                        difflib.SequenceMatcher(None, original[k], e).ratio() >= 0.6
                        for e in edited_span
                    ):
                        kept.append(original_ids[k])
    return kept


def resolve_blocks(parsed: list[list[ParsedLine]], transcript: Transcript) -> list[Block]:
    seg_by_id = {seg.id: seg for seg in transcript.segments}
    by_id = {w.id: w for w in transcript.words}
    seg_of = {wid: seg.id for seg in transcript.segments for wid in seg.word_ids}
    all_ids = [w.id for w in transcript.words]
    out: list[Block] = []

    for block in parsed:
        kept: list[int] = []
        warnings: list[str] = []

        for line in block:
            tokens = _tokens(line.text)
            if line.segment_id is None:
                kept.extend(_match(all_ids, tokens, transcript, allow_replace=False))
                warnings.append(
                    f"line without [n] tag matched globally (may be ambiguous): {line.text!r}"
                )
                continue
            segment = seg_by_id.get(line.segment_id)
            if segment is None:
                warnings.append(f"unknown segment [{line.segment_id}] ignored")
                continue
            kept.extend(_match(list(segment.word_ids), tokens, transcript))

        if not kept:
            continue  # whole block deleted / unresolvable

        # Split wherever a whole tagged line (segment) was deleted between two
        # kept words, so removed chunks are never re-exported. Intra-segment
        # word deletions stay contiguous (fine-tuning is a Logic job).
        runs: list[list[int]] = [[kept[0]]]
        for prev_id, cur_id in zip(kept, kept[1:]):
            sp, sc = seg_of.get(prev_id), seg_of.get(cur_id)
            segment_dropped = sp is not None and sc is not None and sc > sp + 1
            if segment_dropped:
                runs.append([cur_id])
            else:
                runs[-1].append(cur_id)

        for run in runs:
            words = [by_id[wid] for wid in run]
            run_segment_ids = list(dict.fromkeys(seg_of[wid] for wid in run if wid in seg_of))
            run_warnings = list(warnings)
            if len(runs) > 1:
                run_warnings.append(
                    f"auto-split into {len(runs)} files (a deleted line separates them)"
                )
            out.append(
                Block(
                    index=len(out),
                    word_ids=run,
                    start=min(w.start for w in words),
                    end=max(_word_end(w, by_id) for w in words),
                    segment_ids=run_segment_ids,
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
