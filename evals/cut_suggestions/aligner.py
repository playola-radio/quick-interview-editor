"""Map proposed clip labels to shipped ground-truth topics (semantic match).

Two aligners with the same interface `align(proposed, shipped) -> dict` returning
`{"matches": [{"shipped", "proposed"}], "missed": [...], "extra": [...]}`:

- `LLMAligner` — an LLM aligns labels semantically (labels differ in wording).
  The call routes through the injected LLM client, so it is cached like any
  other call.
- `rule_align` — a deterministic token-overlap fallback for offline use.
"""

from __future__ import annotations

import json

_STOPWORDS = {
    "the", "a", "an", "of", "to", "and", "in", "on", "for", "with", "as", "at",
    "my", "his", "her", "their", "out", "up", "be", "is", "was", "it",
}


def _tokens(label: str) -> set[str]:
    toks = {"".join(c for c in w.lower() if c.isalnum()) for w in label.split()}
    return {t for t in toks if t and t not in _STOPWORDS}


def alignment_prompt(proposed: list[str], shipped: list[str]) -> str:
    return (
        "Two lists describe topic clips from the same recording. GROUND TRUTH is "
        "what was actually shipped; PROPOSED is what a model suggested. Match them "
        "semantically (labels differ in wording). Return STRICT JSON: "
        '{"matches": [{"shipped": "<gt>", "proposed": "<prop or null>"}], '
        '"missed": ["<gt not found>"], "extra": ["<proposed not in gt>"]}.\n\n'
        f"GROUND TRUTH:\n{json.dumps(shipped)}\n\nPROPOSED:\n{json.dumps(proposed)}"
    )


def _validate_alignment(raw: dict, proposed: list[str], shipped: list[str]) -> dict:
    """Coerce a raw LLM alignment into a trustworthy one-to-one mapping.

    The LLM's own `missed`/`extra` are not trusted; they are derived here from a
    validated shipped->proposed map: each non-null proposed must be one of the
    inputs, used at most once, and each shipped label mapped at most once.
    """
    shipped_set = set(shipped)
    proposed_set = set(proposed)
    raw_matches = raw.get("matches", []) if isinstance(raw, dict) else []

    mapping: dict[str, str | None] = {}
    used_proposed: set[str] = set()
    for m in raw_matches:
        if not isinstance(m, dict):
            continue
        s = m.get("shipped")
        p = m.get("proposed")
        if s not in shipped_set or s in mapping:
            continue  # unknown or duplicate shipped label
        if isinstance(p, str) and p in proposed_set and p not in used_proposed:
            mapping[s] = p
            used_proposed.add(p)
        else:
            mapping[s] = None  # null, hallucinated, or already-claimed proposed

    matches = [{"shipped": s, "proposed": mapping.get(s)} for s in shipped]
    missed = [s for s in shipped if not mapping.get(s)]
    extra = [p for p in proposed if p not in used_proposed]
    return {"matches": matches, "missed": missed, "extra": extra}


class LLMAligner:
    def __init__(self, llm):
        self.llm = llm

    def align(self, proposed: list[str], shipped: list[str]) -> dict:
        resp = self.llm.complete(alignment_prompt(proposed, shipped), purpose="align")
        return _validate_alignment(json.loads(resp.text), proposed, shipped)

    def __call__(self, proposed: list[str], shipped: list[str]) -> dict:
        return self.align(proposed, shipped)


def rule_align(proposed: list[str], shipped: list[str], min_overlap: int = 1) -> dict:
    """Greedy token-overlap alignment: each shipped topic claims the best-scoring
    unused proposed label sharing at least `min_overlap` significant tokens."""
    prop_tokens = [(p, _tokens(p)) for p in proposed]
    used: set[int] = set()
    matches = []
    missed = []
    for gt in shipped:
        gt_toks = _tokens(gt)
        best_i, best_score = -1, 0
        for i, (_p, ptoks) in enumerate(prop_tokens):
            if i in used:
                continue
            score = len(gt_toks & ptoks)
            if score > best_score:
                best_i, best_score = i, score
        if best_i >= 0 and best_score >= min_overlap:
            used.add(best_i)
            matches.append({"shipped": gt, "proposed": prop_tokens[best_i][0]})
        else:
            matches.append({"shipped": gt, "proposed": None})
            missed.append(gt)
    extra = [p for i, p in enumerate(proposed) if i not in used]
    return {"matches": matches, "missed": missed, "extra": extra}
