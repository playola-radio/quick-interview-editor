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

PBS_RELEASE="20261013"
PBS_VERSION="3.12.15"
PBS_SHA256="ba32036ad8f4c434d97a1ee7feef8b7edc0fac16777639b97e39c74a108e4440"
PBS_ASSET="cpython-${PBS_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ASSET//+/%2B}"
PBS_DIR="$REPO_ROOT/packaging/python/${PBS_VERSION}+${PBS_RELEASE}"
PBS_PY="$PBS_DIR/bin/python3.12"

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
  base="$("$VENV/bin/python" -c 'import sys; print(sys.base_prefix)')"
  if [[ "$base" != "$PBS_DIR" ]]; then
    echo "error: $VENV already exists on a different Python ($base)." >&2
    echo "       Remove it, or pick another location with VENV=/path/to/.venv." >&2
    exit 1
  fi
else
  echo "==> Creating $VENV"
  "$PBS_PY" -m venv "$VENV"
fi

echo "==> Installing engine + cut-suggester deps and PyInstaller"
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/python" -m pip install -r "$REPO_ROOT/requirements.txt" \
  -c "$REPO_ROOT/packaging/build-constraints.txt" pyinstaller pyinstaller-hooks-contrib

echo "==> Ready: VENV=$VENV"
