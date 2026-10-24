#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
cd "$PROJECT_ROOT"
HARNESS_APP="$PROJECT_ROOT/work/site-screens/SiteScreens.app"
mkdir -p "$HARNESS_APP/Contents/MacOS" "$HARNESS_APP/Contents/Resources"
cp .build/xcode/Build/Products/Debug/Workbench.app/Contents/Resources/Assets.car "$HARNESS_APP/Contents/Resources/Assets.car"
cat > "$HARNESS_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.workbench.qa.sitescreens</string>
<key>CFBundleExecutable</key><string>preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
APP_SOURCES=()
for source in Sources/WorkbenchApp/*.swift; do
  if [[ "${source:t}" != MyWorkbenchApp.swift ]]; then APP_SOURCES+=("$source"); fi
done
xcrun swiftc -whole-module-optimization -Onone -parse-as-library -swift-version 5 -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" scripts/render_site_screens.swift -o "$HARNESS_APP/Contents/MacOS/preview"
"$HARNESS_APP/Contents/MacOS/preview"
