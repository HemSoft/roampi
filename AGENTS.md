# AGENTS.md

## Project

RoamPi is an iPhone and iPad client for Pi sessions running on remote macOS and Linux machines. Read `TODO.md` before making architectural or security decisions.

## First-release architecture

- Connect to user-authorized hosts over standard SSH using any reachable DNS hostname or IP address.
- Treat the installed Tailscale iOS app as an optional private network route. Do not embed Tailscale or require it for core functionality.
- Start onboarding with manual SSH host profiles. Optional tailnet discovery may add machines later.
- Show each selected machine's availability, projects, and active Pi sessions.
- Read an optional `.roampi` file from each host. It may define the machine name, projects, global UI behavior, and project-specific prompt or command shortcuts.
- Keep terminal and native RPC modes behind a shared `PiSession` interface.
- Use tmux to keep interactive Pi sessions alive across app suspension and network changes.
- Keep SSH details in `RemoteHost`, saved profiles in `ConnectionStore`, and terminal behavior in `TerminalSession`.

## Security rules

- Require explicit user approval before changing a remote host.
- Treat remote `.roampi` files as untrusted input. Validate their schema and require confirmation before a configured action makes changes.
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

Phase 0 in `TODO.md` is complete. Preserve route-neutral standard SSH, with Tailscale as an optional route. Define the versioned `.roampi` contract before building dashboard configuration or action execution.
