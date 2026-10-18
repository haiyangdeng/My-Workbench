#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/log-response-qa
APP_SOURCES=()
for source in Sources/WorkbenchApp/*.swift; do
  [[ "${source:t}" != MyWorkbenchApp.swift ]] && APP_SOURCES+=("$source")
done
xcrun swiftc -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o -parse-as-library -swift-version 5 Sources/WorkbenchCore/*.swift "${APP_SOURCES[@]}" scripts/verify_native_log_response.swift -o work/log-response-qa/verify
work/log-response-qa/verify
