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

from .words import Transcript


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


def resolve_blocks(parsed: list[list[ParsedLine]], transcript: Transcript) -> list[Block]:
    seg_by_id = {seg.id: seg for seg in transcript.segments}
    all_ids = [w.id for w in transcript.words]
    out: list[Block] = []

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

        words = [transcript.word(wid) for wid in kept]
        start = min(w.start for w in words)
        end = max((w.end if w.end is not None else w.start) for w in words)
        out.append(
            Block(
                index=len(out),
                word_ids=kept,
                start=start,
                end=end,
                segment_ids=segment_ids,
                warnings=warnings,
            )
        )
    return out
