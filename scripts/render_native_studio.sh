#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/studio-render
cp scripts/render_native_studio.swift work/studio-render/main.swift
# Every app source except the @main app file, so newly added files are always included.
APP_SOURCES=()
for source in Sources/WorkbenchApp/*.swift; do
  if [[ "${source:t}" != MyWorkbenchApp.swift ]]; then APP_SOURCES+=("$source"); fi
done
xcrun swiftc -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o -swift-version 5 Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" work/studio-render/main.swift -o work/studio-render/render
work/studio-render/render
