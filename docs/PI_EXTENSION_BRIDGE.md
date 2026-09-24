# Pi extension session bridge, protocol v1

This is an opt-in prototype for Pi 0.87.1 or newer on macOS and Linux, with Node.js 22.19.0 or newer. It does not attach to processes that never loaded the extension. It does not replace Pi's session files or the existing tmux path. RPC mode passed a disposable, credential-free Pi integration test on macOS. An interactive Pi process also published a live socket under a disposable macOS PTY. The same disposable PTY and RPC tests run on Linux in CI; their Linux result must be checked on the current pull-request head.

## Installation and approval

Run `node Remote/RoamPiExtension/install.mjs` to print the exact destination and files. After RoamPi has shown the plan and the user has approved changing the remote host, run `node Remote/RoamPiExtension/install.mjs --apply`. This copies three TypeScript files into `<agent-dir>/extensions/roampi/` and does not install dependencies or start a service. Supply `--agent-dir <path>` for a disposable Pi agent directory. Repeating the command skips identical files. Restart Pi or use `/reload`. RoamPi must not run `--apply` without explicit remote-change approval. `PI_CODING_AGENT_DIR` overrides the default `~/.pi/agent` directory.

The source is pinned by repository revision and protocol version. The bridge stores one small JSON metadata record and one Unix socket per Pi process in `<agent-dir>/roampi/`. No second transcript is written. Pi's normal session file is the history source. The registry reports a session file, not a duplicated conversation snapshot.

## Wire format

All requests and responses are strict UTF-8, LF-delimited JSON objects, with `version: 1`, a string `id`, and a `type`. A frame is at most 32768 bytes including its LF. CRLF, empty lines, invalid UTF-8, malformed JSON, unsupported versions, and overlong frames are rejected. A new socket connection is needed after a framing error. Each request yields a `type: "response"` with the same `id`, except invalid version or shape yields a terminal `type: "error"`. Socket responses and asynchronous events can interleave.

| Request | Fields | Result |
| --- | --- | --- |
| `snapshot` | none | Current metadata, last event sequence, and control availability. Read Pi's session file separately for history. |
| `subscribe` | none | Metadata plus future `event` frames, with monotonic `seq`. Reconnect with a new snapshot; missed deltas are not replayed. |
| `acquire` | none | Random lease `token` and 15-second TTL, unless another controller holds it. |
| `renew` | `token` | Extends the control lease another 15 seconds. |
| `release` | `token` | Drops control and cancels any outstanding approval. |
| `prompt` | `token`, `text`, `delivery` | `immediate` while idle, or explicitly `followUp`/`steer` while working. No implicit promotion. Max 16384 UTF-8 bytes. |
| `interrupt` | `token` | Aborts the current turn. |
| `answer` | `token`, `dialogId`, `value` | Answers a cooperative confirmation, selection, or text request. |

Clients without the lease can subscribe and read streamed assistant text, but cannot send prompts or answer dialogs. An approval's title, options, text, and selected value go only to the controller. Observer events contain `waitingForApproval` and completion, never the approval payload. A cooperative extension can call the exported `relayRoamPiDialog(pi, kind, title, detail)` helper from the installed `index.ts` or use Pi's public event bus. For example, a tool can await `new Promise(resolve => pi.events.emit("roampi:dialog:v1", { kind: "confirm", title: "Approve?", detail: "Run the action?", respond: resolve }))`. The bridge answers false or undefined if no subscribed controller is available. The bridge never approves on timeout or disconnect. Ordinary third-party `ctx.ui` dialogs are **not** remotely answerable by this extension: Pi 0.87.1 emits only the kind and title in `ui_prompt_start`, not options or a response channel. Such dialogs still work through their original Pi UI, and observers see only their waiting state. Do not claim arbitrary interactive extension attachment without a future upstream Pi API.

Events use `type: "event"`, `kind` (`session`, `message`, `tool`, `approval`, `model`, `thinkingLevel`, `control`, or `shutdown`), and `seq`. Message events stream bounded text deltas. Tool events send names and completion state, not tool arguments or results. Registry updates follow session, model, thinking level, and state changes. A new session or extension reload replaces the old socket and record. No independent daemon or TCP port exists.

## Security and failure boundary

The Pi user owns the extension and all its data. The runtime directory must be a real owner-only `0700` directory, registry files are `0600`, and socket files are `0600`. Another local process running under that same user account can observe and take control; Unix filesystem mode is not a defense against the same UID. SSH host-key verification and account authorization are RoamPi's responsibility. Do not forward this socket to untrusted users or expose it through TCP. There is no password or provider-token exchange in this protocol.

The registry contains the process PID, OS process start time, per-run UUID, Pi session ID, session path, working directory, name, mode, model, thinking level, and state. Those paths and names are sensitive metadata: do not log them or export the registry. The extension does not persist prompt text, tool arguments, message content, passwords, or provider credentials. Live text delivered over the socket can itself be sensitive; a local observer must be trusted. A controller's lease expires after 15 seconds without renewal; a disconnected client loses its lease within 3 seconds. Approval dialogs time out after 60 seconds with a deny/cancel outcome. There are at most 16 socket clients, a 32 KiB frame limit, a 256 KiB per-client outgoing queue limit, and a 256-entry discovery scan limit. A stalled client is disconnected rather than allowed to exhaust memory. Inputs are bounded, and unsupported requests do not run Pi commands.

Discovery checks the OS process start time and challenges the live socket's per-run identity, not PID alone. A crashed process leaves a stale record until a later discovery ignores it; it never removes the Pi session file. Socket availability is the final attach test. On systems where `ps -o lstart` is unavailable, startup fails closed rather than inventing identity. The socket path must fit the Unix path limit; long agent-directory paths fail closed rather than opening TCP. If Pi shuts down cleanly, the extension removes only its own run's record and socket. Filesystem unlink after a crash can be handled by a future owner-verified janitor; no destructive scan runs in the prototype.

## Validation

`npm ci --prefix Remote/RoamPiExtension && npm run typecheck --prefix Remote/RoamPiExtension && npm test --prefix Remote/RoamPiExtension` runs the protocol, permissions, lease, redaction, lifecycle, and disposable credential-free Pi RPC and interactive PTY integration tests. A read-only discovery test verifies that a missing runtime directory is not created before user approval. This uses a temporary agent directory and scripted provider, not the developer's Pi credentials, session files, or live tailnet.
