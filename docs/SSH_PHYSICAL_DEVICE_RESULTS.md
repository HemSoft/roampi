# SSH physical-device results

This record separates automated checks from observations made on a physical device. It contains no usernames, hostnames, Tailscale addresses, device identifiers, signing identifiers, commands, keys, fingerprints, credentials, or remote output.

## Test environment

| Component | Recorded version |
| --- | --- |
| Validation date | 2026-09-22 |
| Xcode | 27.0, build 27A266a, selected per command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| Device | iPhone 17 Pro Max |
| iOS | 27.0, build 24A5418b |
| Tailscale iOS | 8.15.0, build 96 |
| SSH implementation | SwiftNIO SSH 0.15.0 |

The machine's global `xcode-select` still points to Command Line Tools. Validation commands selected full Xcode explicitly and did not mutate that machine-wide setting. Device builds used an isolated signing keychain and API-created development provisioning; every temporary signing resource was deleted after validation, and signing values were not added to the repository or logs.

## Results

| Case | Result | Physical or automated evidence |
| --- | --- | --- |
| Build and launch on a physical iPhone | Pass | The signed debug app was installed and launched with `devicectl`; Xcode then ran targeted UI tests on the same device. |
| Parse `user@host` and an optional port | Pass | `TransportFoundationTests` covers MagicDNS-style names, full names, IPv4, bracketed IPv6, custom ports, and invalid input. |
| First-use fingerprint confirmation | Pass | A private one-time debug profile supplied independently calculated expected fingerprints. The physical app exposed the presented SHA-256 fingerprint and enabled approval only for an expected value. The profile was deleted immediately after launch. |
| Saved-key reconnect | Pass | Later Wi-Fi, cellular, and return-to-Wi-Fi probes reused the endpoint-bound pin without another confirmation prompt. |
| Changed host key | Pass | A disposable user-level SSH server was restarted on the same high port with a replacement host key. RoamPi displayed the blocking changed-key error before authentication. The fixture's command count remained unchanged. |
| Standard Ed25519 authentication and harmless exec | Pass | After explicit approval to install the device public key, the physical app authenticated and retained `probe-passed`. The authorized-key fixture was removed after testing. |
| Tailscale SSH `none` authentication | Fallback measured | Standard OpenSSH rejected `none`; RoamPi waited for that result, offered Ed25519, authenticated, and retained `none-rejected-standard-key-fallback-passed`. True Tailscale SSH `none` was not enabled on the user-controlled host, so it was not claimed as demonstrated. |
| MagicDNS over Wi-Fi | Pass | The physical app resolved the staged MagicDNS endpoint, verified the host, authenticated, and completed one harmless command. |
| MagicDNS over cellular | Pass | With Xcode attached over a wired developer connection, the UI test disabled Wi-Fi, waited five seconds, and retained `probe-passed-over-cellular`. It restored Wi-Fi in a teardown path. |
| DERP relay | Environment limitation recorded | Tailscale ping checks found two online iOS peers and observed direct paths for both. The current tailnet supplied no safe way to force or independently verify a DERP route, so no DERP success is claimed. |
| Keepalive and active disconnect | Partial pass with limitation | The client enabled TCP `SO_KEEPALIVE`. A disposable server was terminated after accepting the second probe; RoamPi stopped without reporting success and retained `active-connection-stopped-without-success`. Packet-level keepalive timing was not independently observable on iOS. The 30-second operation deadline remains the upper bound for a silent stall. |
| Pending-connection cancellation | Pass | A physical probe to an unused Tailscale-routed address was cancelled from the UI and retained `pending-connection-cancelled`. |
| Wi-Fi-to-cellular transition and reconnect | Pass | A first wireless-Xcode attempt correctly severed the test harness when Wi-Fi was disabled and produced no network claim. After attaching Xcode over the wired transport, the cellular probe passed. Wi-Fi was restored; the immediate return probe's command channel stopped during the handoff, and a stable-route retry passed without another fingerprint prompt. |
| Duplicate-command prevention | Pass | The coordinator rejects concurrent probes. The disposable fixture counted exactly one command for its successful probe and one for the deliberately disconnected probe; changed-key validation added none. |
| SwiftTerm PTY rendering and input controls | Pass | The physical app rendered a live SSH PTY and exposed text input plus Escape, Control, Tab, arrows, Page Up, and Page Down. The terminal-content region was excluded from retained evidence. |
| tmux-hosted Pi suspension and reconnect | Pass | A disposable tmux pane was started with Pi as its direct process. Its redacted PID remained unchanged across app suspension, forced SSH loss, and a fresh physical-app attachment. No duplicate Pi process was created. |
| Wi-Fi-to-cellular tmux reconnect | Pass | Wired XCTest automation disabled Wi-Fi, waited on cellular routing, reattached the same tmux pane, and displayed the same-process confirmation. Wi-Fi was restored in teardown. |
| Live PTY resize | Pass | Physical orientation changed the tmux pane dimensions while the recorded Pi PID remained unchanged. |
| Strict Pi RPC exchange | Pass | A separate one-use profile opened the real no-session RPC adapter. The physical UI recorded one response frame and zero event frames without invoking a provider or retaining response content. |

## Physical test controls

The physical automation uses debug-only handoffs:

- The transport profile activates only with `--install-development-transport-profile`; the session profile uses a separate launch argument.
- Each profile is size-limited, read from the app's private cache container, validated, and deleted immediately.
- The session profile accepts exactly one independently staged host fingerprint and selects either terminal or RPC mode.
- The transport proof displays a masked endpoint so UI-test output cannot reveal private network data.
- Automated fingerprint approval is permitted only when the presented value matches the independently staged fingerprint.
- A dedicated debug launch argument can export only the generated public key to the private cache container for approved fixture setup.
- Release builds cannot consume either profile or export the key.

The public-key handoff, tagged authorization entry, disposable tmux/Pi session, test directory, private profiles, debug app, signing keychain, provisioning profiles, certificate, bundle records, raw terminal capture, and build products were removed after validation. User tmux sessions and Pi history were not modified.

## Remaining limitation

A DERP-relayed app connection and true Tailscale SSH `none` acceptance remain unverified because the current environment could neither force a DERP path nor provide an approved Tailscale SSH server/policy. The tested standard-SSH fallback succeeds after `none` rejection. These are recorded limitations rather than inferred passes.
