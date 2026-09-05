#!/usr/bin/env bash
# Assemble a distributable .app: build the SwiftUI app (Release) and embed the
# frozen engine folder at Contents/Resources/engine/. Output goes to
# packaging/dist/PlayolaInterviewEditor.app, ready for sign-app.sh.
#
#   packaging/package-engine.sh   # first, produces the frozen engine
#   packaging/build-app.sh        # then, this
#   packaging/sign-app.sh   packaging/dist/PlayolaInterviewEditor.app
#   packaging/notarize-app.sh packaging/dist/PlayolaInterviewEditor.app
#
# Builds unsigned (CODE_SIGNING_ALLOWED=NO); sign-app.sh applies the Developer ID
# signature + hardened runtime afterward, so the slow xcodebuild stays uncoupled
# from signing credentials.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_SRC="$REPO_ROOT/packaging/dist/logic-markers-engine"
CUT_SRC="$REPO_ROOT/packaging/dist/cut-suggester-engine"
DIST="$REPO_ROOT/packaging/dist"

[ -x "$ENGINE_SRC/logic-markers-engine" ] || {
  echo "error: frozen engine missing at $ENGINE_SRC (run package-engine.sh first)" >&2
  exit 1
}
[ -x "$CUT_SRC/cut-suggester-engine" ] || {
  echo "error: frozen cut-suggester missing at $CUT_SRC (run package-cut-suggester.sh first)" >&2
  exit 1
}

echo "==> Building PlayolaInterviewEditor.app (Release, unsigned)"
cd "$REPO_ROOT/QuickInterviewEditor"
xcodebuild \
  -scheme PlayolaInterviewEditor \
  -configuration Release \
  -derivedDataPath "$REPO_ROOT/packaging/build/app" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT="$REPO_ROOT/packaging/build/app/Build/Products/Release/PlayolaInterviewEditor.app"
[ -d "$BUILT" ] || { echo "error: build produced no .app at $BUILT" >&2; exit 1; }

echo "==> Embedding frozen engine + cut-suggester at Contents/Resources/engine/"
DEST_APP="$DIST/PlayolaInterviewEditor.app"
rm -rf "$DEST_APP"
/usr/bin/ditto "$BUILT" "$DEST_APP"
ENGINE_DEST="$DEST_APP/Contents/Resources/engine"
mkdir -p "$ENGINE_DEST"
# Preflight: the two one-folder bundles must not share any top-level entry name, or
# the second ditto would overwrite the first's files (e.g. a stray `_internal`
# clobbering the engine's Python/libs before signing). Fail loud rather than merge
# a corrupted engine dir.
COLLIDE="$(comm -12 \
  <(cd "$ENGINE_SRC" && ls -1A | sort) \
  <(cd "$CUT_SRC" && ls -1A | sort))"
if [ -n "$COLLIDE" ]; then
  echo "error: engine + cut-suggester bundles share top-level entries, refusing to merge:" >&2
  echo "$COLLIDE" | sed 's/^/       /' >&2
  echo "       (cut-suggester.spec must set contents_directory=_cut_suggester_internal)" >&2
  exit 1
fi
# Both frozen one-folder bundles ditto INTO the same engine/ dir. Their support
# trees don't collide — logic-markers uses _internal/, cut-suggester uses
# _cut_suggester_internal/ (set via contents_directory in cut-suggester.spec). The
# only top-level artifacts are the two executables, landing at
# engine/logic-markers-engine and engine/cut-suggester-engine (the paths the Swift
# EngineResolver / CutSuggesterResolver seams expect). ditto preserves the symlinks
# PyInstaller 6 bundles rely on — do NOT swap it for cp.
/usr/bin/ditto "$ENGINE_SRC" "$ENGINE_DEST"
/usr/bin/ditto "$CUT_SRC" "$ENGINE_DEST"

echo "==> Assembled: $DEST_APP"
du -sh "$DEST_APP" | awk '{print "    app size: " $1}'
echo "Next: packaging/sign-app.sh \"$DEST_APP\""
