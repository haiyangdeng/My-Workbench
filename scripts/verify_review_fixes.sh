#!/bin/zsh
# Regression checks for the 2026-10-24 review fixes and theme-dependent app icons.
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
cd "$PROJECT_ROOT"
mkdir -p work/review-fixes-qa
HARNESS_APP="$PROJECT_ROOT/work/review-fixes-qa/ReviewFixes.app"
mkdir -p "$HARNESS_APP/Contents/MacOS" "$HARNESS_APP/Contents/Resources"
cp .build/xcode/Build/Products/Debug/Workbench.app/Contents/Resources/Assets.car "$HARNESS_APP/Contents/Resources/Assets.car"
cp .build/xcode/Build/Products/Debug/Workbench.app/Contents/Resources/AppIcon.icns "$HARNESS_APP/Contents/Resources/AppIcon.icns"
cat > "$HARNESS_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.myworkbench.qa.reviewfixes</string>
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
xcrun swiftc -whole-module-optimization -Onone -parse-as-library -swift-version 5 -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" scripts/verify_review_fixes.swift -o "$HARNESS_APP/Contents/MacOS/verify"
# Same minimal environment an app opened from Finder gets.
env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$HARNESS_APP/Contents/MacOS/verify"
