#!/usr/bin/env bash
# Build a distributable DMG from the signed+notarized app, then sign + notarize +
# staple the DMG itself.  packaging/make-dmg.sh  (reads versions from Info.plist)
#
# Gatekeeper checks the outermost container the user opens, so the DMG must be
# signed, notarized, and stapled (stapling lets it validate offline). The filename
# carries BOTH CFBundleShortVersionString and the integer CFBundleVersion so two
# builds sharing a marketing version never overwrite each other in S3 (which would
# break rollback and invalidate the earlier appcast signature).
#
# Requires: create-dmg (brew install create-dmg), a Developer ID identity, and a
# notarytool keychain profile (NOTARY_PROFILE).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/packaging/dist"
APP="$DIST/QuickInterviewEditor.app"
[ -d "$APP" ] || { echo "error: no app at $APP (run build/sign/notarize first)" >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg not found (brew install create-dmg)" >&2; exit 1; }
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/QuickInterviewEditor-$SHORT-$BUILD.dmg"
rm -f "$DMG"
# create-dmg copies the CONTENTS of its source folder into the image, so it must be
# given a folder that CONTAINS QuickInterviewEditor.app — not the .app itself (that
# would copy Contents/… to the DMG root, leaving no app for --icon/--app-drop-link
# and breaking drag-to-Applications). Stage the signed bundle into a clean temp dir.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/qie-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/QuickInterviewEditor.app"
echo "==> Building DMG: $(basename "$DMG")"
create-dmg \
  --volname "QuickInterviewEditor $SHORT" \
  --app-drop-link 480 200 \
  --icon "QuickInterviewEditor.app" 160 200 \
  --window-size 640 400 \
  "$DMG" "$STAGE"
echo "==> Signing the DMG (Developer ID)"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "==> DMG: $DMG"
du -sh "$DMG" | awk '{print "    dmg size: " $1}'
