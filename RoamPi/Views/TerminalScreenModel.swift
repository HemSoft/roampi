import Foundation
import RoamPiCore

private final class TerminalOutputOverflowGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }

    func reset() {
        lock.withLock { claimed = false }
    }
}

/// Observable bridge between the terminal adapter and its SwiftUI screen.
@MainActor
final class TerminalScreenModel: ObservableObject {
    @Published private(set) var phase: PiSessionPhase = .idle
    @Published private(set) var phaseDetail: String?
    @Published private(set) var identityNote: String?
    @Published private(set) var hasStarted = false

    let session: TerminalSession
    private weak var coordinator: TerminalCoordinator?
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let outputOverflowGate = TerminalOutputOverflowGate()
    private var outputTask: Task<Void, Never>?

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
        let (outputStream, outputContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(64)
        )
        self.session = session
        self.outputContinuation = outputContinuation
        outputTask = Task { @MainActor [weak self] in
            for await data in outputStream {
                guard !Task.isCancelled else { return }
                self?.coordinator?.feed(data)
            }
        }
        session.onPhaseChange = { [weak self] newPhase in
            Task { @MainActor in
                guard let self, self.session.phase == newPhase else { return }
                self.phase = newPhase
                if case let .failed(diagnostic) = newPhase {
                    self.phaseDetail = diagnostic.userMessage
                }
                self.refreshIdentityNote()
            }
        }
        session.onOutput = { [weak self] data in
            for offset in stride(from: 0, to: data.count, by: 64 * 1024) {
                let end = min(offset + 64 * 1024, data.count)
                let boundedChunk = data.subdata(in: offset ..< end)
                switch outputContinuation.yield(boundedChunk) {
                case .enqueued:
                    continue
                case .dropped:
                    guard self?.outputOverflowGate.claim() == true else { return }
                    Task { @MainActor [weak self] in
                        self?.phaseDetail = "Terminal output exceeded the local display buffer."
                        try? await self?.session.detach()
                    }
                    return
                case .terminated:
                    return
                @unknown default:
                    return
                }
            }
        }
    }

    deinit {
        outputContinuation.finish()
        outputTask?.cancel()
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
        outputOverflowGate.reset()
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
