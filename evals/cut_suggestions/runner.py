"""Run the cut-suggestion eval over a dataset and report per-product metrics.

Run modes:
- `cached`  — deterministic, no network (for CI). A cache miss raises.
- `live`    — needs a key; writes responses through the cache (for prompt/model
              changes). Updating the checked-in baseline is a reviewed action.

Usage:
    python -m evals.cut_suggestions.runner --mode cached
    python -m evals.cut_suggestions.runner --mode live --model gpt-4o
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass, field

from cut_suggester.cache import CachingLLMClient
from cut_suggester.config import (
    DEFAULT_SAMPLE_RATE,
    PRODUCT_SPEC_VERSION,
    PROMPT_VERSION,
    STAGE1_STEP,
    STAGE1_WINDOW,
    window_params,
)
from cut_suggester.cutter import suggest_cuts
from cut_suggester.llm import live_client_for
from cut_suggester.models import DEFAULT_SPECS, ProductType
from cut_suggester.transcript import load_transcript

from .aligner import LLMAligner
from .metrics import (
    candidates_per_hour,
    duration_window_compliance,
    fragment_rate,
    overlap_burden,
    semantic_recall,
)

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DATASET = os.path.join(_HERE, "datasets", "joe_miller")
DEFAULT_CACHE_DIR = os.path.join(_HERE, "cache")

# The eval defaults to the model the committed cache/baseline were produced with,
# so `--mode cached` reproduces offline with no `--model` flag. This is distinct
# from cut_suggester.config.DEFAULT_MODEL (claude-sonnet-5), the production
# default; the eval baseline is pinned to whatever key was present (gpt-4o).
EVAL_DEFAULT_MODEL = "gpt-4o"

_LABEL_KEY = {ProductType.SPOTLIGHT: "spotlights", ProductType.INTRO: "intros"}


@dataclass
class EvalReport:
    dataset: str
    mode: str
    model: str
    prompt_version: str
    product_spec_version: str
    per_product: dict
    candidates: list[dict]
    meta: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        return {
            "dataset": self.dataset,
            "mode": self.mode,
            "model": self.model,
            "prompt_version": self.prompt_version,
            "product_spec_version": self.product_spec_version,
            "per_product": self.per_product,
            "meta": self.meta,
            "candidates": self.candidates,
        }


def build_llm(mode: str, cache_dir: str, model: str, wparams: dict | None = None) -> CachingLLMClient:
    inner = live_client_for(model) if mode == "live" else None
    return CachingLLMClient(
        cache_dir,
        inner=inner,
        model=model,
        prompt_version=PROMPT_VERSION,
        product_spec_version=PRODUCT_SPEC_VERSION,
        window_params=wparams or window_params(),
    )


def run_eval(
    dataset_dir: str = DEFAULT_DATASET,
    *,
    mode: str = "cached",
    model: str = EVAL_DEFAULT_MODEL,
    llm=None,
    aligner=None,
    cache_dir: str = DEFAULT_CACHE_DIR,
    specs=None,
    sample_rate: int = DEFAULT_SAMPLE_RATE,
    window: int = STAGE1_WINDOW,
    step: int = STAGE1_STEP,
) -> EvalReport:
    specs = specs or DEFAULT_SPECS
    with open(os.path.join(dataset_dir, "labels.json")) as f:
        labels = json.load(f)
    transcript_path = os.path.join(dataset_dir, labels.get("transcript", "transcript.json"))
    sentences = load_transcript(transcript_path, sample_rate=sample_rate)

    llm = llm or build_llm(mode, cache_dir, model, {"window": window, "step": step})
    aligner = aligner or LLMAligner(llm)

    result = suggest_cuts(sentences, llm, specs=specs, sample_rate=sample_rate, window=window, step=step)
    total_seconds = sentences[-1].end_sec if sentences else 0.0

    per_product = {}
    for ptype in (ProductType.SPOTLIGHT, ProductType.INTRO):
        cands = [c for c in result.candidates if c.product_type is ptype]
        shipped = labels.get(_LABEL_KEY[ptype], [])
        # Intros are scored by the named song (shipped intro labels ARE song
        # names); the free-text label is a topic description, not the song, so it
        # would spuriously miss. Spotlights stay on the topic label.
        if ptype is ProductType.INTRO:
            proposed = [(c.song or c.label) for c in cands]
        else:
            proposed = [c.label for c in cands]
        recall = semantic_recall(proposed, shipped, aligner) if shipped else None
        per_product[ptype.value] = {
            "n_candidates": len(cands),
            "recall": recall,
            "duration_window_compliance": round(
                duration_window_compliance(cands, {ptype: specs[ptype]}), 3
            ),
            "fragment_rate": round(fragment_rate(cands), 3),
            "overlap_burden": overlap_burden(cands),
            "candidates_per_hour": round(candidates_per_hour(cands, total_seconds), 2),
        }

    return EvalReport(
        dataset=os.path.basename(dataset_dir.rstrip("/")),
        mode=mode,
        model=model,
        prompt_version=PROMPT_VERSION,
        product_spec_version=PRODUCT_SPEC_VERSION,
        per_product=per_product,
        candidates=[c.to_dict() for c in result.candidates],
        meta={**result.meta, "total_seconds": round(total_seconds, 1)},
    )


def format_report(report: EvalReport) -> str:
    lines = [
        f"Dataset: {report.dataset}   mode={report.mode}   model={report.model}",
        (
            f"prompt={report.prompt_version}  product_spec={report.product_spec_version}  "
            f"({report.meta.get('n_partitions')} paragraphs, {report.meta.get('n_raw_clips')} raw clips, "
            f"{report.meta.get('n_dropped_duration')} dropped, {report.meta.get('n_invalid_clips')} invalid)"
        ),
    ]
    for ptype, m in report.per_product.items():
        lines.append(f"\n[{ptype}]  {m['n_candidates']} candidates")
        if m["recall"] is not None:
            r = m["recall"]
            lines.append(f"  recall@K: {r['matched']}/{r['shipped']} = {r['recall']:.2f}")
            if r["missed"]:
                lines.append(f"  missed:   {r['missed']}")
        lines.append(f"  duration-window compliance: {m['duration_window_compliance']:.2f}")
        lines.append(f"  fragment rate (<15s):       {m['fragment_rate']:.2f}")
        lines.append(f"  overlap burden (pairs):     {m['overlap_burden']}")
        lines.append(f"  candidates / interview-hour: {m['candidates_per_hour']:.1f}")
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Cut-suggestion eval")
    ap.add_argument("--mode", choices=["cached", "live"], default="cached")
    ap.add_argument("--model", default=EVAL_DEFAULT_MODEL)
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--cache-dir", default=DEFAULT_CACHE_DIR)
    ap.add_argument("--json", action="store_true", help="print the full report as JSON")
    ap.add_argument("--write-baseline", metavar="PATH", help="write the report JSON to PATH")
    args = ap.parse_args(argv)

    report = run_eval(args.dataset, mode=args.mode, model=args.model, cache_dir=args.cache_dir)
    if args.json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        print(format_report(report))
    if args.write_baseline:
        with open(args.write_baseline, "w") as f:
            json.dump(report.to_dict(), f, indent=2)
        print(f"\nwrote baseline -> {args.write_baseline}")


if __name__ == "__main__":
    main()
