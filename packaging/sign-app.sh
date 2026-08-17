#!/usr/bin/env bash
# Deep, inside-out code-signing of the app + bundled engine helper for
# Developer ID distribution with the hardened runtime.
#
#   packaging/sign-app.sh /path/to/QuickInterviewEditor.app
#
# Signs every nested Mach-O (torch/ctranslate2/torchaudio .so/.dylib) FIRST,
# then the engine executable, then embedded frameworks, then the app itself.
# `--deep` is used only for VERIFICATION at the end, never for construction
# (Apple discourages `--deep` signing because it applies one identity/entitlement
# set indiscriminately and silently skips already-signed code).
#
# Override the identity with SIGN_IDENTITY=... (defaults to Playola Developer ID).
set -euo pipefail

APP="${1:?usage: sign-app.sh /path/to/QuickInterviewEditor.app}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)}"
ENGINE_ENTITLEMENTS="$HERE/engine.entitlements"
APP_ENTITLEMENTS="$HERE/app.entitlements"
ENGINE_DIR="$APP/Contents/Resources/engine"

if ! security find-identity -v -p codesigning | grep -q "$(echo "$IDENTITY" | sed 's/.*(\(.*\))/\1/')"; then
  echo "error: signing identity not found in keychain: $IDENTITY" >&2
  exit 1
fi

sign_runtime() { # <entitlements> <path>
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --entitlements "$1" "$2"
}

echo "==> Signing nested Mach-O under $ENGINE_DIR (inside-out)"
# List every Mach-O, deepest-first (sort -r), and sign each individually. `file`
# on each path is the reliable Mach-O test (extensions alone miss extensionless
# binaries and Python framework stubs). Both frozen helper executables
# (logic-markers-engine, cut-suggester-engine) live in this tree; exclude them here
# and sign each explicitly LAST so the inside-out order (nested libs before the
# executable that dlopen's them) holds for both.
count=0
while IFS= read -r macho; do
  [ -z "$macho" ] && continue
  sign_runtime "$ENGINE_ENTITLEMENTS" "$macho"
  count=$((count + 1))
done < <(find "$ENGINE_DIR" -type f -print0 \
           | xargs -0 file 2>/dev/null \
           | grep 'Mach-O' \
           | cut -d: -f1 \
           | grep -vE "/(logic-markers-engine|cut-suggester-engine)$" \
           | sort -r)
echo "    signed $count nested Mach-O binaries"

echo "==> Signing engine + cut-suggester executables"
sign_runtime "$ENGINE_ENTITLEMENTS" "$ENGINE_DIR/logic-markers-engine"
sign_runtime "$ENGINE_ENTITLEMENTS" "$ENGINE_DIR/cut-suggester-engine"

# Sparkle 2.x embeds nested code bundles (an Autoupdate executable, a nested
# Updater.app, and two XPC services) inside Sparkle.framework. A flat codesign of
# the framework leaves those ad-hoc/unsigned, which fails notarization + Gatekeeper
# and breaks Sparkle's own installer launch. Sign them inside-out (deepest first)
# BEFORE the framework loop signs Sparkle.framework itself. No entitlements: Sparkle
# isn't sandboxed here. Versions/B is the current Sparkle layout (2.9.6); re-verify
# the version dir if Sparkle is bumped.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  echo "==> Signing Sparkle nested helpers (inside-out)"
  # --preserve-metadata=entitlements keeps whatever entitlements Sparkle ships on its
  # XPC services (empty in 2.9.6 for a non-sandboxed host, but Sparkle's sandboxed XPC
  # services carry sandbox entitlements — preserving is Sparkle's documented guidance
  # and future-proofs a version bump). https://sparkle-project.github.io/documentation/sandboxing/
  for xpc in "$SPARKLE/Versions/B/XPCServices/"*.xpc; do
    [ -e "$xpc" ] && codesign --force --sign "$IDENTITY" --options runtime --timestamp \
      --preserve-metadata=entitlements "$xpc"
  done
  [ -d "$SPARKLE/Versions/B/Updater.app" ] && \
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE/Versions/B/Updater.app"
  [ -f "$SPARKLE/Versions/B/Autoupdate" ] && \
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE/Versions/B/Autoupdate"
fi

if [ -d "$APP/Contents/Frameworks" ]; then
  echo "==> Signing embedded frameworks/dylibs"
  while IFS= read -r fw; do
    [ -z "$fw" ] && continue
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$fw"
  done < <(find "$APP/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) | sort -r)
fi

echo "==> Signing the app (outermost)"
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements "$APP_ENTITLEMENTS" "$APP"

echo "==> Guard: every Mach-O must be signed with Team FSRSPV9N9Q"
# Belt-and-suspenders: catch any Mach-O (nested Sparkle helper, engine lib, etc.)
# that slipped through unsigned or with the wrong team before we notarize.
# `file` prints an extra line per slice for universal binaries — e.g.
# "…/Autoupdate (for architecture arm64): …" — whose cut(1) prefix is a pseudo-path
# that doesn't exist. Drop those with `sort -u` + a real-file test so fat binaries
# (Sparkle ships x86_64+arm64) don't produce false "unsigned" hits that abort a
# correctly-signed release.
unsigned=0
while IFS= read -r macho; do
  [ -z "$macho" ] && continue
  [ -f "$macho" ] || continue
  if ! codesign -dvvv "$macho" 2>&1 | grep -q "TeamIdentifier=FSRSPV9N9Q"; then
    echo "   UNSIGNED/wrong-team: $macho" >&2
    unsigned=$((unsigned + 1))
  fi
done < <(find "$APP" -type f -print0 | xargs -0 file 2>/dev/null \
           | grep 'Mach-O' | cut -d: -f1 | sort -u)
[ "$unsigned" -eq 0 ] || { echo "error: $unsigned Mach-O binaries not properly signed" >&2; exit 1; }
echo "    all Mach-O binaries signed with our Team ID"

echo "==> Verify (codesign --verify --strict --deep)"
codesign --verify --strict --deep --verbose=4 "$APP"
echo "==> App signature summary"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|Identifier=|Runtime" || true
echo "==> Engine signature summary"
codesign -dvvv "$ENGINE_DIR/logic-markers-engine" 2>&1 \
  | grep -E "Authority=|TeamIdentifier=|Runtime|Entitlement" || true
echo "==> Cut-suggester signature summary"
codesign -dvvv "$ENGINE_DIR/cut-suggester-engine" 2>&1 \
  | grep -E "Authority=|TeamIdentifier=|Runtime|Entitlement" || true
echo
echo "Signed OK. Next: packaging/notarize-app.sh \"$APP\""
