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
  # Xcode 27 replaced Simulator.app with DeviceHub.app, so `open -a Simulator` now fails
  # outright — Launch Services has no app by that name any more. DeviceHub is addressed by
  # bundle ID and not by name: it is "DeviceHub" on disk and "Device Hub" to read, and the
  # ID is the one spelling that is neither.
  local devices_app="com.apple.dt.Devices"

  # DeviceHub shows the devices; it does not boot one. Simulator.app used to boot its last
  # device on launch, which is why the old script could open it and then wait for a boot to
  # turn up — that wait would now never end. So: keep whatever is already booted, since the
  # user chose it, and otherwise pick a device and boot it here.
  local udid
  udid="$(xcrun simctl list devices booted | grep -Eo '[0-9A-F-]{36}' | head -1 || true)"
  if [ -z "$udid" ]; then
    # The first iPhone under the last `-- iOS x.y --` heading: newest runtime, and its
    # roomiest phone, because simctl lists the Pro models first. `available` is load-bearing
    # — the unavailable runtimes are listed too, and a device picked out of one of those
    # would fail at boot for want of a runtime that is not installed.
    udid="$(xcrun simctl list devices available iPhone | awk '
      /^-- iOS/ { seen = 0; next }
      /^-- /    { next }
      seen      { next }
      match($0, /[0-9A-F-]{36}/) { print substr($0, RSTART, RLENGTH); seen = 1 }
    ' | tail -1)"
    [ -n "$udid" ] || { echo "No iPhone simulator installed — Xcode > Settings > Components." >&2; exit 1; }
  fi
  # `bootstatus -b` boots it if it is shut down and returns only once it has finished
  # booting; `simctl install` against a half-booted device fails.
  xcrun simctl bootstatus "$udid" -b

  open -b "$devices_app"

  local app="$DERIVED/Build/Products/Debug-iphonesimulator/Iskra.app"
  # By UDID, not `booted`: this is the device that was just booted, and `booted` picks one
  # of them at random when the user happens to have two running.
  xcrun simctl install "$udid" "$app"
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  # `${a[@]+"${a[@]}"}`, not `"${a[@]}"`: /bin/bash on macOS is 3.2, where an empty array
  # expanded under `set -u` is an unbound variable rather than nothing at all — so the plain
  # form would abort the script here, at the launch, after the whole build had succeeded.
  xcrun simctl launch --console "$udid" "$BUNDLE_ID" ${app_args[@]+"${app_args[@]}"}
}

case "$target" in
  mac) build_mac ;;
  ios) build_ios ;;
  both)
    build_mac
    build_ios
    ;;
esac
