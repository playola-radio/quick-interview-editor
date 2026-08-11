#!/usr/bin/env bash
# Freeze the cut-suggester helper into a PyInstaller one-folder bundle.
#
#   packaging/dist/cut-suggester-engine/cut-suggester-engine        (executable)
#   packaging/dist/cut-suggester-engine/_cut_suggester_internal/... (anthropic stack)
#
# The app bundles that folder INTO Contents/Resources/engine/ alongside the frozen
# logic-markers-engine (see build-app.sh). The distinct contents dir
# (_cut_suggester_internal) keeps the two bundles from colliding on _internal/.
#
# This is a SMALL, fast build compared to package-engine.sh: the cutter's whole
# runtime is CPython stdlib + the anthropic SDK (lazy-imported). No torch/whisperx.
#
# Requirements: a venv with `anthropic` + PyInstaller. Override with
#   VENV=/path/to/.venv packaging/package-cut-suggester.sh
#
# Apple Silicon only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Defaults to a repo-local .venv; override for any other environment with
# VENV=/path/to/.venv (a venv with `anthropic` + PyInstaller).
VENV="${VENV:-$REPO_ROOT/.venv}"
PY="$VENV/bin/python"

if [[ ! -x "$PY" ]]; then
  echo "error: no python at $PY. Set VENV=/path/to/.venv (a venv with anthropic +" >&2
  echo "       PyInstaller), e.g. VENV=~/playola/logic-utils/.venv" >&2
  exit 1
fi
if ! "$PY" -c "import PyInstaller" 2>/dev/null; then
  echo "error: PyInstaller not installed in $VENV. Run: $PY -m pip install pyinstaller" >&2
  exit 1
fi
# contents_directory (the _internal-collision guard the two-bundle merge depends on)
# is a PyInstaller 6+ feature. Fail loud on an older PyInstaller rather than silently
# emitting an `_internal` tree that later clobbers the engine bundle at merge time.
if ! "$PY" -c "import PyInstaller,sys; sys.exit(0 if int(PyInstaller.__version__.split('.')[0])>=6 else 1)" 2>/dev/null; then
  echo "error: PyInstaller >= 6 required (contents_directory support). In $VENV run:" >&2
  echo "       $PY -m pip install -U 'pyinstaller>=6'" >&2
  exit 1
fi
if ! "$PY" -c "import anthropic" 2>/dev/null; then
  echo "error: anthropic not installed in $VENV. Run: $PY -m pip install anthropic" >&2
  exit 1
fi

echo "==> Running PyInstaller (one-folder, arm64) for cut-suggester-engine"
"$PY" -m PyInstaller \
  --clean --noconfirm \
  --distpath "$REPO_ROOT/packaging/dist" \
  --workpath "$REPO_ROOT/packaging/build/pyi-cut-suggester" \
  "$REPO_ROOT/packaging/cut-suggester.spec"

HELPER="$REPO_ROOT/packaging/dist/cut-suggester-engine/cut-suggester-engine"
if [[ ! -x "$HELPER" ]]; then
  echo "error: expected cut-suggester binary missing at $HELPER" >&2
  exit 1
fi

echo "==> Built: $HELPER"
du -sh "$REPO_ROOT/packaging/dist/cut-suggester-engine" | awk '{print "    bundle size: " $1}'

# The whole two-bundle merge (build-app.sh) depends on this bundle's ONLY top-level
# entries being the executable + its distinct contents dir. If a PyInstaller change
# ever emits `_internal` here it would clobber the engine bundle's `_internal` at
# merge time (before signing) — catch that now, loudly, not in a corrupted .app.
DIST_DIR="$REPO_ROOT/packaging/dist/cut-suggester-engine"
TOP="$(cd "$DIST_DIR" && ls -1A | sort | tr '\n' ' ')"
EXPECTED="_cut_suggester_internal cut-suggester-engine "
if [[ "$TOP" != "$EXPECTED" ]]; then
  echo "error: unexpected cut-suggester bundle layout. got: [$TOP]" >&2
  echo "       expected exactly: [$EXPECTED]" >&2
  echo "       (contents_directory must be _cut_suggester_internal; an _internal tree" >&2
  echo "        would collide with logic-markers-engine when merged into engine/)" >&2
  exit 1
fi

echo "==> Smoke test: helper responds to --help"
"$HELPER" --help >/dev/null && echo "    OK (--help)"

# The anthropic SDK is imported LAZILY (only when the Anthropic provider actually
# runs), so `--help` never touches it. Prove the SDK is frozen + importable by
# driving a real Anthropic-model `suggest` far enough to reach `import anthropic`
# and the client construction — with NO key, so it fails cleanly on auth rather
# than making a network call. If anthropic were missing we'd see
# "No module named 'anthropic'" instead.
echo "==> Smoke test: anthropic SDK imports inside the frozen bundle (no key needed)"
SMOKE_DIR="$(mktemp -d)"
trap 'rm -rf "$SMOKE_DIR"' EXIT
"$PY" - "$SMOKE_DIR/request.json" <<'PY'
import json, sys
units = [
    {
        "id": i, "text": f"sentence number {i} about something",
        "word_ids": [2 * i + 1, 2 * i + 2],
        "start_sec": i * 20.0, "end_sec": (i + 1) * 20.0,
        "start_sample": i * 20 * 44100, "end_sample": (i + 1) * 20 * 44100,
        "speaker_id": None,
    }
    for i in range(6)
]
req = {
    "transcript_units": units,
    "product_specs": None,
    "options": {"model": "claude-sonnet-5", "sample_rate": 44100},
    "diarization": None,
}
json.dump(req, open(sys.argv[1], "w"))
PY
set +e
SMOKE_ERR="$(env -u ANTHROPIC_API_KEY "$HELPER" suggest --request "$SMOKE_DIR/request.json" 2>&1 >/dev/null)"
set -e
if grep -qi "No module named" <<<"$SMOKE_ERR"; then
  echo "    FAILED: anthropic did not freeze into the bundle:" >&2
  echo "$SMOKE_ERR" | tail -5 >&2
  exit 1
fi
if grep -qiE "api_key|ANTHROPIC_API_KEY|authentic" <<<"$SMOKE_ERR"; then
  echo "    OK (anthropic imported; failed on missing key as expected)"
else
  echo "    WARNING: unexpected smoke stderr (anthropic import unconfirmed):" >&2
  echo "$SMOKE_ERR" | tail -5 >&2
fi

echo
echo "Next: build the app + embed both helpers with packaging/build-app.sh, then"
echo "sign with packaging/sign-app.sh. Run a REAL end-to-end suggest (needs an LLM"
echo "key in env) with packaging/verify-cut-suggester.sh."
