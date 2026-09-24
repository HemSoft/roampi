# Saved SSH profiles, format v1

`ConnectionStore` keeps manual connection metadata in `Application Support/RoamPi/connection-profiles.json` inside the iOS app sandbox. The directory is owner-only and the file is owner-readable and writable. Reads do not create the directory. Updates replace the entire versioned JSON file atomically; a malformed file or a newer version blocks edits instead of resetting profiles.

A v1 document contains `version: 1` and a `profiles` array. Each profile holds a local UUID, display name, validated `user@host` string, port, absolute project directory, `terminal` or `nativeRPC` choice, optional validated terminal tmux name, and the opaque `transport-ed25519-v1` device-key reference. The profile limit is 128 records and the file limit is 128 KiB. `ConnectionProfile` revalidates fields after decoding. The store returns fixed diagnostics instead of repeating untrusted values.

The reference names the existing device Ed25519 identity managed by `SecureTransportStore` in Keychain. It is not the key itself. Host-key fingerprints remain in that separate Keychain store and are bound to host and port by `RemoteEndpoint.hostIdentity`; importing or editing a profile does not approve a host key. A changed key must still block before authentication. Pi provider credentials remain on the remote host. Private keys, passwords, tokens, session text, remote commands, and host-key trust decisions are not serialized with profiles.

The store never opens SSH, installs software, or reads a remote `.roampi` file. Use a disposable directory with `ConnectionStore(directoryURL:)` in tests rather than a live tailnet or the device's saved profiles.

## Open Pi from a saved host

1. On a machine you own or are authorized to use, arrange standard SSH and authorize the device Ed25519 public key shown in **SSH hosts**. You can copy it from the device-key section. RoamPi does not install the key or run setup commands. Pi and tmux must already be installed on the host.
2. Tap **Add host**. Enter a label, `user@host` (DNS, IPv4, or bracketed IPv6), optional port, absolute project directory, and a tmux session name. Save. This writes only local profile metadata; Tailscale is optional.
3. Tap **Open**. For an unknown host key, compare the displayed SHA256 fingerprint with an independent trusted source (for example, the host administrator's fingerprint), then type it exactly to approve it. Reject an unfamiliar fingerprint. A changed saved host key blocks SSH before authentication and cannot be approved through this screen.
4. Once the fixed read-only SSH probe succeeds, tap **Open Pi terminal**. This attaches to a matching tmux session or starts Pi in the saved project. **Detach** and **Back to hosts** leave Pi running; **Reconnect** reattaches to the existing session. An offline host or unauthorized device key shows a bounded error instead of starting Pi.

This flow does not check or install prerequisites, enumerate projects or tmux sessions, support password authentication, or read a remote `.roampi` file. Those tasks have separate issues. `--saved-hosts-demo` exercises the UI with a disposable profile store and scripted SSH/terminal; it does not contact a host or use staged credentials. The existing `--install-development-transport-profile` and `--install-development-session-profile` paths remain DEBUG-only.
