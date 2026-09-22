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
    private var exitStatus: Int32?
    private var isClosed = false

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
        guard !lock.withLock({ isClosed }) else {
            throw SessionDiagnostic.cancelled
        }
        let transport = SSHSessionTransport(credentials: credentials)
        let connection = try await transport.connect(endpoint: endpoint, mode: authentication)
        let closeImmediately = lock.withLock {
            guard !isClosed else { return true }
            self.connection = connection
            return false
        }
        if closeImmediately {
            await connection.close()
            throw SessionDiagnostic.cancelled
        }
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
            sessionChannel.onOutputOverflow = { [weak self] in
                guard let handler = self?.lock.withLock({ self?.outputHandler }) else {
                    return
                }
                // Feed a bounded explicit oversized record into the strict
                // decoder rather than silently dropping protocol bytes.
                handler(Data(repeating: 0, count: JSONLFraming.maxFrameBytes + 1))
            }
            sessionChannel.onExit = { [weak self] status in
                self?.lock.withLock { self?.exitStatus = status }
            }
            sessionChannel.onClosed = { [weak self] in
                guard let self else { return }
                let result = lock.withLock { (closedHandler, exitStatus) }
                result.0?(result.1)
            }

            lock.withLock {
                self.channel = sessionChannel
            }
            return sessionChannel
        } catch {
            await connection.close()
            lock.withLock { self.connection = nil }
            throw error
        }
    }

    func close() async throws {
        let resources: Resources = lock.withLock {
            isClosed = true
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
    private struct Resources {
        let channel: (any RPCChannel)?
        let transport: (any RPCTransport)?
        let pending: [String: CheckedContinuation<PiRPCFrame, Error>]
    }

    private struct ProtocolFailureResources {
        let channel: (any RPCChannel)?
        let transport: (any RPCTransport)?
        let pending: [String: CheckedContinuation<PiRPCFrame, Error>]
    }

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
    private var streamGeneration: UInt64 = 0
    private var recordedExchange: ExchangeResult?
    private var phaseChangeHandler: (@Sendable (PiSessionPhase) -> Void)?
    private var requestRegistrationHook: (@Sendable () async -> Void)?

    private let configuration: Configuration
    private let requestTimeout: Duration

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
        transport: (any RPCTransport)? = nil,
        requestTimeout: Duration = .seconds(30)
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            workingDirectory: workingDirectory,
            scriptedTransport: transport,
            credentials: nil
        )
        self.requestTimeout = requestTimeout
    }

    init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode = .standardKey,
        workingDirectory: RemoteWorkingDirectory,
        credentials: any SSHSessionCredentials,
        requestTimeout: Duration = .seconds(30)
    ) {
        configuration = Configuration(
            endpoint: endpoint,
            authentication: authentication,
            workingDirectory: workingDirectory,
            scriptedTransport: nil,
            credentials: credentials
        )
        self.requestTimeout = requestTimeout
    }

    /// Installs a deterministic suspension point used only by protocol race tests.
    func setRequestRegistrationHook(_ hook: (@Sendable () async -> Void)?) {
        lock.withLock { requestRegistrationHook = hook }
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
        let resources: Resources = try lock.withLock {
            try stateMachine.detach()
            streamGeneration &+= 1
            let resources = Resources(
                channel: channel,
                transport: transport,
                pending: pendingRequests
            )
            pendingRequests = [:]
            channel = nil
            transport = nil
            return resources
        }
        publishPhase()
        resume(resources.pending, diagnostic: .cancelled, phase: .detached)
        await resources.channel?.close()
        try await resources.transport?.close()
    }

    public func reconnect() async throws {
        let staleResources: Resources = try lock.withLock {
            try stateMachine.beginReconnect()
            streamGeneration &+= 1
            let resources = Resources(
                channel: channel,
                transport: transport,
                pending: pendingRequests
            )
            pendingRequests = [:]
            transport = nil
            channel = nil
            return resources
        }
        publishPhase()
        resume(staleResources.pending, diagnostic: .cancelled, phase: .detached)
        await staleResources.channel?.close()
        try? await staleResources.transport?.close()
        await openExchange()
    }

    public func close() async throws {
        let resources: Resources = try lock.withLock {
            try stateMachine.beginClose()
            streamGeneration &+= 1
            let resources = Resources(
                channel: channel,
                transport: transport,
                pending: pendingRequests
            )
            pendingRequests = [:]
            channel = nil
            transport = nil
            return resources
        }
        publishPhase()
        resume(resources.pending, diagnostic: .cancelled, phase: .closing)
        await resources.channel?.close()
        try await resources.transport?.close()
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
        let generation: UInt64 = lock.withLock {
            streamGeneration &+= 1
            decoder = JSONLFrameDecoder()
            responseFrameCount = 0
            eventFrameCount = 0
            recordedExchange = nil
            return streamGeneration
        }
        var candidateTransport: (any RPCTransport)?
        do {
            // Keep this as a statement for Xcode 26.6: its Swift compiler can
            // hang while lowering a conditional expression to an existential.
            // swiftformat:disable conditionalAssignment
            let transport: any RPCTransport
            if let scripted = configuration.scriptedTransport {
                transport = scripted
            } else {
                transport = SSHRPCTransport(
                    endpoint: configuration.endpoint,
                    authentication: configuration.authentication,
                    workingDirectory: configuration.workingDirectory,
                    credentials: configuration.credentials ?? SecureTransportStore.shared
                )
            }
            // swiftformat:enable conditionalAssignment

            candidateTransport = transport
            transport.onOutput = { [weak self] data in
                self?.handleOutput(data, generation: generation)
            }
            transport.onClosed = { [weak self] exitStatus in
                self?.handleProcessEnded(generation: generation, exitStatus: exitStatus)
            }
            try lock.withLock {
                guard stateMachine.phase == .connecting || stateMachine.phase == .reconnecting else {
                    throw SessionFailure(diagnostic: .cancelled, phase: stateMachine.phase)
                }
                self.transport = transport
            }

            let channel = try await transport.open()

            try lock.withLock {
                guard generation == streamGeneration,
                      self.transport === transport,
                      stateMachine.phase == .connecting || stateMachine.phase == .reconnecting
                else {
                    throw SessionFailure(diagnostic: .cancelled, phase: stateMachine.phase)
                }
                try stateMachine.markAttached()
                self.transport = transport
                self.channel = channel
            }
            publishPhase()

            let stateResponse = try await send(
                PiRPCRequest(identifier: nextIdentifier(), kind: .getState)
            )
            let counts = lock.withLock { (responseFrameCount, eventFrameCount) }
            let didRecord = lock.withLock {
                guard stateMachine.phase == .attached else { return false }
                recordedExchange = ExchangeResult(
                    succeeded: stateResponse.isSuccessResponse(command: "get_state"),
                    diagnostic: nil,
                    responseFrameCount: counts.0,
                    eventFrameCount: counts.1
                )
                return true
            }
            if didRecord {
                publishPhase()
            }
        } catch {
            let diagnostic: SessionDiagnostic = switch error {
            case is CancellationError:
                .cancelled
            case let failure as SessionFailure:
                failure.diagnostic
            case let sessionDiagnostic as SessionDiagnostic:
                sessionDiagnostic
            case let transportError as TransportError:
                Self.diagnostic(for: transportError)
            default:
                .connectionFailed
            }
            try? await candidateTransport?.close()
            finishOpenFailure(
                diagnostic,
                generation: generation,
                candidateTransport: candidateTransport
            )
        }
    }

    private func send(_ request: PiRPCRequest) async throws -> PiRPCFrame {
        let frame = try request.encodedFrame()
        let requestContext: (any RPCChannel, UInt64)? = lock.withLock {
            guard let channel, stateMachine.phase == .attached else { return nil }
            return (channel, streamGeneration)
        }
        guard let (channel, generation) = requestContext else {
            throw SessionFailure(diagnostic: .notAttached, phase: .attached)
        }
        if let hook = lock.withLock({ requestRegistrationHook }) {
            await hook()
        }

        let timeout = requestTimeout
        let timeoutTask: Task<Void, Never> = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.stopTimedOutRequest(request.identifier, generation: generation)
        }
        defer { timeoutTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PiRPCFrame, Error>) in
                    let registrationError: SessionDiagnostic? = lock.withLock {
                        guard !Task.isCancelled else { return .cancelled }
                        guard pendingRequests[request.identifier] == nil else {
                            return .duplicateRequest
                        }
                        guard generation == streamGeneration, stateMachine.phase == .attached else {
                            return .cancelled
                        }
                        pendingRequests[request.identifier] = continuation
                        return nil
                    }
                    if let registrationError {
                        continuation.resume(
                            throwing: SessionFailure(diagnostic: registrationError, phase: .attached)
                        )
                        return
                    }

                    Task { [weak self] in
                        do {
                            try await channel.write(frame)
                        } catch {
                            self?.failPending(
                                request.identifier,
                                generation: generation,
                                error: .connectionFailed
                            )
                        }
                    }
                }
            } onCancel: {
                stopCancelledRequest(request.identifier, generation: generation)
            }
        } catch let failure as SessionFailure {
            throw failure
        } catch {
            throw SessionFailure(diagnostic: .connectionFailed, phase: .attached)
        }
    }

    private func failPending(
        _ identifier: String,
        generation: UInt64,
        error: SessionDiagnostic
    ) {
        let continuation: CheckedContinuation<PiRPCFrame, Error>? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            return pendingRequests.removeValue(forKey: identifier)
        }
        continuation?.resume(throwing: SessionFailure(diagnostic: error, phase: .attached))
    }

    private func stopTimedOutRequest(_ identifier: String, generation: UInt64) {
        stopRequest(identifier, generation: generation, diagnostic: .timedOut)
    }

    private func stopCancelledRequest(_ identifier: String, generation: UInt64) {
        stopRequest(identifier, generation: generation, diagnostic: .cancelled)
    }

    private func stopRequest(
        _ identifier: String,
        generation: UInt64,
        diagnostic: SessionDiagnostic
    ) {
        let continuation: CheckedContinuation<PiRPCFrame, Error>? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            return pendingRequests.removeValue(forKey: identifier)
        }
        guard let continuation else { return }
        stopAfterProtocolFailure(diagnostic, generation: generation)
        continuation.resume(
            throwing: SessionFailure(diagnostic: diagnostic, phase: .failed(diagnostic))
        )
    }

    private func handleOutput(_ data: Data, generation: UInt64) {
        let payloads: [Data]?
        do {
            payloads = try lock.withLock {
                guard generation == streamGeneration else { return nil }
                return try decoder.feed(data)
            }
        } catch let error as JSONLFraming.FrameError {
            stopAfterProtocolFailure(Self.diagnostic(for: error), generation: generation)
            return
        } catch {
            stopAfterProtocolFailure(.malformedFrame, generation: generation)
            return
        }

        guard let payloads else { return }
        var frames: [PiRPCFrame] = []
        for payload in payloads {
            guard let frame = try? JSONLFrameDecoder.decode(payload),
                  let rpcFrame = PiRPCFrameDecoder.decode(frame)
            else {
                stopAfterProtocolFailure(.malformedFrame, generation: generation)
                return
            }
            frames.append(rpcFrame)
        }
        for frame in frames {
            dispatch(frame, generation: generation)
        }
    }

    private func dispatch(_ frame: PiRPCFrame, generation: UInt64) {
        switch frame.body {
        case let .response(command, success, _):
            let continuation: CheckedContinuation<PiRPCFrame, Error>? = lock.withLock {
                guard generation == streamGeneration else { return nil }
                responseFrameCount += 1
                guard let identifier = frame.identifier else { return nil }
                return pendingRequests.removeValue(forKey: identifier)
            }
            if let continuation {
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
            lock.withLock {
                guard generation == streamGeneration else { return }
                eventFrameCount += 1
            }
            _ = type
        }
    }

    private func handleProcessEnded(generation: UInt64, exitStatus: Int32?) {
        // Finish and retire only the stream that emitted this callback. An old
        // channel may close after reconnect has already installed its successor.
        let result: (SessionDiagnostic?, [String: CheckedContinuation<PiRPCFrame, Error>])? =
            lock.withLock {
                guard generation == streamGeneration else { return nil }

                let endingDiagnostic: SessionDiagnostic?
                do {
                    try decoder.finish()
                    if let exitStatus, exitStatus != 0 {
                        endingDiagnostic = .commandFailed
                    } else {
                        endingDiagnostic = nil
                    }
                } catch let error as JSONLFraming.FrameError {
                    endingDiagnostic = Self.diagnostic(for: error)
                } catch {
                    endingDiagnostic = .malformedFrame
                }

                let pending = pendingRequests
                pendingRequests = [:]
                channel = nil
                if let endingDiagnostic {
                    try? stateMachine.fail(endingDiagnostic)
                } else if stateMachine.phase.isConnectedOrRecovering {
                    try? stateMachine.markDisconnected()
                }
                return (endingDiagnostic, pending)
            }

        guard let (endingDiagnostic, pending) = result else { return }
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

    private func stopAfterProtocolFailure(
        _ diagnostic: SessionDiagnostic,
        generation: UInt64? = nil
    ) {
        let resources: ProtocolFailureResources? = lock.withLock {
            if let generation, generation != streamGeneration {
                return nil
            }
            try? stateMachine.fail(diagnostic)
            let resources = ProtocolFailureResources(
                channel: channel,
                transport: transport,
                pending: pendingRequests
            )
            pendingRequests = [:]
            channel = nil
            transport = nil
            return resources
        }

        guard let resources else { return }
        for continuation in resources.pending.values {
            continuation.resume(
                throwing: SessionFailure(diagnostic: diagnostic, phase: .failed(diagnostic))
            )
        }
        Task {
            await resources.channel?.close()
            try? await resources.transport?.close()
        }
        publishPhase()
    }

    private func finishOpenFailure(
        _ diagnostic: SessionDiagnostic,
        generation: UInt64,
        candidateTransport: (any RPCTransport)?
    ) {
        let didFail = lock.withLock {
            guard generation == streamGeneration else { return false }
            if let candidateTransport, let transport, transport !== candidateTransport {
                return false
            }
            channel = nil
            transport = nil
            if case .failed = stateMachine.phase {
                return false
            }
            try? stateMachine.fail(diagnostic)
            return true
        }
        if didFail {
            publishPhase()
        }
    }

    private func resume(
        _ pending: [String: CheckedContinuation<PiRPCFrame, Error>],
        diagnostic: SessionDiagnostic,
        phase: PiSessionPhase
    ) {
        for continuation in pending.values {
            continuation.resume(throwing: SessionFailure(diagnostic: diagnostic, phase: phase))
        }
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
