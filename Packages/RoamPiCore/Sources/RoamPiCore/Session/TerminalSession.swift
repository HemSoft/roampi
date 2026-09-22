import Foundation

/// Terminal adapter behind `PiSession`. Owns the tmux attach command, resize
/// coalescing, and the reconnect rules that prevent duplicate tmux sessions or
/// duplicate Pi processes.
public final class TerminalSession: @unchecked Sendable, PiSession {
    private struct Resources {
        let channel: (any TerminalChannel)?
        let transport: (any TerminalTransport)?
    }

    private struct ResizeSubmission {
        let decision: ResizeCoalescer.Decision?
        let channel: (any TerminalChannel)?
    }

    private struct PendingResize {
        let size: ResizeCoalescer.Size?
        let channel: (any TerminalChannel)?
    }

    private struct Configuration: Sendable {
        let endpoint: RemoteEndpoint
        let authentication: SSHAuthenticationMode
        let sessionName: TmuxSessionName
        let workingDirectory: RemoteWorkingDirectory
        let scriptedTransport: (any TerminalTransport)?
        let credentials: (any SSHSessionCredentials)?
    }

    private let lock = NSLock()
    private var stateMachine = ReconnectStateMachine()
    private var coalescer = ResizeCoalescer()
    private var transport: (any TerminalTransport)?
    private var channel: (any TerminalChannel)?
    private var deferredResizeTask: Task<Void, Never>?
    private var recordedPaneProcessID: Int32?
    private var processIdentityUnchanged: Bool?
    private var phaseChangeHandler: (@Sendable (PiSessionPhase) -> Void)?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var latestColumns = 80
    private var latestRows = 24
    private let configuration: Configuration
    private let deferredResizeInterval: Duration

    /// Observes session phases as they change. Called from arbitrary threads.
    public var onPhaseChange: (@Sendable (PiSessionPhase) -> Void)? {
        get { lock.withLock { phaseChangeHandler } }
        set { lock.withLock { phaseChangeHandler = newValue } }
    }

    /// Reported after each attach: true when a reconnect verified the same pane
    /// process identity, nil on the first attach, false on a mismatch.
    public var lastProcessIdentityUnchanged: Bool? {
        lock.withLock { processIdentityUnchanged }
    }

    public var phase: PiSessionPhase {
        lock.withLock { stateMachine.phase }
    }

    /// Observes remote terminal bytes as they arrive. Called on any thread.
    public var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    public init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode = .standardKey,
        sessionName: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory,
        transport: (any TerminalTransport)? = nil,
        deferredResizeInterval: Duration = .milliseconds(150)
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            scriptedTransport: transport,
            credentials: nil
        )
        self.deferredResizeInterval = deferredResizeInterval
    }

    init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode = .standardKey,
        sessionName: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory,
        credentials: any SSHSessionCredentials,
        deferredResizeInterval: Duration = .milliseconds(150)
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            scriptedTransport: nil,
            credentials: credentials
        )
        self.deferredResizeInterval = deferredResizeInterval
    }

    public func start() async throws {
        try lock.withLock {
            try stateMachine.beginConnecting()
        }
        publishPhase()
        await attach()
    }

    /// Sends user input bytes through the attached PTY.
    public func send(_ data: Data) async throws {
        let channel: (any TerminalChannel)? = lock.withLock {
            guard stateMachine.phase == .attached || stateMachine.phase == .interrupted else {
                return nil
            }
            return channel
        }
        guard let channel else {
            throw SessionFailure(diagnostic: .notAttached, phase: .attached)
        }
        try await channel.write(data)
    }

    public func interrupt() async throws {
        let channel = try lock.withLock {
            try stateMachine.beginInterrupt()
            return self.channel
        }
        defer {
            lock.withLock { try? stateMachine.endInterrupt() }
            publishPhase()
        }
        guard let channel else {
            throw SessionFailure(diagnostic: .notAttached, phase: .attached)
        }
        try await channel.write(Data([0x03]))
    }

    public func detach() async throws {
        let resources: Resources = try lock.withLock {
            try stateMachine.detach()
            let resources = Resources(channel: channel, transport: transport)
            channel = nil
            transport = nil
            return resources
        }
        publishPhase()
        await resources.channel?.close()
        try await resources.transport?.close()
    }

    public func reconnect() async throws {
        let staleTransport: (any TerminalTransport)? = try lock.withLock {
            try stateMachine.beginReconnect()
            let staleTransport = transport
            transport = nil
            channel = nil
            return staleTransport
        }
        publishPhase()
        try? await staleTransport?.close()
        await attach()
    }

    public func close() async throws {
        let resources: Resources = try lock.withLock {
            try stateMachine.beginClose()
            let resources = Resources(channel: channel, transport: transport)
            channel = nil
            transport = nil
            return resources
        }
        publishPhase()
        await resources.channel?.close()
        try await resources.transport?.close()
        try lock.withLock {
            try stateMachine.markClosed()
        }
        publishPhase()
    }

    /// Feeds one viewport size from the UI. Bounded and coalesced; never
    /// reconnects and never starts another process.
    public func submitViewportSize(columns: Int, rows: Int) throws {
        let submission: ResizeSubmission = lock.withLock {
            latestColumns = columns
            latestRows = rows
            return ResizeSubmission(
                decision: coalescer.submit(columns: columns, rows: rows),
                channel: channel
            )
        }

        guard let resizeDecision = submission.decision else {
            return
        }

        if let now = resizeDecision.sendNow {
            try submission.channel?.requestResize(columns: now.columns, rows: now.rows)
        }

        let interval = deferredResizeInterval
        deferredResizeTask?.cancel()
        deferredResizeTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flushPendingResize()
        }
    }

    private func flushPendingResize() {
        let pending: PendingResize = lock.withLock {
            PendingResize(size: coalescer.flush(), channel: channel)
        }
        guard let size = pending.size, let channel = pending.channel else {
            return
        }
        try? channel.requestResize(columns: size.columns, rows: size.rows)
    }

    /// Runs one attach attempt: connect, allocate the PTY, attach or create the
    /// tmux session, and verify the remote process identity after a reconnect.
    private func attach() async {
        var candidateTransport: (any TerminalTransport)?
        do {
            let transport = makeTransport()

            transport.onOutput = { [weak self] data in
                guard let handler = self?.lock.withLock({ self?.outputHandler }) else {
                    return
                }
                handler(data)
            }
            transport.onClosed = { [weak self] exitStatus in
                self?.handleChannelClosed(exitStatus: exitStatus)
            }

            candidateTransport = transport
            let (initialColumns, initialRows) = lock.withLock {
                (latestColumns, latestRows)
            }
            let opened = try await transport.open(columns: initialColumns, rows: initialRows)

            do {
                try await verifyProcessIdentity(for: transport)

                try lock.withLock {
                    try stateMachine.markAttached()
                    self.transport = transport
                    self.channel = opened
                    coalescer.clearLastSent()
                }
                publishPhase()
            } catch {
                await opened.close()
                try? await transport.close()
                throw error
            }
        } catch is CancellationError {
            try? await candidateTransport?.close()
            markFailure(.cancelled)
        } catch let failure as SessionFailure {
            try? await candidateTransport?.close()
            markFailure(failure.diagnostic)
        } catch let diagnostic as SessionDiagnostic {
            try? await candidateTransport?.close()
            markFailure(diagnostic)
        } catch let transportError as TransportError {
            try? await candidateTransport?.close()
            markFailure(Self.diagnostic(for: transportError))
        } catch {
            try? await candidateTransport?.close()
            markFailure(.connectionFailed)
        }
    }

    private func makeTransport() -> any TerminalTransport {
        if let scripted = configuration.scriptedTransport {
            return scripted
        }
        return SSHPTYTransport(
            endpoint: configuration.endpoint,
            authentication: configuration.authentication,
            sessionName: configuration.sessionName,
            workingDirectory: configuration.workingDirectory,
            credentials: configuration.credentials ?? SecureTransportStore.shared
        )
    }

    private func verifyProcessIdentity(for transport: any TerminalTransport) async throws {
        guard let sshTransport = transport as? SSHPTYTransport else {
            return
        }

        let previous = lock.withLock { recordedPaneProcessID }
        let observed = try await observePaneProcessID(transport: sshTransport)
        guard previous == nil || previous == observed else {
            lock.withLock { processIdentityUnchanged = false }
            throw SessionFailure(
                diagnostic: .processIdentityChanged,
                phase: .failed(.processIdentityChanged)
            )
        }
        lock.withLock {
            recordedPaneProcessID = observed
            if previous != nil {
                processIdentityUnchanged = true
            }
        }
    }

    /// Waits briefly for tmux to expose the attached pane identity. Every SSH
    /// attach records it; reconnects compare against that first observation.
    private func observePaneProcessID(transport: SSHPTYTransport) async throws -> Int32 {
        var attempts = 0
        while attempts < 40 {
            if let paneProcessID = try await transport.paneProcessID() {
                return paneProcessID
            }
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        throw SessionFailure(diagnostic: .commandFailed, phase: .connecting)
    }

    private func handleChannelClosed(exitStatus _: Int32?) {
        lock.withLock {
            guard stateMachine.phase.isConnectedOrRecovering else {
                return
            }
            try? stateMachine.markDisconnected()
            channel = nil
        }
        publishPhase()
    }

    private func markFailure(_ diagnostic: SessionDiagnostic) {
        lock.withLock {
            try? stateMachine.fail(diagnostic)
        }
        publishPhase()
    }

    private func publishPhase() {
        lock.withLock { phaseChangeHandler }?(lock.withLock { stateMachine.phase })
    }

    private static func diagnostic(for transportError: TransportError) -> SessionDiagnostic {
        switch transportError {
        case let .diagnostic(diagnostic):
            sessionDiagnostic(diagnostic)
        case .hostKeyConfirmationRequired:
            .hostKeyChanged
        }
    }

    private static func sessionDiagnostic(_ diagnostic: TransportDiagnostic) -> SessionDiagnostic {
        switch diagnostic {
        case .authenticationFailed:
            .authenticationFailed
        case .cancelled:
            .cancelled
        case .commandFailed:
            .commandFailed
        case .connectionFailed:
            .connectionFailed
        case .duplicateProbe:
            .invalidState
        case .hostKeyChanged:
            .hostKeyChanged
        case .invalidEndpoint:
            .invalidEndpoint
        case .keyUnavailable:
            .keyUnavailable
        case .timedOut:
            .timedOut
        }
    }
}
