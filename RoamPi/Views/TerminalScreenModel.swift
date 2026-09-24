import Foundation
import RoamPiCore

private final class TerminalBufferOverflowGate: @unchecked Sendable {
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
final class TerminalScreenModel: ObservableObject, Identifiable {
    @Published private(set) var phase: PiSessionPhase = .idle
    @Published private(set) var phaseDetail: String?
    @Published private(set) var identityNote: String?
    @Published private(set) var hasStarted = false
    @Published private(set) var controlModifierArmed = false

    let session: TerminalSession
    private weak var coordinator: TerminalCoordinator?
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let outputOverflowGate = TerminalBufferOverflowGate()
    private let inputOverflowGate = TerminalBufferOverflowGate()
    private var outputTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?

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
        let (inputStream, inputContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        self.session = session
        self.outputContinuation = outputContinuation
        self.inputContinuation = inputContinuation
        outputTask = Task { @MainActor [weak self] in
            for await data in outputStream {
                guard !Task.isCancelled else { return }
                self?.coordinator?.feed(data)
            }
        }
        inputTask = Task { @MainActor [weak self] in
            for await data in inputStream {
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.session.send(data)
                } catch {
                    self.phaseDetail = "Terminal input could not be sent."
                }
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
        inputContinuation.finish()
        outputTask?.cancel()
        inputTask?.cancel()
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

    func toggleControlModifier() {
        controlModifierArmed.toggle()
    }

    func sendKey(_ data: Data) {
        let outgoingData: Data
        if controlModifierArmed,
           let controlledData = Self.applyingControlModifier(to: data)
        {
            controlModifierArmed = false
            outgoingData = controlledData
        } else {
            outgoingData = data
        }
        for offset in stride(from: 0, to: outgoingData.count, by: 64 * 1024) {
            let end = min(offset + 64 * 1024, outgoingData.count)
            switch inputContinuation.yield(outgoingData.subdata(in: offset ..< end)) {
            case .enqueued:
                continue
            case .dropped:
                guard inputOverflowGate.claim() else { return }
                phaseDetail = "Terminal input exceeded the local send buffer."
                detach()
                return
            case .terminated:
                return
            @unknown default:
                return
            }
        }
    }

    static func applyingControlModifier(to data: Data) -> Data? {
        guard data.count == 1, let byte = data.first else { return nil }
        let controlByte: UInt8? = switch byte {
        case 0x20:
            0x00
        case 0x3F:
            0x7F
        case 0x40 ... 0x5F, 0x60 ... 0x7A:
            byte & 0x1F
        default:
            nil
        }
        return controlByte.map { Data([$0]) }
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
        inputOverflowGate.reset()
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
