# Pi on iOS

## Goal

Build an iPhone and iPad app that connects to Pi installations on machines in a Tailscale network. The app should hide routine SSH, Pi, and tmux setup while preserving explicit approval for remote changes and authentication.

## Product decision

Build a remote client first. Do not try to run Pi inside the iOS sandbox, and do not embed a second Tailscale implementation in the first release.

The first release will use this path:

1. The user installs and signs in to the [Tailscale iOS app](https://tailscale.com/docs/install/ios).
2. iOS routes this app's ordinary network connections through the active Tailscale VPN.
3. The app opens an SSH connection to a MagicDNS hostname or Tailscale IP.
4. The app checks the remote machine, offers an approved bootstrap plan, and stores a connection profile.
5. The user either attaches to a Pi process in tmux or starts a native Pi session over RPC.

This keeps the app small and gives each module a narrow interface:

- `ConnectionStore` saves host profiles and references to Keychain credentials.
- `RemoteHost` connects, verifies host identity, runs readiness checks, and executes approved commands.
- `PiSession` starts, resumes, interrupts, and observes Pi without exposing SSH or JSONL details to the UI.
- `TerminalSession` provides exact terminal and tmux access when a native Pi screen is not enough.

## Known constraints

- An ordinary iOS app cannot silently install, sign in to, or enable another app's VPN. Onboarding can open the [Tailscale iOS instructions](https://tailscale.com/docs/install/ios), detect whether a target is reachable, and explain the remaining action.
- Embedding Tailscale would require a Packet Tunnel Network Extension, Apple entitlement work, tailnet authentication, and substantial networking code. Tailscale's supported embedding library, [tsnet](https://tailscale.com/docs/features/tsnet), targets Go programs and is not the first-release path.
- The app should assume it cannot read the Tailscale app's peer list across the iOS sandbox. Start with manual MagicDNS host profiles. Investigate authenticated machine discovery as a later feature.
- Tailscale provides connectivity, not the remote SSH daemon. The destination still needs standard SSH or [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh).
- iOS can suspend the app in the background. tmux must keep interactive Pi processes alive, and RPC sessions must be resumable after reconnection.
- Codex authentication requires user participation. Pi supports ChatGPT Plus or Pro Codex login and a device-code flow suitable for SSH. The app may present the URL and code, but it must not bypass or impersonate the user.
- Pi requires Node.js 22.19.0 or newer.
- `air` currently has Apple command-line tools and Swift 6.3.3, but not the full Xcode installation selected by `xcode-select`.

## Phase 0: prove the risky parts

- [ ] Install full [Xcode](https://apps.apple.com/us/app/xcode/id497799835) on `air` and select it with `xcode-select`.
- [ ] Choose the app name, bundle identifier, minimum iOS version, repository license, and distribution target.
- [ ] Create a minimal Swift app and run it on a physical iPhone or iPad.
- [ ] With the Tailscale app connected, prove that the test app can resolve a [MagicDNS](https://tailscale.com/docs/features/magicdns) hostname and open TCP port 22.
- [ ] Prove connections over Wi-Fi and cellular, including a DERP-relayed connection.
- [ ] Compare [SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) with [Citadel](https://github.com/orlandos-nl/Citadel) for client authentication, PTY allocation, resize events, keepalives, host-key verification, and async cancellation.
- [ ] Evaluate [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for terminal rendering, selection, Unicode, hardware keyboards, and touch input.
- [ ] Verify standard key-based SSH first. Separately test whether the chosen SSH library interoperates with Tailscale SSH's authentication flow.
- [ ] Start Pi inside tmux, background the app, change networks, reconnect, and confirm that the same process remains usable.
- [ ] Start `pi --mode rpc` over an SSH exec channel and prove LF-delimited JSONL request and response handling.
- [ ] Review the relevant [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) before committing to the terminal and remote-command design.

Exit criterion: one physical iOS device can connect through Tailscale, authenticate with SSH, render a tmux-hosted Pi session, and exchange one Pi RPC prompt.

## Phase 1: project foundation

- [ ] Initialize the Git repository and create an Xcode project with SwiftUI and Swift Testing.
- [ ] Add CI for build, unit tests, formatting, and dependency auditing.
- [ ] Document supported remote systems. Start with macOS and common Linux distributions.
- [ ] Add a small test SSH server fixture for protocol tests. Do not make production tests depend on the live tailnet.
- [ ] Define typed errors for DNS, reachability, host-key mismatch, SSH authentication, remote prerequisites, tmux, Pi, and provider login.

## Phase 2: connection and security model

- [ ] Define a connection profile with display name, hostname, port, username, project directory, Pi session choice, and tmux session name.
- [ ] Generate an Ed25519 SSH key on device and store the private key in Keychain. Prefer Secure Enclave support if the selected SSH library can use it without exporting key material.
- [ ] Support importing an existing key through the document picker. Never place private keys in logs, analytics, app state restoration, or crash metadata.
- [ ] Implement strict host-key verification and a visible first-connection fingerprint confirmation. Treat changed host keys as blocking errors.
- [ ] Add optional Face ID or Touch ID protection for opening saved connections.
- [ ] Redact usernames, hostnames, commands, project paths, tokens, and terminal text from diagnostics by default.
- [ ] Add configurable keepalive and reconnect behavior.

## Phase 3: onboarding and host setup

- [ ] Add a Tailscale readiness screen that checks DNS resolution and port 22 reachability without requesting Tailscale account credentials.
- [ ] Let the user add a host by MagicDNS name, full `*.ts.net` name, or Tailscale IP.
- [ ] Offer a copyable public key and an exact remote command for adding it to `authorized_keys`.
- [ ] Add an advanced option for password authentication only long enough to install the generated public key. Do not save the password unless the user explicitly requests it.
- [ ] Probe the remote operating system, architecture, shell, package manager, SSH mode, Node version, Pi version, tmux version, and writable project directories.
- [ ] Return a readiness report before changing the remote machine.
- [ ] Build an idempotent bootstrap plan for Node.js 22.19 or newer, tmux, Git, and Pi.
- [ ] Show every mutating command and its reason before execution. Require approval, especially for package-manager and `sudo` commands.
- [ ] Do not capture or store a `sudo` password. Use the interactive PTY for any required elevation prompt.
- [ ] Install Pi with the documented command:

  ```bash
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  ```

- [ ] Run `pi`, start `/login`, select ChatGPT Plus or Pro Codex, and expose the device-code URL and code in a native sheet.
- [ ] Confirm that Pi credentials remain on the remote host in `~/.pi/agent/auth.json` and never transit through app logs or analytics.
- [ ] Save the successful readiness snapshot and re-check versions before future upgrades.

## Phase 4: terminal and tmux MVP

- [ ] Open an SSH PTY with the remote `$TERM` and current iOS viewport dimensions.
- [ ] Render the terminal with selection, copy, paste, links, Unicode, and dynamic resize support.
- [ ] Add a mobile key row for Escape, Control, Tab, arrows, Page Up, Page Down, and Pi's common shortcuts.
- [ ] Support hardware keyboard commands without stealing ordinary Pi input.
- [ ] List tmux sessions and show whether each is attached.
- [ ] Create or attach with a safe equivalent of `tmux new-session -A -s <name>`.
- [ ] Let the user set a project directory and launch `pi -c` there.
- [ ] Provide explicit detach, interrupt, reconnect, and close actions. Closing the iOS view must not kill tmux or Pi.
- [ ] Restore the terminal after app suspension, network loss, and Tailscale reconnection.
- [ ] Handle stale SSH channels and tmux sessions without creating duplicate Pi processes.

Exit criterion: a user can configure a host once, tap a project, and return to the same tmux-hosted Pi process after the app or network disappears.

## Phase 5: native Pi interface over RPC

- [ ] Treat terminal mode and native mode as two adapters behind the `PiSession` interface. Keep their transport details out of views.
- [ ] Launch Pi remotely with `pi --mode rpc` in the chosen project directory.
- [ ] Implement strict LF-delimited JSONL framing. Do not use a line reader that also splits Unicode separators.
- [ ] Render streamed assistant text, thinking state, tool calls, tool results, token usage, and errors in SwiftUI.
- [ ] Support submit, steering messages, follow-up messages, interrupt, new session, resume, fork, model selection, and thinking level.
- [ ] Resume by Pi session ID or file after reconnecting.
- [ ] Add a deliberate switch from native mode to a terminal in the same project.
- [ ] Do not claim that RPC mode attaches to an already-running interactive Pi process. Terminal and tmux mode remains the exact-control path.
- [ ] Add compatibility checks so unsupported Pi RPC versions fail with an upgrade instruction instead of malformed behavior.

## Phase 6: machine discovery

- [ ] Confirm whether Tailscale offers an appropriate end-user OAuth flow for read-only device discovery without shipping a client secret.
- [ ] If safe discovery is available, request the smallest scope and store the resulting credential in Keychain.
- [ ] Fetch only the fields required for connection setup, such as machine name, MagicDNS name, Tailscale IP, operating system, and online state.
- [ ] Keep manual profiles available and functional without Tailscale account access.
- [ ] Do not ask users to paste a broad Tailscale API key into the app for the first release.
- [ ] Consider a QR or signed profile exported by a remote helper as an alternative to tailnet-wide machine-list access.

## Phase 7: reliability and testing

- [ ] Unit-test profile validation, command quoting, bootstrap planning, JSONL framing, reconnection state, and redaction.
- [ ] Integration-test SSH key authentication, host-key changes, PTY resize, tmux attach, and Pi RPC against disposable hosts.
- [ ] Test IPv4 Tailscale addresses, MagicDNS short names, full `*.ts.net` names, and offline hosts.
- [ ] Test Wi-Fi to cellular handoff, airplane mode, VPN disable and re-enable, server reboot, and app process termination.
- [ ] Test small iPhone screens, iPad split view, Dynamic Type, VoiceOver, hardware keyboards, and non-English input.
- [ ] Verify that no private key, provider token, terminal content, or remote command output appears in logs or crash reports.
- [ ] Threat-model malicious SSH servers, command injection through profile fields, hostile terminal escape sequences, clipboard leakage, and dependency compromise.

## Phase 8: release work

- [ ] Write a privacy policy that states what remains on device and what reaches remote hosts.
- [ ] Prepare App Store review notes explaining that the app executes code only on user-authorized remote machines.
- [ ] Provide a demo tailnet and disposable SSH host for review if Apple requests one.
- [ ] Add in-app setup help for Tailscale, standard SSH, Tailscale SSH, tmux, Pi, and Codex device login.
- [ ] Add an export and import format for connection profiles that excludes private keys and tokens.
- [ ] Ship through TestFlight before App Store submission.

## Later ideas

- [ ] Optional remote helper that reports Pi versions, projects, tmux sessions, and Pi session metadata through one narrow command interface.
- [ ] Shortcuts actions for opening a saved Pi session.
- [ ] Local notifications when a long-running remote Pi turn finishes, using an explicit remote notification mechanism.
- [ ] Read-only multi-host dashboard for running tmux and Pi sessions.
- [ ] iCloud sync for non-secret profile metadata. Keep keys and provider credentials out unless a separate security design approves synchronization.
- [ ] Embedded Tailscale only if the system-VPN approach proves inadequate and Apple entitlements, licensing, authentication, and maintenance costs are acceptable.

## Definition of done for version 1

- A new user with Tailscale already installed can add a remote macOS or Linux host without entering a public IP.
- The app verifies the SSH host, installs its public key, checks prerequisites, and presents an approved setup plan.
- The app can install or update Pi after explicit approval and guide Codex device login.
- The user can create, attach to, detach from, and reconnect to named tmux-hosted Pi sessions.
- The session survives app suspension and network changes.
- Private keys stay in Keychain, provider credentials stay on the remote host, and logs contain neither.
- The app has a tested path to a native Pi RPC interface without removing full terminal access.

## Primary references

- [Pi documentation](https://github.com/earendil-works/pi)
- [Tailscale iOS installation](https://tailscale.com/docs/install/ios)
- [Tailscale MagicDNS](https://tailscale.com/docs/features/magicdns)
- [Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)
- [Tailscale tsnet](https://tailscale.com/docs/features/tsnet)
- [Apple Network Extension](https://developer.apple.com/documentation/networkextension)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
