#!/usr/bin/env bash
# Freeze the logic-markers engine into a PyInstaller one-folder bundle.
#
#   packaging/dist/logic-markers-engine/logic-markers-engine   (executable)
#   packaging/dist/logic-markers-engine/_internal/...          (native libs + data)
#
# The app bundles that folder at Contents/Resources/engine/. This is a slow,
# multi-GB build, so it is a deliberate, separate step — NOT an xcodebuild phase.
#
# Requirements: a venv with the engine deps + PyInstaller. Override with
#   VENV=/path/to/.venv packaging/package-engine.sh
#
# Apple Silicon only for the spike.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VENV="${VENV:-$HOME/playola/logic-utils/.venv}"
PY="$VENV/bin/python"

if [[ ! -x "$PY" ]]; then
  echo "error: no python at $PY (set VENV=/path/to/.venv)" >&2
  exit 1
fi
if ! "$PY" -c "import PyInstaller" 2>/dev/null; then
  echo "error: PyInstaller not installed in $VENV. Run: $PY -m pip install pyinstaller" >&2
  exit 1
fi

echo "==> Staging bundled NLTK punkt_tab (kills WhisperX's runtime nltk.download)"
NLTK_DIR="$REPO_ROOT/packaging/build/nltk_data"
mkdir -p "$NLTK_DIR"
if [[ ! -d "$NLTK_DIR/tokenizers/punkt_tab" ]]; then
  "$PY" -c "import nltk; nltk.download('punkt_tab', download_dir='$NLTK_DIR', quiet=True)"
fi

echo "==> Running PyInstaller (one-folder, arm64) — this takes a while"
"$PY" -m PyInstaller \
  --clean --noconfirm \
  --distpath "$REPO_ROOT/packaging/dist" \
  --workpath "$REPO_ROOT/packaging/build/pyi" \
  "$REPO_ROOT/packaging/engine.spec"

ENGINE="$REPO_ROOT/packaging/dist/logic-markers-engine/logic-markers-engine"
if [[ ! -x "$ENGINE" ]]; then
  echo "error: expected engine binary missing at $ENGINE" >&2
  exit 1
fi

echo "==> Built: $ENGINE"
du -sh "$REPO_ROOT/packaging/dist/logic-markers-engine" | awk '{print "    bundle size: " $1}'
echo "==> Smoke test: engine responds to --help"
"$ENGINE" --help >/dev/null && echo "    OK (--help)"
echo
echo "Next: sign with packaging/sign-app.sh, then verify offline with"
echo "packaging/verify-offline.sh."
