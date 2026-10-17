#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/studio-v05-qa
HARNESS_APP="$PROJECT_ROOT/work/studio-v05-qa/StudioV05Verification.app"
mkdir -p "$HARNESS_APP/Contents/MacOS" "$HARNESS_APP/Contents/Resources"
cp .build/xcode/Build/Products/Debug/MyWorkbench.app/Contents/Resources/Assets.car "$HARNESS_APP/Contents/Resources/Assets.car"
cat > "$HARNESS_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.myworkbench.qa.studio-v05</string>
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
xcrun swiftc -parse-as-library -swift-version 5 -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" scripts/verify_native_studio_v05.swift -o "$HARNESS_APP/Contents/MacOS/verify"
"$HARNESS_APP/Contents/MacOS/verify"
