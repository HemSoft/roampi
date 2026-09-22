# Terminal, tmux, and RPC architecture

## Module boundary

`RoamPiCore` owns session state, SSH channels, tmux commands, argument validation, resize coalescing, and JSONL framing. SwiftUI observes a `PiSession` phase and invokes session actions; views do not receive SSH channels, remote commands, private keys, or decoded JSON objects.

The two adapters are:

- `TerminalSession`: opens one SSH PTY, attaches a SwiftTerm view, and uses tmux for server-side lifetime.
- `RPCSession`: opens one SSH exec channel, starts `pi --mode rpc --no-session`, and exchanges bounded typed frames.

`TerminalTransport` and `RPCTransport` allow deterministic UI demos and disposable integration fixtures without weakening the production interface.

## Process ownership and reconnect rules

The iOS app owns SSH connections and channels. The remote host owns tmux and Pi processes.

A terminal attach runs the validated equivalent of:

```text
cd '<approved-directory>' && exec tmux new-session -A -s '<approved-name>'
```

Session names accept only letters, numbers, underscores, dots, and dashes, with a safe first character and a 64-byte limit. Working directories must be absolute, contain no traversal components or control characters, use a restricted character set, and fit within 256 bytes. Every remote value is then POSIX single-quoted.

On the first SSH attach, `TerminalSession` records tmux's `pane_pid`. A reconnect uses the same `new-session -A` command, reads `pane_pid` again, and proceeds only if it matches. A mismatch closes the new channel and moves to a bounded failure state. tmux therefore prevents a second named session, while the process-identity check prevents a changed process from being reported as a successful resume.

Detach and close end the iOS-side PTY and SSH connection. They do not send `tmux kill-session`, terminate Pi, or delete remote state. The app does not expect continuous execution while backgrounded: iOS may suspend it. tmux is the continuity mechanism, and reconnect is explicit after suspension or transport loss.

## PTY behavior

The SSH session requests a PTY with terminal type `xterm-256color` and the current column and row counts before executing tmux. Viewport updates are clamped to 2–500 columns and 1–500 rows. The first update is sent immediately; a short coalescing window retains only the newest later size. Resize requests use the existing SSH child channel and do not reconnect or execute another command.

Terminal input is byte-oriented. The system keyboard and hardware keyboard feed SwiftTerm, and the mobile row supplies Escape, Control-C, Tab, arrows, Page Up, and Page Down.

## RPC framing

RPC mode starts `pi --mode rpc --no-session` in an approved directory. `--no-session` keeps the bounded proof out of the user's Pi session history. The startup proof sends `get_state`; it does not submit a prompt or invoke a model provider.

Inbound framing:

- splits only on LF (`0x0A`);
- tolerates one CR only as part of a CRLF ending and rejects all other raw CR bytes;
- never treats U+2028 or U+2029 as record delimiters;
- requires each record to be a JSON object;
- limits a complete or partial frame to 1 MiB;
- rejects malformed JSON and an unterminated final record;
- stops the channel and fails pending requests after a protocol error.

Responses are correlated by request ID. Duplicate pending identifiers are rejected, and each response wait has a 30-second deadline. Every reopened RPC stream starts with a fresh decoder and per-exchange counters. Event frames can arrive alongside responses and are counted separately. Prompt and response contents are not logged or included in diagnostics.

## Security boundaries

- SSH private keys are generated and retained by the Keychain-backed `SecureTransportStore`.
- Host keys are pinned per endpoint. A changed key blocks before user authentication.
- Provider credentials remain on the remote host. RoamPi does not read, copy, or bypass Pi provider authentication.
- Diagnostics are closed enums with fixed messages. They never interpolate usernames, hostnames, addresses, paths, commands, terminal output, prompts, keys, or tokens.
- SwiftTerm handles an untrusted terminal byte stream. Remote OSC 52 clipboard reads and writes are denied.
- The physical validation profile is `DEBUG`-only, size-limited, deleted at launch, and accepts exactly one independently staged host fingerprint. It can export only the device public key for temporary authorization.
- Integration tests use a user-level disposable SSH daemon, generated host and client keys, a temporary working directory, a stub RPC executable, uniquely named tmux sessions, and a fixture-private tmux socket. They do not use the live tailnet, the developer's tmux server, or a user's Pi state.

## Unsupported or deferred cases

- Native RPC sessions are not yet resumable by Pi session ID or file. RPC mode is a bounded exchange proof, not the full native client.
- RPC mode does not attach to an already-running interactive Pi process.
- The terminal screen does not list existing tmux sessions or launch `pi -c`; those remain MVP work.
- True Tailscale SSH `none` acceptance and a forced DERP path remain unverified environment limitations. Standard Ed25519 SSH over the Tailscale route is the verified path.
- Automatic terminal Dynamic Type scaling, full VoiceOver behavior, non-English input, and the hardware-keyboard matrix remain Phase 7 work.
