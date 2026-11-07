#!/bin/zsh
# Builds dist/PhotoFerry.app (universal) with the `pf` CLI and the copy XPC service inside.
#   scripts/package.sh
# For now the app is ad-hoc signed with the hardened runtime. Developer ID signing and
# notarization (PLAN §9.1) replace the ad-hoc identity at M8.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=$(<VERSION)
DIST=dist
APP=$DIST/PhotoFerry.app

rm -rf $DIST
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN/PhotoFerry $APP/Contents/MacOS/PhotoFerry
cp $BIN/pf $APP/Contents/MacOS/pf
sed "s/__VERSION__/$VERSION/g" Packaging/Info.plist > $APP/Contents/Info.plist

# Copy service (PLAN §8A.2). Signed inside-out: service, CLI, then the app.
XPC=$APP/Contents/XPCServices/local.photoferry.copyservice.xpc
mkdir -p $XPC/Contents/MacOS
cp $BIN/PhotoFerryCopyService $XPC/Contents/MacOS/PhotoFerryCopyService
sed "s/__VERSION__/$VERSION/g" Packaging/CopyService-Info.plist > $XPC/Contents/Info.plist

codesign --force --options runtime --sign - --timestamp=none $XPC
codesign --force --options runtime --sign - --timestamp=none $APP/Contents/MacOS/pf
codesign --force --options runtime --sign - --timestamp=none $APP
codesign --verify --deep --strict $APP

lipo -archs $APP/Contents/MacOS/PhotoFerry
echo "Built $APP ($VERSION, ad-hoc signed)"
