# Saved SSH profiles, format v1

`ConnectionStore` keeps manual connection metadata in `Application Support/RoamPi/connection-profiles.json` inside the iOS app sandbox. The directory is owner-only and the file is owner-readable and writable. Reads do not create the directory. Updates replace the entire versioned JSON file atomically; a malformed file or a newer version blocks edits instead of resetting profiles.

A v1 document contains `version: 1` and a `profiles` array. Each profile holds a local UUID, display name, validated `user@host` string, port, absolute project directory, `terminal` or `nativeRPC` choice, optional validated terminal tmux name, and the opaque `transport-ed25519-v1` device-key reference. The profile limit is 128 records and the file limit is 128 KiB. `ConnectionProfile` revalidates fields after decoding. The store returns fixed diagnostics instead of repeating untrusted values.

The reference names the existing device Ed25519 identity managed by `SecureTransportStore` in Keychain. It is not the key itself. Host-key fingerprints remain in that separate Keychain store and are bound to host and port by `RemoteEndpoint.hostIdentity`; importing or editing a profile does not approve a host key. A changed key must still block before authentication. Pi provider credentials remain on the remote host. Private keys, passwords, tokens, session text, remote commands, and host-key trust decisions are not serialized with profiles.

The store never opens SSH, installs software, or reads a remote `.roampi` file. The host editor and readiness checks belong to later issues. Use a disposable directory with `ConnectionStore(directoryURL:)` in tests rather than a live tailnet or the device's saved profiles.
