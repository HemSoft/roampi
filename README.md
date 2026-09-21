# RoamPi

RoamPi is an iPhone and iPad client for Pi sessions running on remote macOS and Linux machines. This repository currently contains the application foundation and a network-free demo dashboard. SSH, Tailscale, tmux, and Pi RPC support are tracked as later work.

## Requirements

- macOS with Xcode 27.0 or newer
- iOS 17.0 or newer deployment target
- SwiftFormat 0.63.0 or newer for the formatting check

The project is generated from `project.yml` with XcodeGen 2.46.0. The generated `RoamPi.xcodeproj` is committed so contributors do not need XcodeGen for routine work.

## Setup

```bash
git clone git@github.com:HemSoft/roampi.git
cd roampi
open RoamPi.xcodeproj
```

The app has no third-party runtime dependencies and requires no credentials to build.

## Build and test

Build and run all unit and UI tests on the iPhone 17 simulator:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RoamPi.xcodeproj \
  -scheme RoamPi \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RoamPi.xcodeproj \
  -scheme RoamPi \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  test
```

Run the UI journey on iPad:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RoamPi.xcodeproj \
  -scheme RoamPi \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest' \
  -only-testing:RoamPiUITests \
  test
```

The first foundation validation used Xcode 27.0 beta build 27A5228h with iOS 27.0 on iPhone 17 and iPad Pro 13-inch (M5) simulators. CI selects Xcode 26.6 build 17F113 and its iOS 26.6 runtime. It prints both versions before each test run so failures identify the hosted toolchain.

## Demo mode

Pass `--demo` as a launch argument in the scheme editor to open the deterministic dashboard. It contains only fictional machines, projects, Pi sessions, and jobs. The fixture loads from source and performs no network or file access.

For command-line launches:

```bash
xcrun simctl launch booted com.hemsoft.RoamPi --demo
```

The default launch displays a placeholder until connection onboarding is implemented.

## Formatting and dependency audit

```bash
swiftformat --lint .
./scripts/audit-dependencies.sh
```

Regenerate the Xcode project after changing `project.yml`:

```bash
xcodegen generate
```

Review the generated diff before committing it.

## Release records

- [`CHANGELOG.md`](CHANGELOG.md) records user-visible and developer-experience changes.
- [`docs/APP_STORE.md`](docs/APP_STORE.md) tracks TestFlight and App Store readiness.
- [`PRIVACY.md`](PRIVACY.md) states the current data-handling baseline.
- [`TODO.md`](TODO.md) contains the product phases and open technical proofs.
