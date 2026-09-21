#!/usr/bin/env bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
destination="platform=iOS Simulator,name=iPhone 17,OS=latest"

xcodebuild -version
xcrun simctl list runtimes
xcodebuild -project RoamPi.xcodeproj -scheme RoamPi -destination "$destination" build
xcodebuild -project RoamPi.xcodeproj -scheme RoamPi -destination "$destination" test
swiftformat --lint .
./scripts/audit-dependencies.sh
