import Foundation

/// Terminal adapter behind `PiSession`. Owns the tmux attach command, resize
/// coalescing, and the reconnect rules that prevent duplicate tmux sessions or
/// duplicate Pi processes.
public final class TerminalSession: @unchecked Sendable, PiSession {
    struct Resources {
        let channel: TerminalChannelBox?
        let transport: TerminalTransportBox?
    }

    struct ResizeSubmission {
        let decision: ResizeCoalescer.Decision?
        let channel: TerminalChannelBox?
    }

    struct PendingResize {
        let size: ResizeCoalescer.Size?
        let channel: TerminalChannelBox?
    }

    struct Configuration: Sendable {
        let endpoint: RemoteEndpoint
        let authentication: SSHAuthenticationMode
        let sessionName: TmuxSessionName
        let workingDirectory: RemoteWorkingDirectory
        let scriptedTransport: TerminalTransportBox?
        let credentials: (any SSHSessionCredentials)?
        let paneCommand: String
    }

    let lock = NSLock()
    var stateMachine = ReconnectStateMachine()
    var attachmentGeneration: UInt64 = 0
    var coalescer = ResizeCoalescer()
    var transport: TerminalTransportBox?
    var channel: TerminalChannelBox?
    var deferredResizeTask: Task<Void, Never>?
    var recordedPaneIdentity: TmuxPaneIdentity?
    var processIdentityUnchanged: Bool?
    var phaseChangeHandler: (@Sendable (PiSessionPhase) -> Void)?
    var outputHandler: (@Sendable (Data) -> Void)?
    var latestColumns = 80
    var latestRows = 24
    let configuration: Configuration
    let deferredResizeInterval: Duration

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
            scriptedTransport: transport.map(TerminalTransportBox.init),
            credentials: nil,
            paneCommand: "exec pi"
        )
        self.deferredResizeInterval = deferredResizeInterval
    }

    init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode = .standardKey,
        sessionName: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory,
        credentials: any SSHSessionCredentials,
        paneCommand: String = "exec pi",
        deferredResizeInterval: Duration = .milliseconds(150)
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            scriptedTransport: nil,
            credentials: credentials,
            paneCommand: paneCommand
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
        let channel: TerminalChannelBox? = lock.withLock {
            guard stateMachine.phase == .attached || stateMachine.phase == .interrupted else {
                return nil
            }
            return self.channel
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
            attachmentGeneration &+= 1
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
        let staleTransport: TerminalTransportBox? = try lock.withLock {
            try stateMachine.beginReconnect()
            attachmentGeneration &+= 1
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
            attachmentGeneration &+= 1
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
            let normalized = coalescer.normalized(columns: columns, rows: rows)
            latestColumns = normalized.columns
            latestRows = normalized.rows
            return ResizeSubmission(
                decision: coalescer.submit(columns: normalized.columns, rows: normalized.rows),
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

    func flushPendingResize() {
        let pending: PendingResize = lock.withLock {
            PendingResize(size: coalescer.flush(), channel: channel)
        }
        guard let size = pending.size, let channel = pending.channel else {
            return
        }
        try? channel.requestResize(columns: size.columns, rows: size.rows)
    }
}
