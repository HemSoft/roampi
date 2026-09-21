# Changelog

RoamPi records notable changes here. Releases follow semantic versioning once public distribution begins.

## Unreleased

### Customer-visible changes

- Added an SSH transport proof with `user@host` parsing, optional ports, first-use host fingerprint confirmation, changed-key blocking, Ed25519 authentication, and Tailscale SSH fallback.
- Added the first iPhone and iPad app shell.
- Added a deterministic demo dashboard with fictional machines, projects, Pi sessions, jobs, and connection states.
- Added adaptive compact and regular layouts with system light and dark appearance.

### Developer experience

- Selected and pinned SwiftNIO SSH after comparing it with Citadel, and documented the physical-device validation matrix.
- Added transport tests for endpoint parsing, host-key transitions, authentication fallback, cancellation, duplicate-command prevention, and diagnostic redaction.
- Added Swift Testing unit tests and an isolated UI test target.
- Added public GitHub Actions checks for build, test, Swift formatting, and resolved dependency sources.
- Documented setup, simulator validation, demo launch, formatting, and dependency audit commands.
- Added release, privacy, and licensing records.
