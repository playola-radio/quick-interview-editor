"""JSON-over-stdio entrypoint for the app's `CutSuggestClient` (live path).

Mirrors `logic_markers.cli` (the frozen engine): the Swift app writes a request
JSON, spawns `python -m cut_suggester.cli suggest --request r.json`, reads
`QIE_EVENT` progress from stderr and a single result JSON from stdout. This is the
one live driver of the validated two-stage cutter — the same code the eval runs, so
production and the regression eval never diverge.

Request shape (written by the app):

    {
      "transcript_units": [
        {"id", "text", "word_ids", "start_sample", "end_sample",
         "start_sec", "end_sec", "speaker_id"?}, ...
      ],
      "product_specs": [
        {"product_type", "target_min_sec", "target_max_sec",
         "hard_min_sec", "hard_max_sec", "description"}, ...
      ],
      "options": {"model", "prompt_version", "product_spec_version",
                  "stage1_window", "stage1_step", "sample_rate"},
      "diarization": {"diarization_hash": "..."} | null
    }

Result on stdout: `{"suggestions": [<CutCandidate.to_dict()>, ...], "meta": {...}}`.

Auth: the model/provider come from `options.model`; the API key is read from the
environment by the live client (`OPENAI_KEY` / the Anthropic SDK's own env). No key
is ever hardcoded or accepted on the command line.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from .cache import CacheMiss, CachingLLMClient
from .config import (
    DEFAULT_MODEL,
    DEFAULT_SAMPLE_RATE,
    PRODUCT_SPEC_VERSION,
    PROMPT_VERSION,
    STAGE1_STEP,
    STAGE1_WINDOW,
)
from .cutter import suggest_cuts
from .llm import LLMClient, live_client_for
from .models import DEFAULT_SPECS, ProductSpec, ProductType
from .transcript import sentences_from_units


def _emit_event(event: dict) -> None:
    """One machine event per stderr line; stdout stays pure JSON (mirrors the engine)."""
    print(f"QIE_EVENT {json.dumps(event)}", file=sys.stderr, flush=True)


def specs_from_request(product_specs: list[dict] | None) -> dict[ProductType, ProductSpec]:
    """Build the `{ProductType: ProductSpec}` map from the request.

    Falls back to the pinned defaults when the app sends nothing. An unknown
    product type fails loud rather than being silently ignored.
    """
    if not product_specs:
        return DEFAULT_SPECS
    out: dict[ProductType, ProductSpec] = {}
    for raw in product_specs:
        try:
            ptype = ProductType(str(raw["product_type"]))
            spec = ProductSpec(
                product_type=ptype,
                target_min_sec=float(raw["target_min_sec"]),
                target_max_sec=float(raw["target_max_sec"]),
                hard_min_sec=float(raw["hard_min_sec"]),
                hard_max_sec=float(raw["hard_max_sec"]),
                description=str(raw.get("description", "")),
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"invalid product spec {raw!r}: {exc}") from exc
        out[ptype] = spec
    return out


def _window_params(options: dict) -> dict:
    return {
        "window": int(options.get("stage1_window", STAGE1_WINDOW)),
        "step": int(options.get("stage1_step", STAGE1_STEP)),
    }


def build_llm(
    options: dict,
    *,
    cache_dir: str | None,
    cached_only: bool,
    refresh: bool,
) -> LLMClient:
    """Assemble the (optionally cached) live LLM client for this run.

    `cached_only` (tests/CI) uses `inner=None` so a miss raises rather than
    reaching the network. `refresh` recomputes and overwrites existing entries.
    The live client reads its API key from the environment — never a flag.
    """
    model = str(options.get("model") or DEFAULT_MODEL)
    inner = None if cached_only else live_client_for(model)
    if cache_dir is None:
        if inner is None:
            raise ValueError("--cached requires --cache-dir")
        return inner  # no caching requested; drive the live client directly
    return CachingLLMClient(
        cache_dir,
        inner=inner,
        model=model,
        prompt_version=str(options.get("prompt_version", PROMPT_VERSION)),
        product_spec_version=str(options.get("product_spec_version", PRODUCT_SPEC_VERSION)),
        window_params=_window_params(options),
        refresh=refresh,
    )


def run_suggest(request: dict, llm: LLMClient, *, emit=_emit_event) -> dict:
    """Run the two-stage cutter for a request dict and shape the result JSON.

    `llm` is injected (a live/cached client in the CLI, a fake in tests), so this
    is exercised with no network. `emit` receives progress dicts; the CLI forwards
    them to stderr as `QIE_EVENT` lines.
    """
    # Fail loud on a missing/empty transcript rather than returning an empty success:
    # the only reason the app calls this is to analyze a transcript, so no units means
    # an encoding/import regression, not "zero clips found". Reporting success with an
    # empty list would let the caller overwrite persisted suggestions with nothing.
    units = request.get("transcript_units")
    if not units:
        raise ValueError("request has no transcript_units to analyze")
    sentences = sentences_from_units(units)
    specs = specs_from_request(request.get("product_specs"))
    options = request.get("options") or {}
    wparams = _window_params(options)
    sample_rate = int(options.get("sample_rate", DEFAULT_SAMPLE_RATE))

    def progress(**event) -> None:
        emit({"type": "progress", **event})

    result = suggest_cuts(
        sentences,
        llm,
        specs=specs,
        sample_rate=sample_rate,
        window=wparams["window"],
        step=wparams["step"],
        progress=progress,
    )
    return {
        "suggestions": [c.to_dict() for c in result.candidates],
        "meta": result.meta,
    }


def _cmd_suggest(args) -> int:
    if not os.path.exists(args.request):
        print(f"error: no such request file: {args.request}", file=sys.stderr)
        return 2
    with open(args.request) as f:
        request = json.load(f)
    options = request.get("options") or {}
    llm = build_llm(
        options,
        cache_dir=args.cache_dir,
        cached_only=args.cached,
        refresh=args.refresh,
    )

    # stdout is a pure-JSON channel the app decodes wholesale. Redirect fd 1 to
    # stderr for the whole run (an SDK or dependency might print a warning to
    # stdout), then restore it and write only the result JSON — the same proven
    # discipline `logic_markers.cli` uses for `plan`/`render`.
    sys.stdout.flush()
    saved_stdout_fd = os.dup(1)
    try:
        os.dup2(2, 1)
        result = run_suggest(request, llm)
    finally:
        sys.stdout.flush()
        os.dup2(saved_stdout_fd, 1)
        os.close(saved_stdout_fd)
    json.dump(result, sys.stdout)
    sys.stdout.flush()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="cut-suggester",
        description="Suggest product-shaped cut candidates from an interview transcript.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("suggest", help="run the two-stage cutter; result JSON to stdout")
    s.add_argument("--request", required=True, help="request.json (transcript units + options)")
    s.add_argument(
        "--cache-dir",
        default=None,
        help="disk cache for LLM responses (temperature:0 is not deterministic)",
    )
    s.add_argument(
        "--cached",
        action="store_true",
        help="cache-only: never hit the network; a miss fails (tests/CI)",
    )
    s.add_argument(
        "--refresh",
        action="store_true",
        help="ignore existing cache entries; recompute and overwrite",
    )
    s.set_defaults(func=_cmd_suggest)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except CacheMiss as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # fail fast with a clear message
        if os.environ.get("QIE_DEBUG"):
            import traceback

            traceback.print_exc(file=sys.stderr)
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
