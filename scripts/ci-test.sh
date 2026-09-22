#!/usr/bin/env bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
destination="platform=iOS Simulator,name=iPhone 17,OS=latest"

xcodebuild -version
xcrun simctl list runtimes
./scripts/audit-dependencies.sh
xcodebuild -resolvePackageDependencies -skipPackagePluginValidation -disableAutomaticPackageResolution -project RoamPi.xcodeproj -scheme RoamPi
xcodebuild -skipPackagePluginValidation -disableAutomaticPackageResolution -project RoamPi.xcodeproj -scheme RoamPi -destination "$destination" build
xcodebuild -skipPackagePluginValidation -disableAutomaticPackageResolution -project RoamPi.xcodeproj -scheme RoamPi -destination "$destination" test
xcodebuild -skipPackagePluginValidation -disableAutomaticPackageResolution -project RoamPi.xcodeproj -scheme RoamPiIntegrationTests -destination 'platform=macOS' test
swiftformat --lint .
