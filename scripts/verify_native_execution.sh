#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/execution-qa
xcrun swiftc -parse-as-library -swift-version 5 Sources/WorkbenchCore/*.swift Sources/WorkbenchApp/WorkbenchStore*.swift scripts/verify_native_execution.swift -o work/execution-qa/verify
work/execution-qa/verify "$@"
