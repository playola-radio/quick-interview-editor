#!/usr/bin/env bash
# Spike success criterion: prove the FROZEN engine transcribes a real clip with
# NO dev environment (no .venv, no QIE_ENGINE_REPO) and NO network, loading
# pre-downloaded models from disk as data.
#
#   packaging/verify-offline.sh /path/to/sample.(wav|m4a|aiff)
#
# It stages the model files (from wherever they're cached on this machine) into
# the exact layout the app builds in Application Support, then runs the engine
# under `env -i` with a fake HOME + offline flags — the cheapest way to simulate
# a clean Mac without a second machine (per Codex's clean-env check).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${ENGINE:-$REPO_ROOT/packaging/dist/logic-markers-engine/logic-markers-engine}"
SAMPLE="${1:?usage: verify-offline.sh /path/to/sample.(wav|m4a|aiff)}"

[ -x "$ENGINE" ] || { echo "error: no frozen engine at $ENGINE (run package-engine.sh)" >&2; exit 1; }
[ -r "$SAMPLE" ] || { echo "error: sample not readable: $SAMPLE" >&2; exit 1; }

STAGE="$(mktemp -d)/qie-offline"
mkdir -p "$STAGE"/models/faster-whisper-large-v2 "$STAGE"/models/align \
         "$STAGE"/work "$STAGE"/home
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "==> Staging models as data into the app's Application Support layout"
WHISP_SNAP=$(ls -d ~/.cache/huggingface/hub/models--Systran--faster-whisper-large-v2/snapshots/*/ 2>/dev/null | head -1)
[ -n "$WHISP_SNAP" ] || { echo "error: faster-whisper-large-v2 not cached; run the engine once online first" >&2; exit 1; }
# cp -c = APFS copy-on-write clone (instant even for the 3 GB model.bin).
cp -c "$WHISP_SNAP"config.json "$WHISP_SNAP"model.bin \
      "$WHISP_SNAP"tokenizer.json "$WHISP_SNAP"vocabulary.txt \
      "$STAGE/models/faster-whisper-large-v2/"
ALIGN=~/.cache/torch/hub/checkpoints/wav2vec2_fairseq_base_ls960_asr_ls960.pth
[ -r "$ALIGN" ] || { echo "error: align model not cached at $ALIGN; run the engine once online first" >&2; exit 1; }
cp -c "$ALIGN" "$STAGE/models/align/"

echo "==> Running frozen 'plan' with a SCRUBBED, OFFLINE environment (env -i)"
set +e
env -i \
  HOME="$STAGE/home" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="$STAGE" \
  QIE_WHISPER_MODEL_DIR="$STAGE/models/faster-whisper-large-v2" \
  QIE_ALIGN_MODEL_DIR="$STAGE/models/align" \
  QIE_OFFLINE=1 \
  "$ENGINE" plan "$SAMPLE" --work-dir "$STAGE/work" --sample-rate 44100 \
  > "$STAGE/plan.json" 2> "$STAGE/plan.stderr"
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "FAILED (exit $rc). stderr tail:" >&2
  tail -40 "$STAGE/plan.stderr" >&2
  exit 1
fi

/usr/bin/python3 - "$STAGE/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
words = plan.get("words") or plan.get("transcript", {}).get("words", [])
assert words, "edit-plan has no words"
print(f"OK: frozen engine produced a valid edit-plan with {len(words)} words —")
print("    no .venv, no QIE_ENGINE_REPO, no network, fake HOME. Spike criterion met.")
PY
