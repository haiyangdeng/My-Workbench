#!/bin/zsh
# M8 media studio: local ComfyUI-compatible fixtures, director plans, budgets and reviews through the real store.
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
cd "$PROJECT_ROOT"
mkdir -p work/m8-qa
HARNESS_APP="$PROJECT_ROOT/work/m8-qa/M8Verification.app"
mkdir -p "$HARNESS_APP/Contents/MacOS" "$HARNESS_APP/Contents/Resources"
cp .build/xcode/Build/Products/Debug/Workbench.app/Contents/Resources/Assets.car "$HARNESS_APP/Contents/Resources/Assets.car"
cat > "$HARNESS_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.myworkbench.qa.m8</string>
<key>CFBundleExecutable</key><string>verify</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
APP_SOURCES=()
for source in Sources/WorkbenchApp/*.swift; do
  if [[ "${source:t}" != MyWorkbenchApp.swift ]]; then
    APP_SOURCES+=("$source")
  fi
done
xcrun swiftc -whole-module-optimization -Onone -parse-as-library -swift-version 5 -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" scripts/verify_m8.swift -o "$HARNESS_APP/Contents/MacOS/verify"
# Same minimal environment an app opened from Finder gets.
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$HARNESS_APP/Contents/MacOS/verify"
