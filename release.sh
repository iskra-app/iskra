#!/bin/bash
#
# Builds a Release Iskra for the Mac, signed with Developer ID, and packs it into a zip that can be
# sent to somebody to try — a friend's Mac, not an App Store build.
#
#   ./release.sh                 # build, sign, zip → .build/mac-release/Iskra-<version>.zip
#   ./release.sh --open          # and start the built app here afterwards
#   NOTARY_PROFILE=iskra ./release.sh   # and notarize it, so it opens with a double-click
#
# Why Developer ID and not the build ./run.sh makes: a Debug build is signed for development and
# runs only on Macs registered to the team; a friend's Mac refuses it. Developer ID runs anywhere.
#
# Notarizing needs a keychain profile made once:
#   xcrun notarytool store-credentials iskra --apple-id <id> --team-id 936RH3UPR3
# Without it the zip is still signed, but the first launch has to be right-click → Open (macOS
# says it cannot check the app for malicious software, which is true until it is notarized).
#
# A Release build has no demo server and no probes (`#if DEBUG`), which is the point of testing it.
#
# CODE_SIGNING_ALLOWED=NO is never passed, for the reason in run.sh and CLAUDE.md.

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Apps/Iskra.xcodeproj"
SCHEME="Iskra (macOS)"
OUT="$PWD/.build/mac-release"
ARCHIVE="$OUT/Iskra.xcarchive"
EXPORT="$OUT/export"
LOGS="$PWD/.build/logs"

open_after=0
[ "${1:-}" = "--open" ] && open_after=1

mkdir -p "$OUT" "$LOGS"
rm -rf "$ARCHIVE" "$EXPORT"

step() { printf '\n▸ %s\n' "$1"; }
fail() { echo "✘ $1 — see $2"; grep -E "error:" "$2" | head -20 || true; exit 1; }

step "Generating the project"
(cd Apps && xcodegen) > "$LOGS/release-xcodegen.log" 2>&1 || fail "xcodegen failed" "$LOGS/release-xcodegen.log"

step "Archiving (Release)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates archive > "$LOGS/release-archive.log" 2>&1 \
  || fail "the archive failed" "$LOGS/release-archive.log"

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>936RH3UPR3</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates \
  > "$LOGS/release-export.log" 2>&1 || fail "the export failed" "$LOGS/release-export.log"

APP="$EXPORT/Iskra.app"
[ -d "$APP" ] || { echo "✘ no Iskra.app in $EXPORT"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo dev)
ZIP="$OUT/Iskra-$VERSION.zip"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  step "Notarizing"
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait \
    > "$LOGS/release-notarize.log" 2>&1 || fail "notarization failed" "$LOGS/release-notarize.log"
  xcrun stapler staple "$APP" >> "$LOGS/release-notarize.log" 2>&1
  rm -f "$OUT/notarize.zip"
fi

step "Zipping"
rm -f "$ZIP"
# ditto, not zip: it keeps the signature's extended attributes and the bundle's symlinks intact.
ditto -c -k --keepParent "$APP" "$ZIP"

codesign --verify --deep --strict "$APP" && echo "  signature ok"
echo
echo "✔ $ZIP ($(du -h "$ZIP" | cut -f1))"
[ -z "${NOTARY_PROFILE:-}" ] && echo "  Not notarized: on the other Mac, the first launch is right-click → Open."

if [ "$open_after" = 1 ]; then
  pkill -x Iskra 2>/dev/null || true
  open "$APP"
fi
