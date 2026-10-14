#!/usr/bin/env bash
# Fail if any Mach-O under a directory needs a newer macOS than the app supports.
#
#   packaging/check-macos-compat.sh packaging/dist/logic-markers-engine
#
# A Homebrew Python is built for the build machine's macOS, so freezing with it
# ships stdlib extensions that crash on older Macs at import time (e.g. pyexpat:
# "Symbol not found: _XML_SetAllocTrackerActivationThreshold" on macOS 15 when
# built on 26). The target defaults to the app's deploymentTarget in project.yml.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:?usage: check-macos-compat.sh <dir>}"
TARGET="${MACOS_DEPLOYMENT_TARGET:-$(awk -F'"' '/^ *macOS:/{print $2; exit}' "$REPO_ROOT/QuickInterviewEditor/project.yml")}"

if [[ -z "$TARGET" ]]; then
  echo "error: could not read the macOS deploymentTarget from project.yml" >&2
  exit 1
fi

newer_than_target() {
  awk -v a="$1" -v b="$TARGET" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 != y[i] + 0) exit !(x[i] + 0 > y[i] + 0) }
    exit 1
  }'
}

echo "==> Checking every Mach-O in $DIR runs on macOS $TARGET"
# Collect the list up front (not via process substitution) so a failure anywhere in
# the pipeline aborts under pipefail instead of silently checking a truncated list.
# LC_ALL=C: `file` descriptions of bundled fonts etc. aren't valid UTF-8.
MACHOS="$(mktemp)"
trap 'rm -f "$MACHOS"' EXIT
find "$DIR" -type f -print0 | LC_ALL=C xargs -0 file --no-pad -F $'\t' \
  | LC_ALL=C awk -F'\t' '$2 ~ /Mach-O/ {print $1}' >"$MACHOS"

checked=0
offenders=0
while IFS= read -r f; do
  # LC_BUILD_VERSION reports "minos X"; older binaries use LC_VERSION_MIN_MACOSX ("version X").
  minos="$(vtool -show-build "$f" | awk '
    $1 == "cmd" { cmd = $2 }
    $1 == "minos" || ($1 == "version" && cmd == "LC_VERSION_MIN_MACOSX") { print $2 }
  ' | sort -t. -k1,1n -k2,2n | tail -1)"
  checked=$((checked + 1))
  if [[ -z "$minos" ]]; then
    echo "    no minimum macOS recorded: ${f#"$DIR"/}" >&2
    offenders=$((offenders + 1))
  elif newer_than_target "$minos"; then
    echo "    needs macOS $minos: ${f#"$DIR"/}" >&2
    offenders=$((offenders + 1))
  fi
done <"$MACHOS"

if ((checked == 0)); then
  echo "error: found no Mach-O binaries under $DIR" >&2
  exit 1
fi
if ((offenders > 0)); then
  echo "error: $offenders of $checked binaries may not run on macOS $TARGET. Freeze with a" >&2
  echo "       python-build-standalone venv (packaging/make-build-venv.sh), never Homebrew Python." >&2
  exit 1
fi
echo "    OK ($checked binaries)"
