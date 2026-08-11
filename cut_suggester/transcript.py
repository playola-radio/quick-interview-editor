"""Load a WhisperX transcript JSON into `Sentence` units.

The transcript contract matches the engine's `edit-plan.json` shape: a `words`
list (`id`/`text`/`start`/`end`) and a `segments` list (`id`/`word_ids`/`text`).
Each non-empty segment becomes one `Sentence`; sample positions are derived from
the word seconds at a nominal sample rate (transcripts carry only seconds).
"""

from __future__ import annotations

import json

from .config import DEFAULT_SAMPLE_RATE
from .models import Sentence

LAST_WORD_FALLBACK_SEC = 0.4  # assumed duration when a word lacks an end


def sentences_from_dict(data: dict, sample_rate: int = DEFAULT_SAMPLE_RATE) -> list[Sentence]:
    by_id = {w["id"]: w for w in data["words"]}
    out: list[Sentence] = []
    for seg in data["segments"]:
        word_ids = list(seg.get("word_ids", []))
        if not word_ids:
            continue  # nothing to anchor in audio; skip
        first = by_id[word_ids[0]]
        last = by_id[word_ids[-1]]
        start = first["start"]
        end = last["end"]
        if end is None:
            # No end on the final word: fall back to its start plus a short
            # duration rather than collapsing onto the start.
            end = last["start"] + LAST_WORD_FALLBACK_SEC
        out.append(
            Sentence(
                index=len(out),
                segment_id=seg["id"],
                text=seg["text"].strip(),
                word_ids=tuple(word_ids),
                start_sec=start,
                end_sec=end,
                start_sample=round(start * sample_rate),
                end_sample=round(end * sample_rate),
            )
        )
    return out


def load_transcript(path: str, sample_rate: int = DEFAULT_SAMPLE_RATE) -> list[Sentence]:
    with open(path) as f:
        return sentences_from_dict(json.load(f), sample_rate=sample_rate)


def sentences_from_units(units: list[dict]) -> list[Sentence]:
    """Build `Sentence`s from the app's pre-computed transcript units.

    The Swift `CutSuggestClient` already derived one unit per non-empty segment
    (text, word IDs, and canonical-rate samples) from `edit-plan.json`, so we take
    those directly rather than re-deriving from words+segments. Samples come from
    the unit (never recomputed from seconds), keeping Swift and the cutter on the
    exact same coordinates. Malformed input fails loud — the app is expected to send
    coherent units, and a silent skip would drift the stage indices.
    """
    out: list[Sentence] = []
    for i, u in enumerate(units):
        try:
            segment_id = int(u["id"])
            text = str(u["text"]).strip()
            word_ids = tuple(int(w) for w in u["word_ids"])
            start_sec = float(u["start_sec"])
            end_sec = float(u["end_sec"])
            start_sample = int(u["start_sample"])
            end_sample = int(u["end_sample"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"transcript unit {i} is malformed: {exc}") from exc
        if not text:
            raise ValueError(f"transcript unit {i} (segment {segment_id}) has empty text")
        if not word_ids:
            raise ValueError(f"transcript unit {i} (segment {segment_id}) has no word_ids")
        if end_sample < start_sample:
            raise ValueError(
                f"transcript unit {i} (segment {segment_id}) has end_sample < start_sample"
            )
        out.append(
            Sentence(
                index=i,  # stage indices reference position in this list, not segment_id
                segment_id=segment_id,
                text=text,
                word_ids=word_ids,
                start_sec=start_sec,
                end_sec=end_sec,
                start_sample=start_sample,
                end_sample=end_sample,
            )
        )
    return out
