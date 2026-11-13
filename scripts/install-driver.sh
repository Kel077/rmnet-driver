#!/bin/sh
# Signed build of the RMNet host app and driver, installed to /Applications/RMNet.app and activated.
# Every run gets a new, increasing CFBundleVersion, so activation replaces a running driver. A dext's
# CFBundleVersion must be a valid kext version (major up to 4 digits, minor and revision up to 2),
# so it is <days since 2026-01-01>.<hour>.<minute>, in UTC. Two installs in the same minute get the
# same version; the script refuses the second rather than install a build the system would not load.
# The first activation needs the owner's approval in System Settings.
#
# A driver can only be deactivated by an app that embeds that exact driver version, so a copy of
# the app for every activated version is kept in build/installed/RMNet-<version>.app (README,
# "Removing the driver"). Nothing here ever deactivates.
set -eu

cd "$(dirname "$0")/.." || exit 1

TEAM=ABCDE12345
BUILD="$PWD/build/xcode-signed"
NEW="$BUILD/Release/RMNet.app"
APP=/Applications/RMNet.app
KEEP="$PWD/build/installed"
DRIVER_ID=io.rmnetdriver.RMNet.driver

now=$(date -u +%s)
epoch=$(date -u -j -f '%Y-%m-%d %H:%M:%S' '2026-01-01 00:00:00' +%s)
secs=$((now - epoch))
VERSION="$((secs / 86400)).$((secs % 86400 / 3600)).$((secs % 3600 / 60))"

stage=start
step() {
  stage=$1
  echo "==> $1"
}
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "install-driver: failed during: $stage" >&2' EXIT

# The version of the driver the system has activated and enabled, or nothing.
active_version() {
  systemextensionsctl list | grep "	$DRIVER_ID (" | grep 'activated enabled' |
    sed -n 's/.*(\([^/]*\)\/\([0-9.]*\)).*/\2/p' | head -1
}

# Keeps a copy of the app at $1 as build/installed/RMNet-<its version>.app.
keep_app() {
  v=$(/usr/bin/defaults read "$1/Contents/Info" CFBundleVersion 2>/dev/null || true)
  [ -n "$v" ] || return 0
  [ -d "$KEEP/RMNet-$v.app" ] && return 0
  mkdir -p "$KEEP"
  ditto "$1" "$KEEP/RMNet-$v.app"
  echo "kept $KEEP/RMNet-$v.app"
}

installed=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || true)
if [ "$installed" = "$VERSION" ]; then
  echo "install-driver: version $VERSION is already installed; wait a minute and run again" >&2
  exit 1
fi

step "generate RMNet.xcodeproj for team $TEAM"
/usr/bin/ruby gen.rb "$TEAM"

step "signed build, version $VERSION"
rm -rf "$NEW"
xcodebuild -project RMNet.xcodeproj -target RMNet -configuration Release -parallelizeTargets \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  SYMROOT="$BUILD" OBJROOT="$BUILD/obj" CURRENT_PROJECT_VERSION="$VERSION" build

step "check the new build"
built=$(/usr/bin/defaults read "$NEW/Contents/Info" CFBundleVersion 2>/dev/null || true)
[ "$built" = "$VERSION" ] || { echo "install-driver: $NEW missing or not version $VERSION" >&2; exit 1; }

step "keep the app that matches the active driver"
active=$(active_version)
if [ -z "$active" ]; then
  echo "no active $DRIVER_ID"
elif [ "$installed" = "$active" ]; then
  keep_app "$APP"
elif [ -d "$KEEP/RMNet-$active.app" ]; then
  echo "already kept: $KEEP/RMNet-$active.app"
else
  echo "install-driver: active driver $active has no matching app ($APP is ${installed:-missing})" >&2
  echo "install-driver: without one it cannot be deactivated; see README, Removing the driver" >&2
  exit 1
fi

step "copy to $APP"
rm -rf "$APP"
ditto "$NEW" "$APP"

step "activate"
"$APP/Contents/MacOS/RMNet" activate
active=$(active_version)
[ "$active" = "$VERSION" ] || { echo "install-driver: active driver is ${active:-none}, not $VERSION" >&2; exit 1; }
keep_app "$APP"

# A running RMNetDriver is not stopped by a replacement (its services refuse to terminate), so the
# new build only loads when the modem re-enumerates. Say so rather than leave the old one running.
step "check the running driver"
new=$(codesign -dvvv "$APP/Contents/Library/SystemExtensions/io.rmnetdriver.RMNet.driver.dext" 2>&1 | sed -n 's/^CDHash=//p')
running=$(ioreg -r -n RMNetDriver -d 1 -w0 | sed -n 's/.*"IOUserServerCDHash" = "\([0-9a-f]*\)".*/\1/p' | head -1)
if [ -z "$running" ]; then
  echo "no RMNetDriver attached (modem not attached in QMI mode?)"
elif [ "$running" = "$new" ]; then
  echo "version $VERSION is the running driver"
else
  echo "an older build is still running; version $VERSION loads when the modem re-enumerates"
  echo "(unplug it, or send AT+CFUN=1,1)"
fi

step "done"
