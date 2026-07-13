#!/bin/bash
#
# Rebuilds Iskra and runs it: on the Mac, in the iPhone simulator, or both.
#
#   ./run.sh            # both
#   ./run.sh mac
#   ./run.sh ios
#   ./run.sh ios --verify-storage    # extra arguments are passed to the app
#
# The .xcodeproj is generated and gitignored, so every run regenerates it first.
#
# CODE_SIGNING_ALLOWED=NO is never passed, and must never be added here. The build would
# succeed, the app would install, and it would then die with SIGTRAP the moment the user
# signed in: an unsigned app is granted none of its entitlements, so the App Group container
# cannot be resolved. See CLAUDE.md.

set -euo pipefail

cd "$(dirname "$0")"

BUNDLE_ID="moscow.swag.iskra"
DERIVED="$PWD/.build/xcode"
PROJECT="Apps/Iskra.xcodeproj"

target="${1:-both}"
case "$target" in
  mac|ios|both) shift || true ;;
  *) target="both" ;;
esac
app_args=("$@")

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }

say "Regenerating $PROJECT"
(cd Apps && xcodegen)

build_mac() {
  say "Building for macOS"
  xcodebuild -project "$PROJECT" -scheme 'Iskra (macOS)' \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" build

  say "Launching Iskra on the Mac"
  local app="$DERIVED/Build/Products/Debug/Iskra.app"
  # Killed first, or `open` politely raises the copy that is already running — which is the
  # build from last time, and the whole point of this script is to see the new one.
  pkill -x Iskra 2>/dev/null || true
  if [ ${#app_args[@]} -gt 0 ]; then
    open -a "$app" --args "${app_args[@]}"
  else
    open -a "$app"
  fi
}

build_ios() {
  say "Building for the iPhone simulator"
  # `generic/platform=iOS Simulator`, not a named device: two simulators can share a name
  # and xcodebuild refuses an ambiguous destination.
  xcodebuild -project "$PROJECT" -scheme 'Iskra (iOS)' \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" build

  say "Launching Iskra in the simulator"
  open -a Simulator
  # There may be no booted simulator yet, and `simctl install booted` fails outright if
  # there isn't. Waiting beats telling the user to go and boot one by hand.
  until xcrun simctl list devices booted | grep -q Booted; do sleep 1; done

  local app="$DERIVED/Build/Products/Debug-iphonesimulator/Iskra.app"
  xcrun simctl install booted "$app"
  xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
  # `${a[@]+"${a[@]}"}`, not `"${a[@]}"`: /bin/bash on macOS is 3.2, where an empty array
  # expanded under `set -u` is an unbound variable rather than nothing at all — so the plain
  # form would abort the script here, at the launch, after the whole build had succeeded.
  xcrun simctl launch --console booted "$BUNDLE_ID" ${app_args[@]+"${app_args[@]}"}
}

case "$target" in
  mac) build_mac ;;
  ios) build_ios ;;
  both)
    build_mac
    build_ios
    ;;
esac
