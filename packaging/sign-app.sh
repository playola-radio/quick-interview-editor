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
# binaries and Python framework stubs).
count=0
while IFS= read -r macho; do
  [ -z "$macho" ] && continue
  sign_runtime "$ENGINE_ENTITLEMENTS" "$macho"
  count=$((count + 1))
done < <(find "$ENGINE_DIR" -type f -print0 \
           | xargs -0 file 2>/dev/null \
           | grep 'Mach-O' \
           | cut -d: -f1 \
           | grep -v "/logic-markers-engine$" \
           | sort -r)
echo "    signed $count nested Mach-O binaries"

echo "==> Signing engine executable"
sign_runtime "$ENGINE_ENTITLEMENTS" "$ENGINE_DIR/logic-markers-engine"

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

echo "==> Verify (codesign --verify --strict --deep)"
codesign --verify --strict --deep --verbose=4 "$APP"
echo "==> App signature summary"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=|TeamIdentifier=|Identifier=|Runtime" || true
echo "==> Engine signature summary"
codesign -dvvv "$ENGINE_DIR/logic-markers-engine" 2>&1 \
  | grep -E "Authority=|TeamIdentifier=|Runtime|Entitlement" || true
echo
echo "Signed OK. Next: packaging/notarize-app.sh \"$APP\""
