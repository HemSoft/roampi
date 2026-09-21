# SSH physical-device results

This record separates completed local proof from network cases that require a configured test host and direct interaction with the device. It contains no usernames, hostnames, Tailscale addresses, command output, keys, or credentials.

## Test environment

| Component | Recorded version |
| --- | --- |
| Xcode | 27.0, build 27A266a, selected per command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |
| Device | iPhone 17 Pro Max |
| iOS | 27.0, build 24A5418b |
| Tailscale iOS | Not visible through the connected-device app inventory. Record the installed version before network testing. |
| SSH implementation | SwiftNIO SSH 0.15.0 |

The machine's global `xcode-select` still points to Command Line Tools. Validation commands select full Xcode explicitly and do not mutate that machine-wide setting.

## Results

| Case | Result | Evidence |
| --- | --- | --- |
| Build and launch on a physical iPhone | Blocked | The device is connected, but Xcode has no configured Apple account and no development provisioning profile for the app identifier. The build stopped before installation. |
| Parse `user@host` and an optional port | Automated | `TransportFoundationTests` covers MagicDNS-style names, full names, IPv4, bracketed IPv6, custom ports, and invalid input. |
| First-use fingerprint confirmation | Automated and simulator UI | The transport stops before authentication, shows a SHA-256 fingerprint, and reconnects only after approval. |
| Saved key reconnect | Automated policy | Matching fingerprints pass without another prompt. A live reconnect remains pending. |
| Changed host key | Automated policy | A mismatch maps only to a blocking error. A live replaced-key test remains pending. |
| Standard Ed25519 authentication and harmless exec | Pending | Needs a non-production host with the generated public key installed after explicit approval. |
| Tailscale SSH `none` authentication | Pending | Needs a test host with Tailscale SSH enabled and policy access. |
| MagicDNS over Wi-Fi | Pending | Needs an active Tailscale route on the device and an approved test destination. |
| MagicDNS over cellular | Pending | Needs direct device interaction to disable Wi-Fi and repeat the probe. |
| DERP relay | Pending | The available environment has not supplied a way to force or verify a relayed path. Record `tailscale ping` relay evidence without peer identifiers if the tailnet can provide it. |
| Keepalive | Implemented, measurement pending | The client enables TCP `SO_KEEPALIVE`. Measure disconnect detection on the approved test host. |
| Cancellation and disconnect | Automated | Task cancellation closes the parent channel. Coordinator tests prove that only one command can run at a time. |
| Wi-Fi-to-cellular reconnect | Pending | Repeat after the physical network transition and verify one successful remote command per user action. |

## Physical validation procedure

Use a disposable or user-controlled test host. Do not use production data. Installing a public key, enabling Remote Login, enabling Tailscale SSH, or replacing a host key changes the remote host and requires explicit approval before the change.

1. Build and launch RoamPi on the recorded device.
2. Enter a redacted test profile in `user@host` form. Use Advanced only for a non-default port.
3. Compare the displayed fingerprint with a trusted out-of-band value. Approve it only when the values match.
4. Run the standard-key probe on Wi-Fi, then reconnect. Confirm that the second run does not ask for the same fingerprint.
5. Disable Wi-Fi, wait for cellular Tailscale connectivity, and run one probe again.
6. Select "Tailscale SSH, then key" and record whether `none` succeeds or the standard key fallback succeeds.
7. Replace the disposable server host key after approval. Confirm that the next probe blocks before authentication or command execution.
8. Start a probe, cancel it, and repeat during a Wi-Fi-to-cellular transition. Confirm that each tap causes at most one completed command.
9. Record only pass or fail, elapsed time, authentication type, direct or DERP path, and software versions. Do not record endpoint or command details.

Do not mark pending rows complete from API documentation or simulator behavior. They require the observed physical-device result.
