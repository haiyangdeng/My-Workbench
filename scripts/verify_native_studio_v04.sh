#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/studio-v04-qa
xcrun swiftc -parse-as-library -swift-version 5 -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o Sources/WorkbenchCore/*.swift Sources/WorkbenchApp/WorkbenchStore.swift Sources/WorkbenchApp/WorkbenchView.swift Sources/WorkbenchApp/StudioComponents.swift Sources/WorkbenchApp/ReadOnlyTextView.swift Sources/WorkbenchApp/ExecutionViews.swift Sources/WorkbenchApp/CollaborationViews.swift Sources/WorkbenchApp/TerminalWorkspace.swift Sources/WorkbenchApp/WorkspaceConfigurationSheet.swift scripts/verify_native_studio_v04.swift -o work/studio-v04-qa/verify
work/studio-v04-qa/verify
