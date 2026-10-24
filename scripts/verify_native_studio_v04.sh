#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/studio-v04-qa
# Every app source except the @main app file, so newly added files are always included.
APP_SOURCES=()
for source in Sources/WorkbenchApp/*.swift; do
  if [[ "${source:t}" != MyWorkbenchApp.swift ]]; then APP_SOURCES+=("$source"); fi
done
xcrun swiftc -parse-as-library -swift-version 5 -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" scripts/verify_native_studio_v04.swift -o work/studio-v04-qa/verify
work/studio-v04-qa/verify
