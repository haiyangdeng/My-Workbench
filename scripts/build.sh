#!/bin/zsh
set -eu
PROJECT_ROOT="${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Users/ocean/Downloads/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Users/ocean/Downloads/Xcode.app/Contents/Developer
fi
cd "$PROJECT_ROOT"
xcrun swift test
xcodebuild -project MyWorkbench.xcodeproj -scheme MyWorkbench -configuration Debug -derivedDataPath .build/xcode build
