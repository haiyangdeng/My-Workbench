#!/bin/zsh
# Builds the universal Release app (x86_64 + arm64, ad hoc signed) and packs it for a GitHub release:
#   releases/Workbench-<version>.dmg            drag-to-Applications disk image
#   releases/Workbench-<version>-macOS.zip      the app alone
#   releases/Workbench-<version>-SHA256SUMS.txt checksums of both
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work releases

echo "Building the universal Release app…"
xcodebuild -project MyWorkbench.xcodeproj -scheme MyWorkbench -configuration Release -derivedDataPath .build/release \
  ARCHS='x86_64 arm64' ONLY_ACTIVE_ARCH=NO build > work/release-build.log 2>&1 || { tail -30 work/release-build.log; exit 1; }
APP=.build/release/Build/Products/Release/Workbench.app
/usr/bin/codesign --verify --deep --strict "$APP"
xcrun lipo "$APP/Contents/MacOS/Workbench" -verify_arch x86_64 arm64
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")

STAGE=work/dmg-stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Workbench.app"
ln -s /Applications "$STAGE/Applications"
DMG="releases/Workbench-$VERSION.dmg"
ZIP="releases/Workbench-$VERSION-macOS.zip"
rm -f "$DMG" "$ZIP"
hdiutil create -quiet -volname "Workbench $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd releases && shasum -a 256 "Workbench-$VERSION.dmg" "Workbench-$VERSION-macOS.zip" > "Workbench-$VERSION-SHA256SUMS.txt")
rm -rf "$STAGE"
echo "Workbench $VERSION ($BUILD), universal, ad hoc signed:"
ls -lh "$DMG" "$ZIP" | awk '{print "  " $5 "  " $9}'
cat "releases/Workbench-$VERSION-SHA256SUMS.txt"
