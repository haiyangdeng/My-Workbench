#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/collaboration-qa
xcrun swiftc -parse-as-library -swift-version 5 Sources/WorkbenchCore/*.swift Sources/WorkbenchApp/WorkbenchStore.swift scripts/verify_real_collaboration.swift -o work/collaboration-qa/verify
work/collaboration-qa/verify "$@"
