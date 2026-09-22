import RoamPiCore
import SwiftTerm
import SwiftUI

/// SwiftUI screen for one tmux-hosted Pi terminal session.
///
/// SwiftTerm renders the remote PTY output; the key row supplies the keys a
/// touch keyboard lacks. SSH, tmux, and framing details stay behind
/// `TerminalSession`.
struct TerminalScreenView: View {
    @StateObject private var model: TerminalScreenModel

    init(model: TerminalScreenModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            SessionPhaseBanner(
                title: "Pi terminal",
                phase: model.phase,
                detail: model.phaseDetail,
                identityNote: model.identityNote
            )
            .accessibilityIdentifier("terminal-phase-banner")

            TerminalRepresentable(model: model)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .frame(maxHeight: .infinity)
                .accessibilityLabel("Pi terminal")
                .accessibilityIdentifier("terminal-view")

            TerminalKeyRow { key in
                model.sendKey(key)
            }
            .accessibilityIdentifier("terminal-key-row")

            HStack(spacing: 12) {
                Button("Reconnect") {
                    model.reconnect()
                }
                .disabled(!model.canReconnect)
                .accessibilityIdentifier("terminal-reconnect")

                Button("Detach") {
                    model.detach()
                }
                .disabled(!model.canDetach)
                .accessibilityIdentifier("terminal-detach")

                Button("Interrupt") {
                    model.interrupt()
                }
                .disabled(!model.canInterrupt)
                .accessibilityIdentifier("terminal-interrupt")

                Button("Close") {
                    model.close()
                }
                .accessibilityIdentifier("terminal-close")
            }
            .buttonStyle(.bordered)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
        .background(Color.black)
        .task {
            model.startIfNeeded()
        }
    }
}

/// Compact banner showing the distinct session phase and bounded diagnostic.
struct SessionPhaseBanner: View {
    let title: String
    let phase: PiSessionPhase
    let detail: String?
    var identityNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            HStack(spacing: 8) {
                Text(phase.userLabel)
                    .font(.subheadline)
                    .accessibilityIdentifier("session-phase-label")
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let identityNote {
                Text(identityNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("session-identity-note")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
        .foregroundStyle(.white)
    }
}

/// The SwiftTerm view bridge. The model keeps the delegate methods and feeds
/// transport bytes into the terminal; terminal-specific code lives here only.
struct TerminalRepresentable: UIViewRepresentable {
    @ObservedObject var model: TerminalScreenModel

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator()
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.bind(model: model, view: view)
        return view
    }

    func updateUIView(_: TerminalView, context _: Context) {}
}

/// Bridge between SwiftTerm callbacks and the session model.
private final class OrderedMainActorDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock {
            let predecessor = tail
            tail = Task {
                await predecessor?.value
                await operation()
            }
        }
    }
}

final class TerminalCoordinator: NSObject, TerminalViewDelegate {
    private let inputDispatcher = OrderedMainActorDispatcher()
    private let viewportDispatcher = OrderedMainActorDispatcher()
    private weak var model: TerminalScreenModel?
    private weak var terminalView: TerminalView?

    @MainActor
    func bind(model: TerminalScreenModel, view: TerminalView) {
        self.model = model
        terminalView = view
        model.attach(coordinator: self)
    }

    @MainActor
    func feed(_ data: Data) {
        terminalView?.feed(byteArray: ArraySlice(data))
    }

    // MARK: TerminalViewDelegate

    func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        inputDispatcher.enqueue { [weak model] in
            model?.sendKey(bytes)
        }
    }

    func sizeChanged(source _: TerminalView, newCols: Int, newRows: Int) {
        viewportDispatcher.enqueue { [weak model] in
            model?.viewportChanged(columns: newCols, rows: newRows)
        }
    }

    func setTerminalTitle(source _: TerminalView, title _: String) {}

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    func scrolled(source _: TerminalView, position _: Double) {}

    func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
        guard let url = URL(string: link) else { return }
        Task { @MainActor in
            await UIApplication.shared.open(url)
        }
    }

    func bell(source _: TerminalView) {}

    func clipboardCopy(source _: TerminalView, content _: Data) {
        // Deny remote OSC 52 clipboard writes. User-initiated selection copy
        // and paste continue to use SwiftTerm's native edit menu.
    }

    func clipboardRead(source _: TerminalView) -> Data? {
        // Deny remote clipboard reads; SwiftTerm defaults to denial as well.
        nil
    }

    func iTermContent(source _: TerminalView, content _: ArraySlice<UInt8>) {}

    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
}

/// The key row: Escape, Control, Tab, arrows, Page Up, Page Down.
struct TerminalKeyRow: View {
    enum Key: String, CaseIterable, Identifiable {
        case escape = "esc"
        case control = "ctrl"
        case tab
        case up = "↑"
        case down = "↓"
        case left = "←"
        case right = "→"
        case pageUp = "pgup"
        case pageDown = "pgdn"

        var id: String {
            rawValue
        }

        var bytes: Data {
            switch self {
            case .escape:
                Data([0x1B])
            case .control:
                Data([0x03])
            case .tab:
                Data([0x09])
            case .up:
                Data([0x1B, 0x5B, 0x41])
            case .down:
                Data([0x1B, 0x5B, 0x42])
            case .left:
                Data([0x1B, 0x5B, 0x44])
            case .right:
                Data([0x1B, 0x5B, 0x43])
            case .pageUp:
                Data([0x1B, 0x5B, 0x35, 0x7E])
            case .pageDown:
                Data([0x1B, 0x5B, 0x36, 0x7E])
            }
        }
    }

    let onKey: (Data) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Key.allCases) { key in
                    Button(key.rawValue) {
                        onKey(key.bytes)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("key-\(key.rawValue)")
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 44)
    }
}
