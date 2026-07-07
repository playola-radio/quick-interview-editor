#!/usr/bin/env bash
# Notarize + staple a signed .app for Gatekeeper acceptance on clean Macs.
#
#   packaging/notarize-app.sh /path/to/QuickInterviewEditor.app
#
# Requires notarytool credentials. Provide EITHER a stored keychain profile:
#   xcrun notarytool store-credentials qie-notary \
#     --apple-id you@example.com --team-id FSRSPV9N9Q --password <app-specific-pw>
#   NOTARY_PROFILE=qie-notary packaging/notarize-app.sh App.app
# OR an App Store Connect API key:
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=XXXX NOTARY_ISSUER=uuid \
#     packaging/notarize-app.sh App.app
#
# NOTE: this step cannot run without those credentials; the packaging spike
# documents this as a gap when they are absent.
set -euo pipefail

APP="${1:?usage: notarize-app.sh /path/to/QuickInterviewEditor.app}"
ZIP="${APP%.app}-notarize.zip"

notary_auth=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  notary_auth=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
  notary_auth=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
else
  echo "error: no notarytool credentials. Set NOTARY_PROFILE or NOTARY_KEY/…." >&2
  echo "       (This is the documented gap when creds aren't configured.)" >&2
  exit 2
fi

echo "==> Zipping app for submission (ditto preserves signatures/symlinks)"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (waits for result)"
xcrun notarytool submit "$ZIP" "${notary_auth[@]}" --wait

echo "==> Stapling the ticket to the .app"
xcrun stapler staple "$APP"

echo "==> Validate staple + Gatekeeper assessment"
xcrun stapler validate "$APP"
spctl --assess --type exec -vvv "$APP"
rm -f "$ZIP"
echo "Notarized + stapled OK."
