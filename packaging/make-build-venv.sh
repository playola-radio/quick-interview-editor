#!/usr/bin/env bash
# Create the venv the release freezes run from, on a python-build-standalone CPython.
#
#   packaging/make-build-venv.sh                 # → $REPO_ROOT/.venv
#   VENV=/path/to/.venv packaging/make-build-venv.sh
#
# The release lane runs this before freezing; it refuses a venv on any other Python
# and re-pins packages to build-constraints.txt. See packaging/README.md for why
# Homebrew Python can't be used.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${VENV:-$REPO_ROOT/.venv}"

source "$REPO_ROOT/packaging/build-python.sh"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ASSET//+/%2B}"

if [[ ! -x "$PBS_PY" ]]; then
  echo "==> Downloading python-build-standalone CPython $PBS_VERSION ($PBS_RELEASE)"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL "$PBS_URL" -o "$TMP/python.tar.gz"
  echo "$PBS_SHA256  $TMP/python.tar.gz" | shasum -a 256 -c -
  mkdir -p "$TMP/x"
  tar -xzf "$TMP/python.tar.gz" -C "$TMP/x"
  mkdir -p "$(dirname "$PBS_DIR")"
  mv "$TMP/x/python" "$PBS_DIR"
fi

if [[ -x "$VENV/bin/python" ]]; then
  validate_build_python "$VENV/bin/python" "$VENV"
else
  echo "==> Creating $VENV"
  "$PBS_PY" -m venv "$VENV"
fi

echo "==> Installing engine + cut-suggester deps and PyInstaller"
"$VENV/bin/python" -m pip install "pip==25.3"
"$VENV/bin/python" -m pip install -r "$REPO_ROOT/requirements.txt" \
  -c "$REPO_ROOT/packaging/build-constraints.txt" pyinstaller pyinstaller-hooks-contrib

echo "==> Ready: VENV=$VENV"
