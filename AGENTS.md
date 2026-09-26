# AGENTS.md

## Project

RoamPi is an iPhone and iPad client for Pi sessions running on remote macOS and Linux machines. Read [product direction](docs/PRODUCT_DIRECTION.md) and the relevant architecture/security documents before changing those boundaries. Use [GitHub Issues](https://github.com/HemSoft/roampi/issues), not `TODO.md`, for task status and acceptance criteria.

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

## Plan of attack

The [first POC milestone](https://github.com/HemSoft/roampi/milestone/1) and its ordered `poc/` labels are the live plan. Aim for a simple terminal connection to an already prepared, user-authorized host. SSH, Node, tmux, Pi, and Pi login are ready on that host. Do not make remote installation, the optional extension bridge, native RPC conversation screens, tailnet discovery, or TestFlight prerequisites for this proof.

1. [#14](https://github.com/HemSoft/roampi/issues/14): finish saved-host Pi terminal and same-process reconnect. Require an authorized disposable-host smoke on a signed physical device, including a harmless prompt; simulator or earlier transport proofs cannot replace it. Keep an unmerged PR open if that gate fails.
2. [#15](https://github.com/HemSoft/roampi/issues/15): guide reachability, independent host-key verification, and one-time device-key authorization. An already authorized host should go straight to connection.
3. [#19](https://github.com/HemSoft/roampi/issues/19): let the user choose a project and existing tmux Pi session instead of memorizing a name. Prove the complete flow and reconnect on a signed physical device.

[#40](https://github.com/HemSoft/roampi/issues/40) retires the old checklist independently. The versioned `.roampi` contract is already defined in [remote configuration](docs/ROAMPI_CONFIGURATION.md); do not redo it as a POC prerequisite. Everything labeled `after-poc` is deferred unless the live issues change. Before starting work, re-read the milestone, selected issue, linked PRs, and review gates. GitHub state wins over this orientation text if the sequence or status changes.
