"""Pure, network-free post-processing of stage-2 LLM clips.

This is where the fixture-tested logic lives: strict JSON-span validation,
sentence-span -> word-ID mapping, duration computed from samples (never the
LLM's estimate), duration-window enforcement, dedupe/merge across window seams,
ranking, and song-label validation.
"""

from __future__ import annotations

from .models import CutCandidate, ProductSpec, ProductType, Sentence

_VALID_TYPES = {t.value for t in ProductType}


def _norm_tokens(text: str) -> list[str]:
    return ["".join(c for c in w.lower() if c.isalnum()) for w in text.split()]


_SONG_STOPWORDS = {"the", "a", "an", "of", "to", "and", "in", "on", "for", "my", "me", "it", "is"}


def validate_clip(raw: dict) -> tuple[bool, str]:
    """Strict validation of a raw stage-2 clip dict. Returns (ok, reason)."""
    ptype = raw.get("type")
    if ptype not in _VALID_TYPES:
        return False, f"unknown type {ptype!r}"
    start, end = raw.get("start"), raw.get("end")
    if not isinstance(start, int) or isinstance(start, bool):
        return False, "start is not an int"
    if not isinstance(end, int) or isinstance(end, bool):
        return False, "end is not an int"
    if start < 0 or end < 0:
        return False, "negative index"
    if start > end:
        return False, "start > end"
    label = raw.get("label")
    if not isinstance(label, str) or not label.strip():
        return False, "missing label"
    return True, ""


def verify_song(song: str, transcript_text: str) -> bool:
    """A song label is verified if every significant title token appears in the
    transcript text (case/punctuation-insensitive)."""
    if not song:
        return False
    title = [t for t in _norm_tokens(song) if t and t not in _SONG_STOPWORDS]
    if not title:
        return False  # nothing significant to match -> leave unverified
    corpus = set(t for t in _norm_tokens(transcript_text) if t)
    return all(t in corpus for t in title)


def build_candidate(
    sentences: list[Sentence],
    raw: dict,
    specs: dict[ProductType, ProductSpec],
    sample_rate: int,
) -> CutCandidate:
    """Map a validated clip's sentence span to word IDs and samples.

    Indices are clamped into range. Duration is derived from the sentences'
    sample positions — the LLM's own duration guess is ignored.
    """
    n = len(sentences)
    start = max(0, min(int(raw["start"]), n - 1))
    end = max(start, min(int(raw["end"]), n - 1))
    span = sentences[start : end + 1]

    word_ids: list[int] = []
    for s in span:
        word_ids.extend(s.word_ids)

    start_sample = span[0].start_sample
    end_sample = span[-1].end_sample
    duration_sec = (end_sample - start_sample) / sample_rate

    product_type = ProductType(raw["type"])
    song = raw.get("song")
    if not isinstance(song, str) or not song.strip():
        song = None
    text = " ".join(s.text for s in span)
    song_verified = verify_song(song, text) if song else False

    warnings: list[str] = []
    if song and not song_verified:
        warnings.append(f"song {song!r} not found in clip text (unverified)")

    return CutCandidate(
        product_type=product_type,
        start_index=start,
        end_index=end,
        label=str(raw["label"]).strip(),
        song=song,
        song_verified=song_verified,
        word_ids=word_ids,
        start_sample=start_sample,
        end_sample=end_sample,
        start_sec=span[0].start_sec,
        end_sec=span[-1].end_sec,
        duration_sec=duration_sec,
        warnings=warnings,
    )


def enforce_duration_window(
    candidates: list[CutCandidate], specs: dict[ProductType, ProductSpec]
) -> tuple[list[CutCandidate], list[CutCandidate]]:
    """Drop fragments (< hard_min) and absurd over-merges (> hard_max).

    Returns (kept, dropped). Clips inside the acceptance range but outside the
    tighter target window are kept, with a warning.
    """
    kept: list[CutCandidate] = []
    dropped: list[CutCandidate] = []
    for c in candidates:
        spec = specs[c.product_type]
        if c.duration_sec < spec.hard_min_sec or c.duration_sec > spec.hard_max_sec:
            dropped.append(c)
            continue
        if not (spec.target_min_sec <= c.duration_sec <= spec.target_max_sec):
            c.warnings.append(
                f"duration {c.duration_sec:.0f}s outside target "
                f"{spec.target_min_sec:.0f}-{spec.target_max_sec:.0f}s"
            )
        kept.append(c)
    return kept, dropped


def _overlap_sentences(a: CutCandidate, b: CutCandidate) -> int:
    lo = max(a.start_index, b.start_index)
    hi = min(a.end_index, b.end_index)
    return max(0, hi - lo + 1)


def _span_len(c: CutCandidate) -> int:
    return c.end_index - c.start_index + 1


def _norm_label(label: str) -> str:
    return " ".join(t for t in _norm_tokens(label) if t)


def merge_adjacent_same_label(
    candidates: list[CutCandidate],
    sentences: list[Sentence],
    specs: dict[ProductType, ProductSpec],
    sample_rate: int,
    max_gap_sentences: int = 2,
) -> list[CutCandidate]:
    """Merge runs of adjacent same-type, same-label candidates into one clip.

    Stage 2 sometimes over-splits one story into several fragments that carry the
    same label (e.g. three "Radney Foster and Musical Aspirations" pieces).
    `dedupe_overlapping` cannot fold them because they do not overlap, so they
    inflate candidate count and editor burden. A run of candidates of the same
    product type whose labels normalize equal and that sit within
    `max_gap_sentences` of each other is rebuilt as a single spanning candidate.
    """
    ordered = sorted(candidates, key=lambda c: (c.start_index, c.end_index))
    out: list[CutCandidate] = []
    i = 0
    while i < len(ordered):
        j = i
        while (
            j + 1 < len(ordered)
            and ordered[j + 1].product_type is ordered[i].product_type
            and _norm_label(ordered[j + 1].label) == _norm_label(ordered[i].label)
            and ordered[j + 1].start_index <= ordered[j].end_index + max_gap_sentences + 1
        ):
            j += 1
        if j == i:
            out.append(ordered[i])
        else:
            first, last = ordered[i], ordered[j]
            song = next((c.song for c in ordered[i : j + 1] if c.song), None)
            raw = {
                "type": first.product_type.value,
                "start": first.start_index,
                "end": last.end_index,
                "label": first.label,
                "song": song,
            }
            merged = build_candidate(sentences, raw, specs, sample_rate)
            spec = specs.get(first.product_type)
            if spec is not None and merged.duration_sec > spec.hard_max_sec:
                # An over-long merge would be dropped by enforce_duration_window,
                # taking the whole story with it; keep the fragments instead so
                # each individually-valid piece can survive on its own.
                out.extend(ordered[i : j + 1])
            else:
                merged.warnings.append(f"merged {j - i + 1} adjacent same-label fragments")
                out.append(merged)
        i = j + 1
    return out


def dedupe_overlapping(
    candidates: list[CutCandidate], min_overlap_ratio: float = 0.5
) -> list[CutCandidate]:
    """Drop near-duplicate spans (from window overlap); keep the longer one.

    Only candidates of the SAME product type are compared — an intro may
    legitimately live inside a broader spotlight, so overlap across types is not
    a duplicate. Two same-type candidates are duplicates when their overlap is at
    least `min_overlap_ratio` of the shorter span (a relative threshold, so a few
    shared transition sentences between distinct stories do not collapse them).
    The longer span survives.
    """
    ordered = sorted(candidates, key=lambda c: (c.start_index, c.end_index))
    kept: list[CutCandidate] = []
    for c in ordered:
        absorbed = False
        i = 0
        while i < len(kept):
            k = kept[i]
            if k.product_type is not c.product_type:
                i += 1
                continue
            overlap = _overlap_sentences(c, k)
            if overlap and overlap / min(_span_len(c), _span_len(k)) >= min_overlap_ratio:
                if _span_len(c) > _span_len(k):
                    # c is the longer span: k is a duplicate of c. Drop k and keep
                    # scanning — c may duplicate further retained clips too, so we
                    # must not stop at the first match (that left duplicates).
                    kept.pop(i)
                    continue
                # k is at least as long: c is absorbed by k and is discarded.
                absorbed = True
                break
            i += 1
        if not absorbed:
            kept.append(c)
    return kept


def _score(c: CutCandidate, spec: ProductSpec) -> float:
    """Display-only score: 1.0 inside the target window, decaying outside."""
    if spec.target_min_sec <= c.duration_sec <= spec.target_max_sec:
        return 1.0
    center = (spec.target_min_sec + spec.target_max_sec) / 2
    half = max(1.0, (spec.target_max_sec - spec.target_min_sec) / 2)
    return round(max(0.0, 1.0 - abs(c.duration_sec - center) / (half * 4)), 3)


def rank_candidates(
    candidates: list[CutCandidate], specs: dict[ProductType, ProductSpec]
) -> list[CutCandidate]:
    """Assign a display score and a 1-based rank (higher score first, then order)."""
    for c in candidates:
        c.score = _score(c, specs[c.product_type])
    ordered = sorted(candidates, key=lambda c: (-c.score, c.start_index))
    for i, c in enumerate(ordered, start=1):
        c.rank = i
    return ordered
