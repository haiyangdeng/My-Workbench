#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work releases
xcrun swift test > work/release-tests.log 2>&1
xcodebuild -project MyWorkbench.xcodeproj -scheme MyWorkbench -configuration Release -derivedDataPath .build/release ARCHS='x86_64 arm64' ONLY_ACTIVE_ARCH=NO build > work/release-build.log 2>&1
APP_BUNDLE="$PROJECT_ROOT/.build/release/Build/Products/Release/Workbench.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" > work/release-signature.log 2>&1
xcrun lipo "$APP_BUNDLE/Contents/MacOS/Workbench" -verify_arch x86_64 arm64
python3 scripts/package_release.py
