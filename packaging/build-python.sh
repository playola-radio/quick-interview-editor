#!/usr/bin/env bash
# Shared release-Python identity and validation for the venv builder and packagers.

PBS_RELEASE="20261013"
PBS_VERSION="3.12.15"
PBS_SHA256="ba32036ad8f4c434d97a1ee7feef8b7edc0fac16777639b97e39c74a108e4440"
PBS_ASSET="cpython-${PBS_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PBS_DIR="$REPO_ROOT/packaging/python/${PBS_VERSION}+${PBS_RELEASE}"
PBS_PY="$PBS_DIR/bin/python3.12"

validate_build_python() {
  local python="$1"
  local venv="$2"
  local base
  base="$("$python" -c 'import sys; print(sys.base_prefix)')"
  if [[ "$base" != "$PBS_DIR" ]]; then
    echo "error: $venv is based on a different Python ($base)." >&2
    echo "       Create it with packaging/make-build-venv.sh." >&2
    exit 1
  fi
}
