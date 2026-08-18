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
# Requires: a Developer ID identity + a notarytool keychain profile (NOTARY_PROFILE).
# Uses hdiutil (not create-dmg): create-dmg drives Finder over AppleEvents to arrange
# the window, which needs an interactive GUI session with Automation permission and
# times out (-1712) when the release runs headless/detached. A plain read-only DMG
# with the app + an /Applications shortcut is all a drag-install needs.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$REPO_ROOT/packaging/dist"
APP="$DIST/QuickInterviewEditor.app"
[ -d "$APP" ] || { echo "error: no app at $APP (run build/sign/notarize first)" >&2; exit 1; }
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Playola Radio, Incorporated (FSRSPV9N9Q)}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile)}"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$DIST/QuickInterviewEditor-$SHORT-$BUILD.dmg"
rm -f "$DMG"
# Stage the signed bundle + an /Applications shortcut into a clean temp dir, then
# image the whole dir (read-only, compressed). ditto preserves the app's signature
# and symlinks; the /Applications symlink gives the drag-to-install target.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/qie-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/QuickInterviewEditor.app"
ln -s /Applications "$STAGE/Applications"
echo "==> Building DMG (hdiutil, no Finder): $(basename "$DMG")"
hdiutil create -volname "QuickInterviewEditor $SHORT" \
  -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "==> Signing the DMG (Developer ID)"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "==> Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
echo "==> Stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
echo "==> DMG: $DMG"
du -sh "$DMG" | awk '{print "    dmg size: " $1}'
