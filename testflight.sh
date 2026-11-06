#!/bin/bash
#
# Archives Iskra for the App Store and, when asked, uploads it to App Store Connect, from where
# TestFlight takes it.
#
#   ./testflight.sh                  # iOS and Mac: archive, export a signed .ipa / .pkg, stop
#   ./testflight.sh ios              # just iPhone and iPad
#   ./testflight.sh mac              # just the Mac
#   ./testflight.sh both --upload    # ... and upload, after asking once
#   ./testflight.sh ios --upload --yes   # skip the question (for a person who has already decided)
#
# Without --upload nothing leaves this machine. The export proves what can be proved without
# Apple: the archive builds in Release, signs with App Store profiles and exports. Look at
# .build/testflight/<platform>/ before uploading.
#
# The upload goes through Xcode's own account (`destination: upload` in the export options), so
# Xcode → Settings → Accounts must hold the Apple ID of team 936RH3UPR3. There is no password or
# API key in this script, and none should be added.
#
# Version and build number are stamped from git (the `Stamped` template in Apps/project.yml): the
# build number is the commit count, and App Store Connect refuses a number it already has. Two
# uploads from the same commit are the same number — commit something in between, or upload
# only the platform that failed.
#
# Mac is the Mac App Store build (sandboxed, signed for the store), not release.sh's Developer ID
# one. Both platforms share the bundle ID wtf.iskra, so they are one record in App Store Connect.
#
# CODE_SIGNING_ALLOWED=NO is never passed, for the reason in run.sh and CLAUDE.md.

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Apps/Iskra.xcodeproj"
TEAM="936RH3UPR3"
OUT="$PWD/.build/testflight"
LOGS="$PWD/.build/logs"

which="both"
upload=0
yes=0
for arg in "$@"; do
  case "$arg" in
    ios|mac|both) which="$arg" ;;
    --upload) upload=1 ;;
    --yes) yes=1 ;;
    *) echo "unknown argument: $arg"; exit 2 ;;
  esac
done

mkdir -p "$OUT" "$LOGS"

step() { printf '\n▸ %s\n' "$1"; }
fail() { echo "✘ $1 — see $2"; grep -E "error:" "$2" | head -20 || true; exit 1; }

# Upload from a commit that is not on origin, or from a dirty tree, and the build in TestFlight is
# something nobody can reproduce. Say so; do not refuse — a person may have a reason.
if [ "$upload" = 1 ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "! The working tree has uncommitted changes; the build carries commit $(git rev-parse --short HEAD) but not them."
  fi
  git fetch --quiet origin 2>/dev/null || true
  if ! git branch -r --contains HEAD 2>/dev/null | grep -q .; then
    echo "! $(git rev-parse --short HEAD) is not on any remote branch."
  fi
fi

options() { # options <destination> <file>
  cat > "$2" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$1</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
}

build() { # build <ios|mac>
  local key="$1" scheme dest
  if [ "$key" = ios ]; then scheme="Iskra (iOS)"; dest="generic/platform=iOS"
  else scheme="Iskra (macOS)"; dest="generic/platform=macOS"; fi

  local dir="$OUT/$key" archive="$OUT/$key/Iskra.xcarchive"
  rm -rf "$dir"; mkdir -p "$dir"

  step "[$key] Archiving (Release)"
  xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Release \
    -destination "$dest" -archivePath "$archive" -allowProvisioningUpdates archive \
    > "$LOGS/testflight-$key-archive.log" 2>&1 \
    || fail "the $key archive failed" "$LOGS/testflight-$key-archive.log"

  local info="$archive/Products/Applications/Iskra.app/Info.plist"
  [ "$key" = mac ] && info="$archive/Products/Applications/Iskra.app/Contents/Info.plist"
  echo "  version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$info"), build $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$info")"

  step "[$key] Exporting for the App Store"
  options export "$dir/ExportOptions.plist"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$dir/export" \
    -exportOptionsPlist "$dir/ExportOptions.plist" -allowProvisioningUpdates \
    > "$LOGS/testflight-$key-export.log" 2>&1 \
    || fail "the $key export failed" "$LOGS/testflight-$key-export.log"
  echo "  $(ls "$dir/export" | grep -E '\.(ipa|pkg)$' | head -1) → $dir/export"
}

send() { # send <ios|mac>
  local key="$1" dir="$OUT/$1"
  step "[$key] Uploading to App Store Connect"
  options upload "$dir/ExportOptions-upload.plist"
  xcodebuild -exportArchive -archivePath "$dir/Iskra.xcarchive" -exportPath "$dir/uploaded" \
    -exportOptionsPlist "$dir/ExportOptions-upload.plist" -allowProvisioningUpdates \
    > "$LOGS/testflight-$key-upload.log" 2>&1 \
    || fail "the $key upload failed" "$LOGS/testflight-$key-upload.log"
  echo "  uploaded. It shows up in TestFlight after App Store Connect has processed it (10–30 minutes)."
}

step "Generating the project"
(cd Apps && xcodegen) > "$LOGS/testflight-xcodegen.log" 2>&1 || fail "xcodegen failed" "$LOGS/testflight-xcodegen.log"

platforms=()
case "$which" in
  ios) platforms=(ios) ;;
  mac) platforms=(mac) ;;
  both) platforms=(ios mac) ;;
esac

for p in "${platforms[@]}"; do build "$p"; done

if [ "$upload" = 0 ]; then
  echo
  echo "✔ Exported to $OUT — nothing was uploaded. Add --upload to send it."
  exit 0
fi

if [ "$yes" = 0 ]; then
  echo
  printf 'Upload %s (commit %s) to App Store Connect? [y/N] ' "${platforms[*]}" "$(git rev-parse --short HEAD)"
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || { echo "Not uploaded. The archives are in $OUT."; exit 0; }
fi

for p in "${platforms[@]}"; do send "$p"; done

echo
echo "✔ Done. Next: App Store Connect → TestFlight → External Testing → add the build to a group."
