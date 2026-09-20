# AGENTS.md

## Project

RoamPi is an iPhone and iPad client for Pi sessions running on remote macOS and Linux machines. Read `TODO.md` before making architectural or security decisions.

## First-release architecture

- Use the installed Tailscale iOS app for network routing. Do not embed Tailscale.
- Connect to remote hosts over SSH by MagicDNS name or Tailscale IP.
- Keep terminal and native RPC modes behind a shared `PiSession` interface.
- Use tmux to keep interactive Pi sessions alive across app suspension and network changes.
- Keep SSH details in `RemoteHost`, saved profiles in `ConnectionStore`, and terminal behavior in `TerminalSession`.

## Security rules

- Require explicit user approval before changing a remote host.
- Verify SSH host keys. Treat a changed key as a blocking error.
- Store private keys and app credentials in Keychain.
- Keep Pi provider credentials on the remote host.
- Never log private keys, tokens, passwords, terminal contents, remote commands, hostnames, usernames, or project paths.
- Never capture or store a `sudo` password.
- Do not bypass Codex login or other user authentication.

## Development rules

- Build the app with SwiftUI and Swift Testing.
- Support Node.js 22.19.0 or newer on remote hosts.
- Use strict LF-delimited JSONL framing for Pi RPC.
- Quote all remote command arguments and test profile fields for command injection.
- Make bootstrap operations idempotent and show each mutating command before execution.
- Keep production tests independent of the live tailnet. Use a disposable SSH fixture for protocol tests.
- Cover reconnection, host-key changes, PTY resizing, tmux attachment, RPC framing, and secret redaction with tests.

## Current priority

Work through Phase 0 in `TODO.md` before building the full product. Prove physical-device Tailscale connectivity, SSH and tmux behavior, terminal rendering, and one Pi RPC exchange first.
