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

private final class RequestTimeoutController: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func arm(after duration: Duration, action: @escaping @Sendable () -> Void) {
        let task = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            action()
        }
        let shouldCancel = lock.withLock {
            guard !cancelled else { return true }
            self.task = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            let task = self.task
            self.task = nil
            return task
        }
        task?.cancel()
    }
}

private final class OrderedRPCWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let predecessor = tail
            tail = Task {
                await predecessor?.value
                await operation()
            }
        }
    }
}

/// Native RPC adapter behind `PiSession`. Starts `pi --mode rpc`, exchanges at
/// least one strict LF-delimited request/response, and keeps framing details
/// out of SwiftUI views.
public final class RPCSession: @unchecked Sendable, PiSession {
    private enum RequestWriteState: Sendable {
        case queued
        case writing
        case written
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<PiRPCFrame, Error>
        let expectedCommand: String
        var writeState: RequestWriteState = .queued
        var deferredFailure: SessionDiagnostic?
        var deferredByLifecycle = false
    }

    private struct Resources {
        let channel: (any RPCChannel)?
        let transport: (any RPCTransport)?
        let pending: [String: PendingRequest]
    }

    private struct ProtocolFailureResources {
        let channel: (any RPCChannel)?
        let transport: (any RPCTransport)?
        let pending: [String: PendingRequest]
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
    private var pendingRequests: [String: PendingRequest] = [:]
    private var reservedRequestIdentifiers = Set<String>()
    private let writer = OrderedRPCWriter()
    private var responseFrameCount = 0
    private var eventFrameCount = 0
    private var identifierCounter = 0
    private var streamGeneration: UInt64 = 0
    private var retiringStreamGeneration: UInt64?
    private var recordedExchange: ExchangeResult?
    private var startupRequestIdentifier: String?
    private var phaseChangeHandler: (@Sendable (PiSessionPhase) -> Void)?
    private var requestRegistrationHook: (@Sendable () async -> Void)?
    private var requestWriteHook: (@Sendable () async -> Void)?
    private var requestWriteClaimHook: (@Sendable () async -> Void)?
    private var startupExchangeHook: (@Sendable () async -> Void)?
    private var startupSendHook: (@Sendable () async -> Void)?
    private var protocolFailureHook: (@Sendable () -> Void)?

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

    /// Installs a post-registration suspension point used only by protocol race tests.
    func setRequestWriteHook(_ hook: (@Sendable () async -> Void)?) {
        lock.withLock { requestWriteHook = hook }
    }

    /// Installs a post-claim suspension point used only by protocol race tests.
    func setRequestWriteClaimHook(_ hook: (@Sendable () async -> Void)?) {
        lock.withLock { requestWriteClaimHook = hook }
    }

    /// Installs a post-startup-response suspension point used only by race tests.
    func setStartupExchangeHook(_ hook: (@Sendable () async -> Void)?) {
        lock.withLock { startupExchangeHook = hook }
    }

    /// Installs a pre-send startup suspension used only by reservation tests.
    func setStartupSendHook(_ hook: (@Sendable () async -> Void)?) {
        lock.withLock { startupSendHook = hook }
    }

    /// Installs a synchronous protocol-failure suspension used only by retirement tests.
    func setProtocolFailureHook(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { protocolFailureHook = hook }
    }

    public func start() async throws {
        try lock.withLock {
            try stateMachine.beginConnecting()
        }
        publishPhase()
        await openExchange()
    }

    public func interrupt() async throws {
        try lock.withLock { try stateMachine.beginInterrupt() }
        publishPhase()
        defer {
            let didRestore = lock.withLock {
                guard stateMachine.phase == .interrupted else { return false }
                try? stateMachine.endInterrupt()
                return true
            }
            if didRestore {
                publishPhase()
            }
        }
        let request = PiRPCRequest(identifier: nextIdentifier(), kind: .abort)
        _ = try await send(request, allowInterrupted: true)
    }

    public func detach() async throws {
        let resources = try beginLifecycleRetirement { try stateMachine.detach() }
        publishPhase()
        await resources.channel?.close()
        let teardownFailed: Bool
        do {
            try await resources.transport?.close()
            teardownFailed = false
        } catch {
            teardownFailed = true
        }
        let pending = finishLifecycleRetirement()
        resume(pending, diagnostic: .cancelled, phase: .detached)
        if teardownFailed {
            throw SessionFailure(diagnostic: .connectionFailed, phase: .detached)
        }
    }

    public func reconnect() async throws {
        let resources = try beginLifecycleRetirement { try stateMachine.beginReconnect() }
        publishPhase()
        await resources.channel?.close()
        try? await resources.transport?.close()
        let pending = finishLifecycleRetirement()
        resume(pending, diagnostic: .cancelled, phase: .reconnecting)
        await openExchange()
    }

    public func close() async throws {
        let resources = try beginLifecycleRetirement { try stateMachine.beginClose() }
        publishPhase()
        await resources.channel?.close()
        let teardownFailed: Bool
        do {
            try await resources.transport?.close()
            teardownFailed = false
        } catch {
            teardownFailed = true
        }
        let pending = finishLifecycleRetirement()
        resume(pending, diagnostic: .cancelled, phase: .closing)
        try lock.withLock {
            try stateMachine.markClosed()
        }
        publishPhase()
        if teardownFailed {
            throw SessionFailure(diagnostic: .connectionFailed, phase: .closed)
        }
    }

    private func beginLifecycleRetirement(
        _ transition: () throws -> Void
    ) throws -> Resources {
        try lock.withLock {
            try transition()
            retiringStreamGeneration = streamGeneration
            for identifier in Array(pendingRequests.keys) {
                pendingRequests[identifier]?.deferredFailure = .cancelled
                pendingRequests[identifier]?.deferredByLifecycle = true
            }
            return Resources(channel: channel, transport: transport, pending: [:])
        }
    }

    private func finishLifecycleRetirement() -> [String: PendingRequest] {
        lock.withLock {
            streamGeneration &+= 1
            retiringStreamGeneration = nil
            let pending = pendingRequests
            pendingRequests = [:]
            reservedRequestIdentifiers = []
            channel = nil
            transport = nil
            return pending
        }
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
            startupRequestIdentifier = nil
            reservedRequestIdentifiers = []
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
            let startupRequest = PiRPCRequest(
                identifier: nextIdentifier(reserving: true),
                kind: .getState
            )

            try lock.withLock {
                guard generation == streamGeneration,
                      self.transport === transport,
                      stateMachine.phase == .connecting || stateMachine.phase == .reconnecting
                else {
                    throw SessionFailure(diagnostic: .cancelled, phase: stateMachine.phase)
                }
                try stateMachine.markAttached()
                startupRequestIdentifier = startupRequest.identifier
                self.transport = transport
                self.channel = channel
            }
            publishPhase()
            if let hook = lock.withLock({ startupSendHook }) {
                await hook()
            }

            let stateResponse = try await send(
                startupRequest,
                consumesReservedIdentifier: true
            )
            if let hook = lock.withLock({ startupExchangeHook }) {
                await hook()
            }
            let counts = lock.withLock { (responseFrameCount, eventFrameCount) }
            let didRecord = lock.withLock {
                guard stateMachine.phase == .attached || stateMachine.phase == .interrupted else {
                    return false
                }
                recordedExchange = ExchangeResult(
                    succeeded: stateResponse.isSuccessResponse(command: "get_state"),
                    diagnostic: nil,
                    responseFrameCount: counts.0,
                    eventFrameCount: counts.1
                )
                reservedRequestIdentifiers.remove(startupRequest.identifier)
                startupRequestIdentifier = nil
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

    private func send(
        _ request: PiRPCRequest,
        allowInterrupted: Bool = false,
        consumesReservedIdentifier: Bool = false
    ) async throws -> PiRPCFrame {
        let frame = try request.encodedFrame()
        let requestContext: (any RPCChannel, UInt64)? = lock.withLock {
            guard let channel,
                  stateMachine.phase == .attached
                  || (allowInterrupted && stateMachine.phase == .interrupted)
            else { return nil }
            return (channel, streamGeneration)
        }
        guard let (channel, generation) = requestContext else {
            throw SessionFailure(diagnostic: .notAttached, phase: .attached)
        }
        if let hook = lock.withLock({ requestRegistrationHook }) {
            await hook()
        }

        let timeout = requestTimeout
        let timeoutController = RequestTimeoutController()
        defer { timeoutController.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PiRPCFrame, Error>) in
                    let registrationError: SessionDiagnostic? = lock.withLock {
                        guard !Task.isCancelled else { return .cancelled }
                        guard pendingRequests[request.identifier] == nil,
                              consumesReservedIdentifier
                              || !reservedRequestIdentifiers.contains(request.identifier)
                        else {
                            return .duplicateRequest
                        }
                        guard generation == streamGeneration,
                              stateMachine.phase == .attached
                              || (allowInterrupted && stateMachine.phase == .interrupted)
                        else {
                            return .cancelled
                        }
                        if consumesReservedIdentifier {
                            guard reservedRequestIdentifiers.contains(request.identifier) else {
                                return .cancelled
                            }
                        }
                        pendingRequests[request.identifier] = PendingRequest(
                            continuation: continuation,
                            expectedCommand: request.expectedResponseCommand
                        )
                        writer.enqueue { [weak self] in
                            await self?.performWrite(
                                identifier: request.identifier,
                                generation: generation,
                                channel: channel,
                                frame: frame
                            )
                        }
                        return nil
                    }
                    if let registrationError {
                        continuation.resume(
                            throwing: SessionFailure(diagnostic: registrationError, phase: .attached)
                        )
                    } else {
                        timeoutController.arm(after: timeout) { [weak self] in
                            self?.stopTimedOutRequest(request.identifier, generation: generation)
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

    private func performWrite(
        identifier: String,
        generation: UInt64,
        channel: any RPCChannel,
        frame: Data
    ) async {
        if let hook = lock.withLock({ requestWriteHook }) {
            await hook()
        }
        let claimed = lock.withLock {
            guard generation == streamGeneration,
                  retiringStreamGeneration != generation,
                  var pending = pendingRequests[identifier],
                  pending.writeState == .queued,
                  !pending.deferredByLifecycle
            else { return false }
            pending.writeState = .writing
            pendingRequests[identifier] = pending
            return true
        }
        guard claimed else { return }
        if let hook = lock.withLock({ requestWriteClaimHook }) {
            await hook()
        }

        do {
            try await channel.write(frame)
            finishWrite(identifier, generation: generation, writeError: nil)
        } catch {
            finishWrite(identifier, generation: generation, writeError: .connectionFailed)
        }
    }

    private func finishWrite(
        _ identifier: String,
        generation: UInt64,
        writeError: SessionDiagnostic?
    ) {
        let outcome: (
            deferred: SessionDiagnostic?,
            deferredByLifecycle: Bool,
            failure: PendingRequest?
        ) = lock.withLock {
            guard generation == streamGeneration,
                  var pending = pendingRequests[identifier]
            else { return (nil, false, nil) }
            pending.writeState = .written
            pendingRequests[identifier] = pending
            if let deferred = pending.deferredFailure {
                return (deferred, pending.deferredByLifecycle, nil)
            }
            guard writeError != nil else { return (nil, false, nil) }
            return (nil, false, pendingRequests.removeValue(forKey: identifier))
        }
        if let deferred = outcome.deferred, !outcome.deferredByLifecycle {
            stopRequest(identifier, generation: generation, diagnostic: deferred)
        } else if let failure = outcome.failure, let writeError {
            failure.continuation.resume(
                throwing: SessionFailure(diagnostic: writeError, phase: .attached)
            )
        }
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
        let outcome: (
            pending: PendingRequest?,
            channel: (any RPCChannel)?,
            transport: (any RPCTransport)?
        ) = lock.withLock {
            guard generation == streamGeneration,
                  var pending = pendingRequests[identifier]
            else { return (nil, nil, nil) }
            if pending.writeState == .writing {
                guard pending.deferredFailure == nil else { return (nil, nil, nil) }
                pending.deferredFailure = diagnostic
                pendingRequests[identifier] = pending
                return (nil, channel, transport)
            }
            return (pendingRequests.removeValue(forKey: identifier), nil, nil)
        }
        if let channel = outcome.channel {
            Task { [weak self] in
                await channel.close()
                try? await outcome.transport?.close()
                self?.finishDeferredStop(
                    identifier,
                    generation: generation,
                    diagnostic: diagnostic
                )
            }
            return
        }
        guard let pending = outcome.pending else { return }
        stopAfterProtocolFailure(diagnostic, generation: generation)
        pending.continuation.resume(
            throwing: SessionFailure(diagnostic: diagnostic, phase: .failed(diagnostic))
        )
    }

    private func finishDeferredStop(
        _ identifier: String,
        generation: UInt64,
        diagnostic: SessionDiagnostic
    ) {
        let pending: PendingRequest? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            return pendingRequests.removeValue(forKey: identifier)
        }
        guard let pending else { return }
        stopAfterProtocolFailure(diagnostic, generation: generation)
        pending.continuation.resume(
            throwing: SessionFailure(diagnostic: diagnostic, phase: .failed(diagnostic))
        )
    }

    private func handleOutput(_ data: Data, generation: UInt64) {
        let payloads: [Data]?
        do {
            payloads = try lock.withLock {
                guard generation == streamGeneration,
                      retiringStreamGeneration != generation
                else { return nil }
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
        let batchIsValid = lock.withLock {
            guard generation == streamGeneration else { return false }
            var responseIdentifiers = Set<String>()
            for frame in frames {
                switch frame.body {
                case let .response(command, _, _):
                    guard let identifier = frame.identifier,
                          responseIdentifiers.insert(identifier).inserted,
                          let pending = pendingRequests[identifier],
                          pending.expectedCommand == command
                    else { return false }
                    responseFrameCount += 1
                case .event:
                    eventFrameCount += 1
                }
            }
            return true
        }
        guard batchIsValid else {
            stopAfterProtocolFailure(.malformedFrame, generation: generation)
            return
        }
        for frame in frames {
            dispatch(frame, generation: generation)
        }
    }

    private func dispatch(_ frame: PiRPCFrame, generation: UInt64) {
        switch frame.body {
        case let .response(command, success, _):
            let result: (pending: PendingRequest?, protocolMismatch: Bool) = lock.withLock {
                guard generation == streamGeneration,
                      stateMachine.phase == .attached || stateMachine.phase == .interrupted
                else { return (nil, false) }
                guard let identifier = frame.identifier,
                      let pending = pendingRequests[identifier]
                else { return (nil, true) }
                guard pending.deferredFailure == nil else { return (nil, false) }
                guard pending.expectedCommand == command else { return (nil, true) }
                return (pendingRequests.removeValue(forKey: identifier), false)
            }
            if result.protocolMismatch {
                stopAfterProtocolFailure(.malformedFrame, generation: generation)
            } else if let pending = result.pending {
                if success {
                    pending.continuation.resume(returning: frame)
                } else {
                    let failedStartup = lock.withLock {
                        guard generation == streamGeneration,
                              startupRequestIdentifier == frame.identifier
                        else { return false }
                        try? stateMachine.fail(.commandFailed)
                        return true
                    }
                    if failedStartup {
                        publishPhase()
                    }
                    pending.continuation.resume(
                        throwing: SessionFailure(
                            diagnostic: .commandFailed,
                            phase: failedStartup ? .failed(.commandFailed) : .attached
                        )
                    )
                }
            }
        case let .event(type, _):
            _ = type
        }
    }

    private func handleProcessEnded(generation: UInt64, exitStatus: Int32?) {
        // Finish and retire only the stream that emitted this callback. An old
        // channel may close after reconnect has already installed its successor.
        let result: (SessionDiagnostic?, [String: PendingRequest], PiSessionPhase)? = lock.withLock {
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
            let existingFailure: SessionDiagnostic? = if case let .failed(diagnostic) = stateMachine.phase {
                diagnostic
            } else {
                nil
            }
            let cleanStartupClose: SessionDiagnostic? = if existingFailure == nil,
                                                           endingDiagnostic == nil,
                                                           recordedExchange == nil
                                                           || !pending.isEmpty
                                                           || stateMachine.phase == .connecting
                                                           || stateMachine.phase == .reconnecting
            {
                .unexpectedRemoteClose
            } else {
                nil
            }
            let sessionDiagnostic = existingFailure
                ?? pending.values.compactMap(\.deferredFailure).first
                ?? endingDiagnostic
                ?? cleanStartupClose
            let isLifecycleRetirement = retiringStreamGeneration == generation
            pendingRequests = [:]
            reservedRequestIdentifiers = []
            channel = nil
            if !isLifecycleRetirement {
                if let sessionDiagnostic {
                    try? stateMachine.fail(sessionDiagnostic)
                } else if stateMachine.phase.isConnectedOrRecovering {
                    try? stateMachine.markDisconnected()
                }
            }
            let requestPhase = isLifecycleRetirement
                ? stateMachine.phase
                : sessionDiagnostic.map(PiSessionPhase.failed) ?? .detached
            return (sessionDiagnostic, pending, requestPhase)
        }

        guard let (endingDiagnostic, pending, requestPhase) = result else { return }
        for request in pending.values {
            let diagnostic = request.deferredFailure
                ?? endingDiagnostic
                ?? .unexpectedRemoteClose
            request.continuation.resume(
                throwing: SessionFailure(
                    diagnostic: diagnostic,
                    phase: requestPhase
                )
            )
        }
        publishPhase()
    }

    private func stopAfterProtocolFailure(
        _ diagnostic: SessionDiagnostic,
        generation: UInt64? = nil
    ) {
        lock.withLock { protocolFailureHook }?()
        let resources: ProtocolFailureResources? = lock.withLock {
            if let generation,
               generation != streamGeneration || retiringStreamGeneration == generation
            {
                return nil
            }
            try? stateMachine.fail(diagnostic)
            let resources = ProtocolFailureResources(
                channel: channel,
                transport: transport,
                pending: pendingRequests
            )
            pendingRequests = [:]
            reservedRequestIdentifiers = []
            channel = nil
            transport = nil
            return resources
        }

        guard let resources else { return }
        for request in resources.pending.values {
            request.continuation.resume(
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
        let result: (
            didFail: Bool,
            pending: [String: PendingRequest],
            diagnostic: SessionDiagnostic
        )? = lock.withLock {
            guard generation == streamGeneration else { return nil }
            if let candidateTransport, let transport, transport !== candidateTransport {
                return nil
            }
            let finalDiagnostic: SessionDiagnostic
            let didFail: Bool
            if case let .failed(existingDiagnostic) = stateMachine.phase {
                finalDiagnostic = existingDiagnostic
                didFail = false
            } else {
                try? stateMachine.fail(diagnostic)
                finalDiagnostic = diagnostic
                didFail = true
            }
            streamGeneration &+= 1
            let pending = pendingRequests
            pendingRequests = [:]
            reservedRequestIdentifiers = []
            startupRequestIdentifier = nil
            channel = nil
            transport = nil
            return (didFail, pending, finalDiagnostic)
        }
        guard let result else { return }
        resume(
            result.pending,
            diagnostic: result.diagnostic,
            phase: .failed(result.diagnostic)
        )
        if result.didFail {
            publishPhase()
        }
    }

    private func resume(
        _ pending: [String: PendingRequest],
        diagnostic: SessionDiagnostic,
        phase: PiSessionPhase
    ) {
        for request in pending.values {
            request.continuation.resume(
                throwing: SessionFailure(diagnostic: diagnostic, phase: phase)
            )
        }
    }

    private func publishPhase() {
        lock.withLock { phaseChangeHandler }?(lock.withLock { stateMachine.phase })
    }

    private func nextIdentifier(reserving: Bool = false) -> String {
        lock.withLock {
            var identifier: String
            repeat {
                identifierCounter += 1
                identifier = "r\(identifierCounter)"
            } while pendingRequests[identifier] != nil
                || reservedRequestIdentifiers.contains(identifier)
            if reserving {
                reservedRequestIdentifiers.insert(identifier)
            }
            return identifier
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
