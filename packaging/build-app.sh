#!/usr/bin/env bash
# Assemble a distributable .app: build the SwiftUI app (Release) and embed the
# frozen engine folder at Contents/Resources/engine/. Output goes to
# packaging/dist/QuickInterviewEditor.app, ready for sign-app.sh.
#
#   packaging/package-engine.sh   # first, produces the frozen engine
#   packaging/build-app.sh        # then, this
#   packaging/sign-app.sh   packaging/dist/QuickInterviewEditor.app
#   packaging/notarize-app.sh packaging/dist/QuickInterviewEditor.app
#
# Builds unsigned (CODE_SIGNING_ALLOWED=NO); sign-app.sh applies the Developer ID
# signature + hardened runtime afterward, so the slow xcodebuild stays uncoupled
# from signing credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_SRC="$REPO_ROOT/packaging/dist/logic-markers-engine"
DIST="$REPO_ROOT/packaging/dist"

[ -x "$ENGINE_SRC/logic-markers-engine" ] || {
  echo "error: frozen engine missing at $ENGINE_SRC (run package-engine.sh first)" >&2
  exit 1
}

echo "==> Building QuickInterviewEditor.app (Release, unsigned)"
cd "$REPO_ROOT/QuickInterviewEditor"
xcodebuild \
  -scheme QuickInterviewEditor \
  -configuration Release \
  -derivedDataPath "$REPO_ROOT/packaging/build/app" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT="$REPO_ROOT/packaging/build/app/Build/Products/Release/QuickInterviewEditor.app"
[ -d "$BUILT" ] || { echo "error: build produced no .app at $BUILT" >&2; exit 1; }

echo "==> Embedding frozen engine at Contents/Resources/engine/"
DEST_APP="$DIST/QuickInterviewEditor.app"
rm -rf "$DEST_APP"
/usr/bin/ditto "$BUILT" "$DEST_APP"
mkdir -p "$DEST_APP/Contents/Resources/engine"
/usr/bin/ditto "$ENGINE_SRC" "$DEST_APP/Contents/Resources/engine"

echo "==> Assembled: $DEST_APP"
du -sh "$DEST_APP" | awk '{print "    app size: " $1}'
echo "Next: packaging/sign-app.sh \"$DEST_APP\""
