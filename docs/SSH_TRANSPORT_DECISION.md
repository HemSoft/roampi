# SSH transport decision

Status: accepted for the Phase 0 proof

## Decision

Use [SwiftNIO SSH 0.15.0](https://github.com/apple/swift-nio-ssh/releases/tag/0.15.0) directly for the bounded transport proof. Keep it behind `SSHProbeTransporting` so a later physical-device result can change the implementation without changing the onboarding model.

The project pins SwiftNIO SSH 0.15.0, SwiftNIO 2.103.0, and Swift Crypto 4.5.2. Swift Package Manager records exact transitive revisions in `Package.resolved`. SwiftNIO SSH uses the [Apache 2.0 license](https://github.com/apple/swift-nio-ssh/blob/0.15.0/LICENSE.txt).

## Comparison

| Requirement | SwiftNIO SSH 0.15.0 | Citadel 0.12.1 |
| --- | --- | --- |
| Authentication | Its public client delegate accepts Ed25519 private-key and `none` offers. RoamPi can try Tailscale SSH `none` once, then a key if the server rejects it. | It has a convenient Ed25519 helper. `none` needs a custom NIOSSH delegate because Citadel's public helpers omit it. |
| Host-key verification | A required server-authentication delegate receives the key before user authentication. RoamPi derives the standard SHA-256 fingerprint and applies its own trust policy. | It has trusted-key and custom-validator APIs. A first-use confirmation still needs app-owned state and UI. |
| Exec channels | Session channels and exec requests are supported, but RoamPi must own channel setup, output limits, exit handling, and cleanup. | `executeCommand` and streaming helpers reduce code. |
| PTY and resize | PTY and window-change events are public protocol operations. RoamPi would need a terminal adapter. | `withPTY` is higher level. Resize still needs validation with the eventual terminal renderer. |
| Keepalive | There is no first-class SSH keepalive API. The proof enables TCP keepalive on the NIO channel. An application heartbeat would need a separate design. | No documented first-class SSH keepalive API was found. Its NIO channel can use socket options. |
| Cancellation | RoamPi can close the parent channel from a Swift task cancellation handler. Child channels then fail and cannot execute again. | Async helpers are easier to call, but cancellation and Citadel's optional automatic reconnect need extra ownership rules to prevent an exec retry. |
| Maintenance | Apple maintains the package. Release 0.15.0 requires Swift 6.1 and supports iOS 13 or newer. | The release is active and targets iOS 17, but 0.12.1 depends on a SwiftNIO SSH fork rather than Apple's package. |
| License | Apache 2.0. | MIT, plus the licenses of its transitive packages. |

## Why this choice

Tailscale SSH interoperability and host identity are the two risks this issue must measure. SwiftNIO SSH exposes both decisions without relying on a wrapper's defaults. It also avoids Citadel 0.12.1's dependency on `Wellz26/swift-nio-ssh` while the proof is deciding a long-term security boundary.

Citadel remains a reasonable fallback if physical testing shows that direct channel ownership costs more than expected. Its command and PTY APIs are useful, but they do not remove RoamPi's trust, Keychain, cancellation, or redaction work.

## Source evidence

- [SwiftNIO SSH feature and platform support](https://github.com/apple/swift-nio-ssh/tree/0.15.0#what-does-swiftnio-ssh-support) covers exec, PTY events, Ed25519, and public-key authentication.
- [`NIOSSHUserAuthenticationOffer.Offer.none`](https://github.com/apple/swift-nio-ssh/blob/3ec281496f28a3b6581afd946b759e2642f5cd8d/Sources/NIOSSH/User%20Authentication/UserAuthenticationMethod.swift#L175-L190) is the protocol offer needed by Tailscale SSH.
- [`SSHClientConfiguration`](https://github.com/apple/swift-nio-ssh/blob/3ec281496f28a3b6581afd946b759e2642f5cd8d/Sources/NIOSSH/SSHClientConfiguration.swift) requires user and server authentication delegates.
- [Citadel's client documentation](https://github.com/orlandos-nl/Citadel/tree/0.12.1#client-usage) documents its command and PTY helpers.
- [Citadel 0.12.1 package dependencies](https://github.com/orlandos-nl/Citadel/blob/ae8562f895de06ccb86fdb1cbb65fd99c8976e12/Package.swift#L16-L25) include the SwiftNIO SSH fork.
- [Citadel's MIT license](https://github.com/orlandos-nl/Citadel/blob/0.12.1/LICENSE) is compatible with RoamPi's MIT license.
