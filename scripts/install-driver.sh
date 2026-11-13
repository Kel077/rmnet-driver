#!/bin/sh
# Signed build of the RMNet host app and driver, installed to /Applications/RMNet.app and activated.
# Every run gets a new CFBundleVersion (the current time), so activation replaces a running driver.
# The first activation needs the owner's approval in System Settings.
set -eu

cd "$(dirname "$0")/.." || exit 1

TEAM=ABCDE12345
VERSION=$(date +%s)
BUILD="$PWD/build/xcode-signed"
APP=/Applications/RMNet.app

stage=start
step() {
  stage=$1
  echo "==> $1"
}
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "install-driver: failed during: $stage" >&2' EXIT

step "generate RMNet.xcodeproj for team $TEAM"
/usr/bin/ruby gen.rb "$TEAM"

step "signed build, version $VERSION"
xcodebuild -project RMNet.xcodeproj -target RMNet -configuration Release -parallelizeTargets \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  SYMROOT="$BUILD" OBJROOT="$BUILD/obj" CURRENT_PROJECT_VERSION="$VERSION" build

step "copy to $APP"
rm -rf "$APP"
ditto "$BUILD/Release/RMNet.app" "$APP"

step "activate"
"$APP/Contents/MacOS/RMNet" activate

step "done"
