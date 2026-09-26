# Product direction

RoamPi is a remote client for Pi on user-authorized macOS and Linux machines. It does not run Pi in the iOS sandbox. Standard SSH works over any route the device can reach; the separately installed Tailscale app is optional. RoamPi does not embed Tailscale or require an account with it.

The [first POC milestone](https://github.com/HemSoft/roampi/milestone/1) defines the live proof, not a release promise. It uses a host where SSH, Node, tmux, Pi, and Pi login are already ready. The user should be able to approve that host once, choose a Pi session, send a harmless prompt, and return to the same tmux pane after leaving the app. GitHub Issues own the tasks and evidence; this document records decisions that should survive a change in issue order.

## Host and session boundaries

- Start with manually entered DNS names or IP addresses. Optional machine discovery must never become a prerequisite for ordinary SSH. iOS cannot read another app's VPN peer list or silently install, sign in to, or enable its VPN. Any future authenticated discovery needs its own least-privilege review; do not ask for a broad tailnet API key.
- A saved profile is not approval to change the remote host. Verify its host key before authentication and block a changed key. Show proposed setup commands before any remote write and require explicit approval. A full new-host setup can follow the POC; it is not hidden inside Connect.
- Interactive Pi stays alive in tmux when iOS suspends. A later native RPC client is a separate session mode, not an attachment to an existing interactive Pi process. The optional Pi extension bridge also cannot be a requirement for the basic terminal path.
- Keep device SSH keys in Keychain and Pi provider credentials on the host. SwiftNIO SSH needs exportable Ed25519 key material for this implementation, so Secure Enclave storage is not available for that key. Codex login requires the user's participation; the app may guide a device-code flow but must not impersonate the user or copy the host's Pi credentials.

See [the session architecture](SESSION_ARCHITECTURE.md) for channel and reconnect rules, [the SSH transport decision](SSH_TRANSPORT_DECISION.md) for the library choice, and [the remote configuration contract](ROAMPI_CONFIGURATION.md) for validated `.roampi` behavior. [App Store decisions](APP_STORE.md) are separate from the POC. The issue tracker, not this document, determines what is complete or next.
