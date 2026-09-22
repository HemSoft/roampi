# RoamPi

RoamPi is an iPhone and iPad client for Pi sessions running on remote macOS and Linux machines. This repository contains the application foundation, a network-free demo dashboard, an SSH transport proof, and bounded terminal, tmux reconnect, and Pi RPC vertical slices. Tailscale routing comes from the installed iOS app.

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

The app requires no credentials to build. SwiftTerm, SwiftNIO SSH, SwiftNIO, and Swift Crypto are pinned through Swift Package Manager.

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

Run the disposable macOS SSH integration suite without a tailnet or provider credentials:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project RoamPi.xcodeproj \
  -scheme RoamPiIntegrationTests \
  -destination 'platform=macOS' \
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

The default launch opens the SSH transport proof. It accepts `user@host`, an optional advanced port, and either standard Ed25519 authentication or Tailscale SSH `none` with key fallback. It shows a first-use host fingerprint before authentication and blocks changed keys.

Launch deterministic transport states for simulator and UI-test validation without network access:

```bash
xcrun simctl launch booted com.hemsoft.RoamPi --transport-proof-demo
```

The proof uses one fixed non-mutating command and discards its output after checking the expected response. See [`docs/SSH_TRANSPORT_DECISION.md`](docs/SSH_TRANSPORT_DECISION.md) for the library comparison and [`docs/SSH_PHYSICAL_DEVICE_RESULTS.md`](docs/SSH_PHYSICAL_DEVICE_RESULTS.md) for the physical test matrix.

Launch deterministic terminal and RPC screens without a network connection:

```bash
xcrun simctl launch booted com.hemsoft.RoamPi --terminal-demo
xcrun simctl launch booted com.hemsoft.RoamPi --rpc-demo
```

SwiftTerm findings are in [`docs/SWIFTTERM_EVALUATION.md`](docs/SWIFTTERM_EVALUATION.md). Session ownership, reconnect rules, strict JSONL framing, and security boundaries are in [`docs/SESSION_ARCHITECTURE.md`](docs/SESSION_ARCHITECTURE.md).

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
