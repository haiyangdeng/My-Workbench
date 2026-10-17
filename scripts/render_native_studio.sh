#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
mkdir -p work/studio-render
cp scripts/render_native_studio.swift work/studio-render/main.swift
xcrun swiftc -I .build/xcode/Build/Products/Debug .build/xcode/Build/Products/Debug/SwiftTerm.o -swift-version 5 Sources/WorkbenchCore/*.swift Sources/WorkbenchApp/WorkbenchStore.swift Sources/WorkbenchApp/WorkbenchView.swift Sources/WorkbenchApp/StudioComponents.swift Sources/WorkbenchApp/ReadOnlyTextView.swift Sources/WorkbenchApp/TerminalWorkspace.swift Sources/WorkbenchApp/WorkspaceConfigurationSheet.swift Sources/WorkbenchApp/ExecutionViews.swift Sources/WorkbenchApp/CollaborationViews.swift work/studio-render/main.swift -o work/studio-render/render
work/studio-render/render
