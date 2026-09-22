import Foundation
import RoamPiCore

/// Observable bridge between the terminal adapter and its SwiftUI screen.
@MainActor
final class TerminalScreenModel: ObservableObject {
    @Published private(set) var phase: PiSessionPhase = .idle
    @Published private(set) var phaseDetail: String?
    @Published private(set) var identityNote: String?
    @Published private(set) var hasStarted = false

    let session: TerminalSession
    private weak var coordinator: TerminalCoordinator?

    var canReconnect: Bool {
        switch phase {
        case .detached, .disconnected, .failed:
            true
        default:
            false
        }
    }

    var canInterrupt: Bool {
        phase == .attached
    }

    var canDetach: Bool {
        phase == .attached || phase == .interrupted
    }

    init(session: TerminalSession) {
        self.session = session
        session.onPhaseChange = { [weak self] newPhase in
            Task { @MainActor in
                self?.phase = newPhase
                self?.refreshIdentityNote()
            }
        }
        session.onOutput = { [weak self] data in
            Task { @MainActor in
                self?.coordinator?.feed(data)
            }
        }
    }

    /// Binds the SwiftTerm bridge so transport bytes reach the view.
    func attach(coordinator: TerminalCoordinator) {
        self.coordinator = coordinator
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        runStart()
    }

    func sendKey(_ data: Data) {
        Task {
            try? await session.send(data)
        }
    }

    func viewportChanged(columns: Int, rows: Int) {
        try? session.submitViewportSize(columns: columns, rows: rows)
    }

    func interrupt() {
        Task {
            try? await session.interrupt()
        }
    }

    func detach() {
        Task {
            try? await session.detach()
        }
    }

    func reconnect() {
        phaseDetail = nil
        Task {
            try? await session.reconnect()
        }
    }

    func close() {
        Task {
            try? await session.close()
        }
    }

    private func runStart() {
        Task {
            do {
                try await session.start()
            } catch let failure as SessionFailure {
                phaseDetail = failure.diagnostic.userMessage
            } catch let diagnostic as SessionDiagnostic {
                phaseDetail = diagnostic.userMessage
            } catch {
                phaseDetail = SessionDiagnostic.connectionFailed.userMessage
            }
        }
    }

    private func refreshIdentityNote() {
        switch session.lastProcessIdentityUnchanged {
        case .some(true):
            identityNote = "Reconnected to the same tmux session and process."
        case .some(false):
            identityNote = "The remote process identity changed during reconnect."
        case nil:
            identityNote = nil
        }
    }
}
