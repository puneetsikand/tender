#!/bin/zsh
# Builds dist/PhotoFerry.app (universal) with the `pf` CLI inside the bundle.
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
codesign --force --options runtime --sign - --timestamp=none $APP/Contents/MacOS/pf
codesign --force --options runtime --sign - --timestamp=none $APP

lipo -archs $APP/Contents/MacOS/PhotoFerry
echo "Built $APP ($VERSION, ad-hoc signed)"
