#!/usr/bin/env bash
# Prove the FROZEN cut-suggester helper runs a REAL two-stage `suggest` with NO dev
# environment (no .venv, no QIE_ENGINE_REPO, no PYTHONPATH) — the cutter analog of
# verify-offline.sh.
#
#   packaging/verify-cut-suggester.sh
#   MODEL=claude-sonnet-5 packaging/verify-cut-suggester.sh
#
# Unlike the whisperx engine, the cutter's work IS a network LLM call, so this can't
# run offline: it forwards exactly one credential (OPENAI_KEY / ANTHROPIC_API_KEY,
# whichever the model needs) into an otherwise-scrubbed `env -i` shell. Everything
# else (Python runtime, anthropic SDK, certifi CA bundle) must come from inside the
# frozen bundle — that's the point of the check.
#
# Default model is a cheap OpenAI model so an OPENAI_KEY smoke-tests the stdlib-urllib
# path end to end; set MODEL=claude-... (with ANTHROPIC_API_KEY) to exercise the
# bundled anthropic SDK against the live API.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${HELPER:-$REPO_ROOT/packaging/dist/cut-suggester-engine/cut-suggester-engine}"
MODEL="${MODEL:-gpt-4o-mini}"

[ -x "$HELPER" ] || {
  echo "error: no frozen cut-suggester at $HELPER (run package-cut-suggester.sh)" >&2
  exit 1
}

# Forward only the credential the chosen provider needs.
case "$MODEL" in
  gpt-*|o1*|o3*|o4*)
    # Forward exactly one credential (OPENAI_KEY is the cutter's primary; OPENAI_API_KEY
    # is its fallback) so the scrubbed child gets no more than it needs.
    if [ -n "${OPENAI_KEY:-}" ]; then
      KEY_ENV=(OPENAI_KEY="$OPENAI_KEY")
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
      KEY_ENV=(OPENAI_API_KEY="$OPENAI_API_KEY")
    else
      echo "error: model '$MODEL' needs OPENAI_KEY (or OPENAI_API_KEY) in the env" >&2
      exit 1
    fi ;;
  *)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || {
      echo "error: model '$MODEL' needs ANTHROPIC_API_KEY in the env" >&2
      exit 1
    }
    KEY_ENV=(ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}") ;;
esac

STAGE="$(mktemp -d)/qie-cut-verify"
mkdir -p "$STAGE/home"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT

echo "==> Building a request (model=$MODEL)"
/usr/bin/python3 - "$STAGE/request.json" "$MODEL" <<'PY'
import json, sys
lines = [
    "Welcome back to the show, today we are talking about how a small town radio",
    "station reinvented itself for the streaming era.",
    "Our guest started in the business sweeping floors at the AM station downtown.",
    "By the time he was twenty he was running the overnight shift solo.",
    "He tells the story of the night the transmitter failed during a blizzard.",
    "The whole county lost the signal and the phones lit up immediately.",
    "He drove two hours through the snow to reset the backup transmitter by hand.",
    "That moment, he says, is when he understood what the station meant to people.",
    "Later we get into the economics of running independent radio in a small market.",
    "Advertising dollars moved to the internet and the old model stopped working.",
    "So he built a membership program modeled on public television pledge drives.",
    "Listeners could support the station directly and get behind the scenes access.",
    "The first drive raised almost nothing and he nearly gave up on the whole idea.",
    "But a local diner owner cut a check that covered a month of operating costs.",
    "Word spread, and within a year membership became the biggest line of revenue.",
    "We close the conversation with his advice for the next generation of broadcasters.",
    "Learn the community first, he says, and let the programming follow from that.",
    "Do not chase the trends, chase the trust, because trust is what keeps a station alive.",
]
units = []
wid = 1
for i, text in enumerate(lines):
    start, end = i * 6.0, (i + 1) * 6.0
    units.append({
        "id": i, "text": text, "word_ids": [wid, wid + 1],
        "start_sec": start, "end_sec": end,
        "start_sample": round(start * 44100), "end_sample": round(end * 44100),
        "speaker_id": None,
    })
    wid += 2
json.dump({
    "transcript_units": units,
    "product_specs": None,
    "options": {"model": sys.argv[2], "sample_rate": 44100},
    "diarization": None,
}, open(sys.argv[1], "w"))
PY

echo "==> Running frozen 'suggest' with a SCRUBBED env (env -i + one credential)"
set +e
env -i \
  HOME="$STAGE/home" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="$STAGE" \
  "${KEY_ENV[@]}" \
  "$HELPER" suggest --request "$STAGE/request.json" \
  > "$STAGE/out.json" 2> "$STAGE/err.txt"
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "FAILED (exit $rc). stderr tail:" >&2
  tail -40 "$STAGE/err.txt" >&2
  exit 1
fi

/usr/bin/python3 - "$STAGE/out.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert isinstance(result, dict), "result is not a JSON object"
assert "suggestions" in result, "result has no 'suggestions' key"
assert isinstance(result["suggestions"], list), "'suggestions' is not a list"
meta = result.get("meta", {})
print(f"OK: frozen cut-suggester produced valid JSON — "
      f"{len(result['suggestions'])} suggestion(s), "
      f"{meta.get('n_sentences', '?')} sentences, "
      f"{meta.get('n_partitions', '?')} partitions.")
print("    No .venv, no QIE_ENGINE_REPO, no PYTHONPATH — the frozen bundle is self-contained.")
PY
