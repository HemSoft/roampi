# Changelog

RoamPi records notable changes here. Releases follow semantic versioning once public distribution begins.

## Unreleased

### Customer-visible changes

- Added version 1 of the declarative `.roampi` machine and project configuration contract, including native pages, data sources, approved actions, durable jobs, deterministic merge rules, and last-known-good recovery.
- Made Tailscale optional: RoamPi's standard SSH path now explicitly accepts any reachable DNS hostname or IP address, with route-neutral setup and failure guidance.
- Added a SwiftTerm terminal screen with SSH PTY input, bounded resize handling, mobile terminal keys, explicit session actions, and tmux-backed reconnect.
- Added a native Pi RPC proof that completes a strict LF-delimited `get_state` exchange without invoking a provider.
- Added an SSH transport proof with `user@host` parsing, optional ports, first-use host fingerprint confirmation, changed-key blocking, Ed25519 authentication, and Tailscale SSH fallback.
- Added the first iPhone and iPad app shell.
- Added a deterministic demo dashboard with fictional machines, projects, Pi sessions, jobs, and connection states.
- Added adaptive compact and regular layouts with system light and dark appearance.

### Developer experience

- Added matching Codable configuration models, bounded diagnostics, project namespace isolation, action trust identities, fictional examples, a schema validator, and CI coverage.
- Selected and pinned SwiftTerm 1.19.0 after evaluating rendering, selection, clipboard behavior, Unicode, input, maintenance, platform support, and licensing.
- Added a shared `PiSession` core, redacted reconnect state model, strict bounded JSONL framing, and disposable SSH integration coverage for PTY resize, tmux process continuity, and RPC failures.
- Added deterministic terminal and RPC UI routes plus debug-only, one-time physical-session profiles.
- Verified on a physical iPhone that a tmux-hosted Pi process survives suspension, forced SSH loss, cellular reconnection, and PTY rotation, and that the strict no-session RPC path completes one bounded state exchange.
- Added an explicit bundle-scoped Keychain entitlement and serialized the shared transport credential store to prevent concurrent device-key generation.
- Selected and pinned SwiftNIO SSH after comparing it with Citadel, and documented physical Wi-Fi, cellular, authentication fallback, cancellation, disconnect, and changed-host-key results.
- Added a guarded one-time debug profile for redacted physical-device UI automation; release builds cannot consume it.
- Added transport tests for endpoint parsing, host-key transitions, authentication fallback, cancellation, duplicate-command prevention, and diagnostic redaction.
- Added Swift Testing unit tests and an isolated UI test target.
- Added public GitHub Actions checks for build, test, Swift formatting, and resolved dependency sources.
- Documented setup, simulator validation, demo launch, formatting, and dependency audit commands.
- Added release, privacy, and licensing records.
