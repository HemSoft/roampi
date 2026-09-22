# SwiftTerm evaluation

## Decision

RoamPi uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.19.0 for terminal rendering. The exact release is pinned in `project.yml` and `Package.resolved`. SwiftTerm is MIT licensed, permits commercial distribution, and declares iOS 14 or newer; RoamPi requires iOS 17 or newer.

The evaluated release was tagged on 2026-08-18. Its repository includes current UIKit, CoreText, Unicode, selection, keyboard, link, and optional Metal implementations. RoamPi keeps SwiftTerm in `TerminalScreenView`; SSH, PTY, tmux, resize, and reconnect behavior remains behind `TerminalSession`.

## Evaluation matrix

| Area | Finding | RoamPi treatment |
| --- | --- | --- |
| Rendering | `TerminalView` renders terminal buffers with CoreText and optionally Metal. It supports color, scrollback, cursor state, and standard terminal escape sequences. | Remote PTY bytes are fed directly to one `TerminalView`. SwiftTerm never owns the SSH connection or remote process. |
| Selection | The UIKit view has touch selection, selection handles, word selection, select all, and selected-text extraction. | Native selection remains enabled. Streaming output does not expose selected text to app logs or state restoration. |
| Copy and paste | The UIKit edit menu implements user-initiated copy and paste through `UIPasteboard`. The delegate also exposes OSC 52 clipboard callbacks. | User-initiated copy and paste remain available. RoamPi denies remote OSC 52 reads and writes, so an untrusted remote process cannot inspect or replace the device clipboard. |
| Unicode | The engine documents UTF, grapheme-cluster, emoji, combining-character, wide-character, bidirectional-text, and hardened Unicode rendering coverage. | UTF-8 PTY bytes remain byte-preserving between SSH and SwiftTerm. Physical validation uses rendered terminal output without retaining its contents. |
| Dynamic Type | Terminal cells use a monospaced terminal font and do not automatically follow SwiftUI Dynamic Type categories. Automatic scaling would also alter PTY geometry. | Surrounding controls use Dynamic Type. Terminal font scaling remains a later explicit preference coupled to a bounded PTY resize; RoamPi does not claim automatic terminal Dynamic Type support. |
| Touch input | The UIKit implementation supports taps, pans, scrolling, selection gestures, links, and the system software keyboard. | RoamPi adds a horizontal mobile key row for Escape, Control-C, Tab, arrows, Page Up, and Page Down. |
| Hardware keyboards | `TerminalView` implements UIKit text input and key handling, including terminal key encoding. | SwiftTerm receives ordinary hardware-key input. RoamPi does not register global shortcuts that would steal normal Pi input. Hardware-keyboard edge cases remain part of broader device testing. |
| Links | SwiftTerm reports links through its delegate instead of opening arbitrary content itself on iOS. | RoamPi accepts only strings that parse as URLs and hands them to the system opener. A future security review may narrow allowed schemes before release. |
| Maintenance | Version 1.19.0 is a current tagged release, uses Swift tools 6.0, and includes UIKit and modern rendering work. | The dependency remains exact-pinned. Updates require dependency audit, terminal regression tests, and a license review. |
| Minimum iOS | SwiftTerm declares iOS 14. | Compatible with RoamPi's iOS 17 deployment target. |
| License | MIT, including upstream xterm.js-derived notices. | Compatible with RoamPi's MIT repository and intended commercial distribution. The dependency copyright and license must be included in shipped notices. |

## Risks and boundaries

- A terminal renderer processes hostile escape sequences. SwiftTerm is treated as a security-sensitive dependency and remains exact-pinned.
- Remote clipboard OSC 52 access is denied. Explicit user copy and paste is still possible and may transfer terminal text or clipboard text by user choice.
- Link opening and future file-transfer escape sequences require separate review before release.
- Terminal font scaling, VoiceOver behavior inside the terminal grid, complex input methods, and the full hardware-keyboard matrix need broader Phase 7 testing.
- SwiftTerm's build includes a package plugin and Metal shader resource. CI skips interactive package-plugin approval while retaining exact dependency resolution and public-source auditing.
