import Foundation

/// Byte-level transport for one native RPC session. The SSH exec channel is the
/// production transport; scripted transports serve demo and UI-test builds.
public protocol RPCTransport: AnyObject, Sendable {
    /// Observed remote bytes destined for the strict JSONL decoder.
    var onOutput: (@Sendable (Data) -> Void)? { get set }
    /// Observed end of the remote process with its optional exit status.
    var onClosed: (@Sendable (_ exitStatus: Int32?) -> Void)? { get set }

    /// Starts `pi --mode rpc` through an SSH exec channel.
    func open() async throws -> any RPCChannel
    /// Ends this transport and the remote RPC process.
    func close() async throws
}

/// One live RPC channel.
public protocol RPCChannel: Sendable {
    func write(_ data: Data) async throws
    func close() async
}

/// The SSH exec transport for RPC mode.
final class SSHRPCTransport: @unchecked Sendable, RPCTransport {
    private struct Resources {
        let channel: SSHSessionChannel?
        let connection: SSHSessionConnection?
    }

    private let endpoint: RemoteEndpoint
    private let authentication: SSHAuthenticationMode
    private let workingDirectory: RemoteWorkingDirectory
    private let credentials: any SSHSessionCredentials
    /// Internal override for integration fixtures; nil uses the approved
    /// `pi --mode rpc` command.
    let remoteCommand: String?

    private let lock = NSLock()
    private var connection: SSHSessionConnection?
    private var channel: SSHSessionChannel?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode,
        workingDirectory: RemoteWorkingDirectory,
        credentials: any SSHSessionCredentials = SecureTransportStore.shared,
        remoteCommand: String? = nil
    ) {
        self.endpoint = endpoint
        self.authentication = authentication
        self.workingDirectory = workingDirectory
        self.credentials = credentials
        self.remoteCommand = remoteCommand
    }

    func open() async throws -> any RPCChannel {
        let transport = SSHSessionTransport(credentials: credentials)
        let connection = try await transport.connect(endpoint: endpoint, mode: authentication)
        do {
            let command = remoteCommand ?? PiRPCCommand.start(workingDirectory: workingDirectory)
            let sessionChannel = try await connection.openExecSession(command: command)

            sessionChannel.onOutput = { [weak self] data, isStdErr in
                guard !isStdErr else { return }
                guard let handler = self?.lock.withLock({ self?.outputHandler }) else {
                    return
                }
                handler(data)
            }
            sessionChannel.onClosed = { [weak self] in
                guard let handler = self?.lock.withLock({ self?.closedHandler }) else {
                    return
                }
                handler(nil)
            }

            lock.withLock {
                self.connection = connection
                self.channel = sessionChannel
            }
            return sessionChannel
        } catch {
            await connection.close()
            throw error
        }
    }

    func close() async throws {
        let resources: Resources = lock.withLock {
            let resources = Resources(channel: channel, connection: connection)
            channel = nil
            connection = nil
            return resources
        }
        await resources.channel?.close()
        await resources.connection?.close()
    }
}

/// Native RPC adapter behind `PiSession`. Starts `pi --mode rpc`, exchanges at
/// least one strict LF-delimited request/response, and keeps framing details
/// out of SwiftUI views.
public final class RPCSession: @unchecked Sendable, PiSession {
    /// Bounded result of the most recent strict JSONL exchange. Contains no
    /// response content, paths, or prompts.
    public struct ExchangeResult: Equatable, Sendable {
        public let succeeded: Bool
        public let diagnostic: SessionDiagnostic?
        public let responseFrameCount: Int
        public let eventFrameCount: Int
    }

    private struct Configuration: Sendable {
        let endpoint: RemoteEndpoint
        let authentication: SSHAuthenticationMode
        let workingDirectory: RemoteWorkingDirectory
        let scriptedTransport: (any RPCTransport)?
        let credentials: (any SSHSessionCredentials)?
    }

    private let lock = NSLock()
    private var stateMachine = ReconnectStateMachine()
    private var decoder = JSONLFrameDecoder()
    private var transport: (any RPCTransport)?
    private var channel: (any RPCChannel)?
    private var pendingRequests: [String: CheckedContinuation<PiRPCFrame, Error>] = [:]
    private var responseFrameCount = 0
    private var eventFrameCount = 0
    private var identifierCounter = 0
    private var recordedExchange: ExchangeResult?
    private var phaseChangeHandler: (@Sendable (PiSessionPhase) -> Void)?

    private let configuration: Configuration

    /// Result of the startup `get_state` exchange, nil before it completes.
    public var lastExchange: ExchangeResult? {
        lock.withLock { recordedExchange }
    }

    public var phase: PiSessionPhase {
        lock.withLock { stateMachine.phase }
    }

    /// Observes session phases as they change. Called from arbitrary threads.
    public var onPhaseChange: (@Sendable (PiSessionPhase) -> Void)? {
        get { lock.withLock { phaseChangeHandler } }
        set { lock.withLock { phaseChangeHandler = newValue } }
    }

    public init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode = .standardKey,
        workingDirectory: RemoteWorkingDirectory,
        transport: (any RPCTransport)? = nil
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            workingDirectory: workingDirectory,
            scriptedTransport: transport,
            credentials: nil
        )
    }

    init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode = .standardKey,
        workingDirectory: RemoteWorkingDirectory,
        credentials: any SSHSessionCredentials
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            workingDirectory: workingDirectory,
            scriptedTransport: nil,
            credentials: credentials
        )
    }

    public func start() async throws {
        try lock.withLock {
            try stateMachine.beginConnecting()
        }
        publishPhase()
        await openExchange()
    }

    public func interrupt() async throws {
        let request = PiRPCRequest(identifier: nextIdentifier(), kind: .abort)
        _ = try await send(request)
    }

    public func detach() async throws {
        let channels = try lock.withLock {
            try stateMachine.detach()
            let channels = (channel, transport)
            channel = nil
            transport = nil
            return channels
        }
        publishPhase()
        await channels.0?.close()
        try await channels.1?.close()
    }

    public func reconnect() async throws {
        let staleTransport = try lock.withLock {
            try stateMachine.beginReconnect()
            let staleTransport = transport
            transport = nil
            channel = nil
            return staleTransport
        }
        publishPhase()
        try? await staleTransport?.close()
        await openExchange()
    }

    public func close() async throws {
        let channels = try lock.withLock {
            try stateMachine.beginClose()
            let channels = (channel, transport)
            channel = nil
            transport = nil
            return channels
        }
        publishPhase()
        await channels.0?.close()
        try await channels.1?.close()
        try lock.withLock {
            try stateMachine.markClosed()
        }
        publishPhase()
    }

    /// Sends one bounded request and awaits the correlated response frame.
    /// The exchange proves strict LF-delimited JSONL over the exec channel.
    public func exchange(_ request: PiRPCRequest) async throws -> PiRPCFrame {
        try await send(request)
    }

    private func openExchange() async {
        var candidateTransport: (any RPCTransport)?
        do {
            let transport: any RPCTransport = if let scripted = configuration.scriptedTransport {
                scripted
            } else {
                SSHRPCTransport(
                    endpoint: configuration.endpoint,
                    authentication: configuration.authentication,
                    workingDirectory: configuration.workingDirectory,
                    credentials: configuration.credentials ?? SecureTransportStore.shared
                )
            }

            candidateTransport = transport
            transport.onOutput = { [weak self] data in
                self?.handleOutput(data)
            }
            transport.onClosed = { [weak self] _ in
                self?.handleProcessEnded()
            }

            let channel = try await transport.open()

            try lock.withLock {
                try stateMachine.markAttached()
                self.transport = transport
                self.channel = channel
            }
            publishPhase()

            let stateResponse = try await send(
                PiRPCRequest(identifier: nextIdentifier(), kind: .getState)
            )
            let counts = lock.withLock { (responseFrameCount, eventFrameCount) }
            lock.withLock {
                recordedExchange = ExchangeResult(
                    succeeded: stateResponse.isSuccessResponse(command: "get_state"),
                    diagnostic: nil,
                    responseFrameCount: counts.0,
                    eventFrameCount: counts.1
                )
            }
            publishPhase()
        } catch is CancellationError {
            try? await candidateTransport?.close()
            clearTransportReferences()
            markFailure(.cancelled)
        } catch let failure as SessionFailure {
            try? await candidateTransport?.close()
            clearTransportReferences()
            markFailure(failure.diagnostic)
        } catch let diagnostic as SessionDiagnostic {
            try? await candidateTransport?.close()
            clearTransportReferences()
            markFailure(diagnostic)
        } catch let transportError as TransportError {
            try? await candidateTransport?.close()
            clearTransportReferences()
            markFailure(Self.diagnostic(for: transportError))
        } catch {
            try? await candidateTransport?.close()
            clearTransportReferences()
            markFailure(.connectionFailed)
        }
    }

    private func send(_ request: PiRPCRequest) async throws -> PiRPCFrame {
        let frame = try request.encodedFrame()
        let channel: (any RPCChannel)? = lock.withLock { self.channel }
        guard let channel else {
            throw SessionFailure(diagnostic: .notAttached, phase: .attached)
        }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PiRPCFrame, Error>) in
                    lock.withLock {
                        pendingRequests[request.identifier] = continuation
                    }

                    Task { [weak self] in
                        do {
                            try await channel.write(frame)
                        } catch {
                            self?.failPending(request.identifier, error: .connectionFailed)
                        }
                    }
                }
            } onCancel: {
                failPending(request.identifier, error: .cancelled)
            }
        } catch let failure as SessionFailure {
            throw failure
        } catch {
            throw SessionFailure(diagnostic: .connectionFailed, phase: .attached)
        }
    }

    private func failPending(_ identifier: String, error: SessionDiagnostic) {
        let continuation = lock.withLock { pendingRequests.removeValue(forKey: identifier) }
        continuation?.resume(throwing: SessionFailure(diagnostic: error, phase: .attached))
    }

    private func handleOutput(_ data: Data) {
        let payloads: [Data]
        do {
            payloads = try lock.withLock {
                try decoder.feed(data)
            }
        } catch let error as JSONLFraming.FrameError {
            stopAfterProtocolFailure(Self.diagnostic(for: error))
            return
        } catch {
            stopAfterProtocolFailure(.malformedFrame)
            return
        }

        for payload in payloads {
            guard let frame = try? JSONLFrameDecoder.decode(payload) else {
                stopAfterProtocolFailure(.malformedFrame)
                return
            }
            guard let rpcFrame = PiRPCFrameDecoder.decode(frame) else {
                stopAfterProtocolFailure(.malformedFrame)
                return
            }
            dispatch(rpcFrame)
        }
    }

    private func dispatch(_ frame: PiRPCFrame) {
        switch frame.body {
        case let .response(command, success, _):
            lock.withLock { responseFrameCount += 1 }
            if let identifier = frame.identifier,
               let continuation = lock.withLock({ pendingRequests.removeValue(forKey: identifier) })
            {
                if success {
                    continuation.resume(returning: frame)
                } else {
                    continuation.resume(
                        throwing: SessionFailure(diagnostic: .commandFailed, phase: .attached)
                    )
                }
            } else {
                _ = command
                _ = success
            }
        case let .event(type, _):
            lock.withLock { eventFrameCount += 1 }
            _ = type
        }
    }

    private func handleProcessEnded() {
        // Drain the decoder first so a trailing partial frame is reported
        // instead of being silently dropped at process end.
        var endingDiagnostic: SessionDiagnostic?
        do {
            try lock.withLock {
                try decoder.finish()
            }
        } catch let error as JSONLFraming.FrameError {
            endingDiagnostic = Self.diagnostic(for: error)
        } catch {
            endingDiagnostic = .malformedFrame
        }

        let pending: [String: CheckedContinuation<PiRPCFrame, Error>] = lock.withLock {
            let drained = pendingRequests
            pendingRequests = [:]
            channel = nil
            return drained
        }

        lock.withLock {
            if let endingDiagnostic {
                try? stateMachine.fail(endingDiagnostic)
            } else if stateMachine.phase.isConnectedOrRecovering {
                try? stateMachine.markDisconnected()
            }
        }

        for continuation in pending.values {
            continuation.resume(
                throwing: SessionFailure(
                    diagnostic: endingDiagnostic ?? .unexpectedRemoteClose,
                    phase: .detached
                )
            )
        }
        publishPhase()
    }

    private func stopAfterProtocolFailure(_ diagnostic: SessionDiagnostic) {
        let resources = lock.withLock {
            try? stateMachine.fail(diagnostic)
            let pending = pendingRequests
            pendingRequests = [:]
            let resources = (channel, transport, pending)
            channel = nil
            transport = nil
            return resources
        }

        for continuation in resources.2.values {
            continuation.resume(
                throwing: SessionFailure(diagnostic: diagnostic, phase: .failed(diagnostic))
            )
        }
        Task {
            await resources.0?.close()
            try? await resources.1?.close()
        }
        publishPhase()
    }

    private func clearTransportReferences() {
        lock.withLock {
            channel = nil
            transport = nil
        }
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

    private func nextIdentifier() -> String {
        lock.withLock {
            identifierCounter += 1
            return "r\(identifierCounter)"
        }
    }

    private static func diagnostic(for error: JSONLFraming.FrameError) -> SessionDiagnostic {
        switch error {
        case .framingError, .trailingPartialFrame, .streamAlreadyFinished:
            .malformedFrame
        case .frameTooLarge:
            .frameTooLarge
        case .malformedJSON:
            .malformedFrame
        }
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
