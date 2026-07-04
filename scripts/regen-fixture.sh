#!/usr/bin/env bash
#
# Regenerate the bundled edit-plan.json fixture from the canonical source clip.
#
# The app + tests load QuickInterviewEditor/Resources/Fixtures/edit-plan.json
# (committed). The source audio is NOT committed (licensing + size); it lives in
# one durable, gitignored location and is referenced here. Run this only when the
# clip or the engine's analysis params change.
#
# Usage:
#   scripts/regen-fixture.sh [path-to-audio]
#   QIE_FIXTURE_AUDIO=/path/to/clip.m4a scripts/regen-fixture.sh
#
# Requires a Python engine env (.venv) in the current workspace:
#   /opt/homebrew/bin/python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt
#
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIO="${1:-${QIE_FIXTURE_AUDIO:-$HOME/playola/logic-utils/.context/audio/hayes-carll-intro.m4a}}"
FIXTURE_DIR="$REPO_ROOT/QuickInterviewEditor/Resources/Fixtures"
PY="$REPO_ROOT/.venv/bin/python"

[ -f "$AUDIO" ] || { echo "error: audio not found: $AUDIO" >&2; exit 1; }
[ -x "$PY" ] || {
  echo "error: no .venv in this workspace." >&2
  echo "  /opt/homebrew/bin/python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt" >&2
  exit 1
}

echo "==> transcript (WhisperX; cached next to the clip after first run)"
"$PY" -m logic_markers.cli transcript "$AUDIO"

TXT="${AUDIO%.*}.txt"
echo "==> cut -> edit-plan.json"
"$PY" -m logic_markers.cli cut "$AUDIO" "$TXT"
PLAN="$AUDIO.edit-plan.json"

mkdir -p "$FIXTURE_DIR"
echo "==> install fixture (normalizing source.path)"
"$PY" - "$PLAN" "$FIXTURE_DIR/edit-plan.json" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
plan = json.load(open(src))
plan["source"]["path"] = "fixtures/hayes-carll-intro.m4a"  # stable, non-machine-specific
json.dump(plan, open(dst, "w"), indent=2)
print(f"    wrote {dst} ({len(plan['words'])} words, {len(plan['silences'])} silences)")
PYEOF

# tidy engine byproducts in the (gitignored) source folder; keep the transcript cache
rm -f "${AUDIO%.*}".*.aiff "${AUDIO%.*}".markers.aiff 2>/dev/null || true
echo "==> done: $FIXTURE_DIR/edit-plan.json"
