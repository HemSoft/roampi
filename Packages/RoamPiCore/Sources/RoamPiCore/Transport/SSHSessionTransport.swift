import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Supplies the device key and the endpoint-bound host fingerprint. The
/// production implementation is the Keychain-backed `SecureTransportStore`;
/// integration tests provide an in-memory one.
protocol SSHSessionCredentials: Sendable {
    func privateKey() async throws -> Curve25519.Signing.PrivateKey
    func fingerprint(for endpoint: RemoteEndpoint) async throws -> String?
    func save(fingerprint: String, for endpoint: RemoteEndpoint) async throws
}

extension SecureTransportStore: SSHSessionCredentials {}

/// Connects long-lived SSH sessions for the terminal and RPC adapters.
///
/// The connection reuses the probe's authentication and host-key verification.
/// Each `openPTYSession`/`openExecSession` call opens one child channel on the
/// same connection, so resizes and reconnects ride an existing transport
/// instead of spawning extra remote processes.
final class SSHSessionTransport: @unchecked Sendable {
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private static let connectTimeout = TimeAmount.seconds(15)
    private static let sessionOpenTimeout = TimeAmount.seconds(30)

    private let credentials: any SSHSessionCredentials

    init(credentials: any SSHSessionCredentials = SecureTransportStore.shared) {
        self.credentials = credentials
    }

    func connect(endpoint: RemoteEndpoint, mode: SSHAuthenticationMode) async throws -> SSHSessionConnection {
        let privateKey = try await credentials.privateKey()
        let storedFingerprint = try await credentials.fingerprint(for: endpoint)
        let authentication = AuthenticationDelegate(
            mode: mode,
            username: endpoint.username,
            privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)
        )
        let hostKeys = HostKeyDelegate(storedFingerprint: storedFingerprint)

        let bootstrap = ClientBootstrap(group: Self.eventLoopGroup)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: authentication,
                        serverAuthDelegate: hostKeys
                    )
                    let handler = NIOSSHHandler(
                        role: .client(configuration),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandlers(
                        handler,
                        AuthenticationCompletionHandler(),
                        ConnectionErrorHandler()
                    )
                }
            }
            .connectTimeout(Self.connectTimeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel: Channel
        do {
            let connectionFuture = bootstrap.connect(host: endpoint.host, port: endpoint.port)
            channel = try await PendingConnection().wait(for: connectionFuture)
        } catch {
            try Self.translateConnectionError(
                error,
                hostKeys: hostKeys,
                authentication: authentication
            )
            throw TransportError.diagnostic(.connectionFailed)
        }

        authentication.closeChannelWhenExhausted {
            channel.close(promise: nil)
        }

        let deadline = SSHOperationDeadline()
        let timeoutTask = channel.eventLoop.scheduleTask(in: Self.sessionOpenTimeout) {
            deadline.expire()
            channel.close(promise: nil)
        }
        defer { timeoutTask.cancel() }

        do {
            let completion: EventLoopFuture<Void> = channel.pipeline
                .handler(type: AuthenticationCompletionHandler.self)
                .flatMap(\.completionFuture)
            try await withTaskCancellationHandler {
                try await completion.get()
            } onCancel: {
                channel.close(promise: nil)
            }
        } catch {
            try Self.translateAuthenticationError(
                error,
                hostKeys: hostKeys,
                authentication: authentication,
                deadline: deadline
            )
            throw TransportError.diagnostic(.authenticationFailed)
        }

        return SSHSessionConnection(
            channel: channel,
            authentication: authentication,
            hostKeys: hostKeys
        )
    }

    private static func translateConnectionError(
        _ error: Error,
        hostKeys: HostKeyDelegate,
        authentication: AuthenticationDelegate
    ) throws {
        if let validationError = hostKeys.validationError {
            throw validationError
        }
        if let transportError = error as? TransportError {
            throw transportError
        }
        if Task.isCancelled || error is CancellationError {
            throw TransportError.diagnostic(.cancelled)
        }
        if authentication.didExhaustOffers {
            throw TransportError.diagnostic(.authenticationFailed)
        }
    }

    private static func translateAuthenticationError(
        _ error: Error,
        hostKeys: HostKeyDelegate,
        authentication: AuthenticationDelegate,
        deadline: SSHOperationDeadline
    ) throws {
        if let validationError = hostKeys.validationError {
            throw validationError
        }
        if let transportError = error as? TransportError {
            throw transportError
        }
        if Task.isCancelled || error is CancellationError {
            throw TransportError.diagnostic(.cancelled)
        }
        if deadline.didExpire {
            throw TransportError.diagnostic(.timedOut)
        }
        if authentication.didExhaustOffers {
            throw TransportError.diagnostic(.authenticationFailed)
        }
    }
}

/// One authenticated SSH connection over which session channels are opened.
final class SSHSessionConnection: @unchecked Sendable {
    private let channel: Channel
    private let authentication: AuthenticationDelegate
    private let hostKeys: HostKeyDelegate

    init(channel: Channel, authentication: AuthenticationDelegate, hostKeys: HostKeyDelegate) {
        self.channel = channel
        self.authentication = authentication
        self.hostKeys = hostKeys
    }

    /// Opens an interactive PTY session that runs the approved command.
    func openPTYSession(
        command: String,
        terminalType: String = "xterm-256color",
        columns: Int,
        rows: Int
    ) async throws -> SSHSessionChannel {
        try await openSession { childChannel, handler in
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: terminalType,
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            try await handler.awaitRequestReply(for: request, on: childChannel)
        } thenRun: { childChannel, handler in
            let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            try await handler.awaitRequestReply(for: request, on: childChannel)
        }
    }

    /// Opens a non-interactive exec channel, for example for RPC mode.
    func openExecSession(command: String) async throws -> SSHSessionChannel {
        try await openSession { _, _ in
            // No PTY for exec channels.
        } thenRun: { childChannel, handler in
            let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
            try await handler.awaitRequestReply(for: request, on: childChannel)
        }
    }

    private func openSession(
        prepare: @escaping @Sendable (Channel, SessionChannelDataHandler) async throws -> Void,
        thenRun run: @escaping @Sendable (Channel, SessionChannelDataHandler) async throws -> Void
    ) async throws -> SSHSessionChannel {
        let opened: EventLoopPromise<Channel> = channel.eventLoop.makePromise()
        let childFuture: EventLoopFuture<Channel> = channel.pipeline
            .handler(type: NIOSSHHandler.self)
            .flatMap { handler in
                handler.createChannel(opened) { childChannel, type in
                    guard type == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            TransportError.diagnostic(.commandFailed)
                        )
                    }
                    return childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations
                            .addHandler(SessionChannelDataHandler())
                    }
                }
                return opened.futureResult
            }

        let childChannel: Channel
        do {
            childChannel = try await childFuture.get()
        } catch {
            try Self.translateChannelError(error)
            throw TransportError.diagnostic(.connectionFailed)
        }

        let handler = try await childChannel.pipeline
            .handler(type: SessionChannelDataHandler.self)
            .get()

        do {
            try await withTaskCancellationHandler {
                try await prepare(childChannel, handler)
                try await run(childChannel, handler)
            } onCancel: {
                childChannel.close(promise: nil)
            }
        } catch {
            childChannel.close(promise: nil)
            try Self.translateChannelError(error)
            throw TransportError.diagnostic(.commandFailed)
        }

        return SSHSessionChannel(channel: childChannel, handler: handler)
    }

    private static func translateChannelError(_ error: Error) throws {
        if let transportError = error as? TransportError {
            throw transportError
        }
        if Task.isCancelled || error is CancellationError {
            throw TransportError.diagnostic(.cancelled)
        }
    }

    /// Closes the whole SSH connection.
    func close() async {
        channel.close(promise: nil)
    }
}

/// One session (PTY or exec) child channel with its data handler.
final class SSHSessionChannel: @unchecked Sendable, TerminalChannel, RPCChannel {
    private let channel: Channel
    private let handler: SessionChannelDataHandler

    init(channel: Channel, handler: SessionChannelDataHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Observes stdout (and bounded stderr) bytes as they arrive.
    var onOutput: (@Sendable (Data, _ isStdErr: Bool) -> Void)? {
        get { handler.outputCallback }
        set { handler.outputCallback = newValue }
    }

    /// Observes the remote exit status when the process ends.
    var onExit: (@Sendable (Int32) -> Void)? {
        get { handler.exitCallback }
        set { handler.exitCallback = newValue }
    }

    /// Observes channel closure, whether local, remote, or network-driven.
    var onClosed: (@Sendable () -> Void)? {
        get { handler.closedCallback }
        set { handler.closedCallback = newValue }
    }

    /// Sends user input bytes to the remote PTY or process.
    func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await channel.writeAndFlush(channelData).get()
    }

    /// Sends one bounded window-change request on the existing channel. This is
    /// how viewport changes reach the remote PTY without reconnecting.
    func requestResize(columns: Int, rows: Int) throws {
        try requestWindowChange(columns: columns, rows: rows)
    }

    func requestWindowChange(columns: Int, rows: Int) throws {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        channel.triggerUserOutboundEvent(request, promise: nil)
    }

    /// Ends this channel. For tmux sessions the remote session detaches and
    /// keeps running; for exec channels the remote process ends.
    func close() async {
        channel.close(promise: nil)
    }
}

/// Pipeline handler for one session channel. Bridges SSH channel data and
/// channel-request replies to the session object.
final class SessionChannelDataHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let lock = NSLock()
    private var replyContinuations: [CheckedContinuation<Void, Error>] = []
    private var outputHandler: (@Sendable (Data, Bool) -> Void)?
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private var closedHandler: (@Sendable () -> Void)?
    private var pendingOutput: [(Data, Bool)] = []
    private var pendingOutputBytes = 0
    private var pendingExitStatus: Int32?
    private var didClose = false

    var outputCallback: (@Sendable (Data, Bool) -> Void)? {
        get { lock.withLock { outputHandler } }
        set {
            let pending: [(Data, Bool)] = lock.withLock {
                outputHandler = newValue
                guard newValue != nil else { return [] }
                let buffered = pendingOutput
                pendingOutput = []
                pendingOutputBytes = 0
                return buffered
            }
            if let newValue {
                for (data, isStdErr) in pending {
                    newValue(data, isStdErr)
                }
            }
        }
    }

    var exitCallback: (@Sendable (Int32) -> Void)? {
        get { lock.withLock { exitHandler } }
        set {
            let pending: Int32? = lock.withLock {
                exitHandler = newValue
                let status = pendingExitStatus
                pendingExitStatus = nil
                return status
            }
            if let newValue, let pending {
                newValue(pending)
            }
        }
    }

    var closedCallback: (@Sendable () -> Void)? {
        get { lock.withLock { closedHandler } }
        set {
            let alreadyClosed = lock.withLock {
                closedHandler = newValue
                return didClose
            }
            if alreadyClosed {
                newValue?()
            }
        }
    }

    init() {}

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case let .byteBuffer(bytes) = channelData.data else {
            return
        }
        var readable = bytes
        guard let payload = readable.readData(length: readable.readableBytes) else {
            return
        }
        let isStdErr = channelData.type == .stdErr
        let callback: (@Sendable (Data, Bool) -> Void)? = lock.withLock {
            if outputHandler == nil, pendingOutputBytes + payload.count <= JSONLFraming.maxFrameBytes {
                pendingOutput.append((payload, isStdErr))
                pendingOutputBytes += payload.count
            }
            return outputHandler
        }
        callback?(payload, isStdErr)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            resolveReply()
        case is ChannelFailureEvent:
            failOldestReply(TransportError.diagnostic(.commandFailed))
        case let status as SSHChannelRequestEvent.ExitStatus:
            let exitStatus = Int32(status.exitStatus)
            let callback: (@Sendable (Int32) -> Void)? = lock.withLock {
                if exitHandler == nil {
                    pendingExitStatus = exitStatus
                }
                return exitHandler
            }
            callback?(exitStatus)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let pending = pendingReplies()
        for continuation in pending {
            continuation.resume(throwing: TransportError.diagnostic(.connectionFailed))
        }
        let callback: (@Sendable () -> Void)? = lock.withLock {
            didClose = true
            return closedHandler
        }
        callback?()
        context.fireChannelInactive()
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        let pending = pendingReplies()
        for continuation in pending {
            continuation.resume(throwing: TransportError.diagnostic(.connectionFailed))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    /// Awaits the server's success/failure reply for one channel request.
    /// At most one request is awaited at a time by each session; a scheduled
    /// deadline fails the reply if the server never answers.
    func awaitRequestReply(
        for request: some Sendable,
        on channel: Channel
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                replyContinuations.append(continuation)
            }

            channel.eventLoop.scheduleTask(in: TimeAmount.seconds(30)) {
                self.failOldestReply(TransportError.diagnostic(.timedOut))
            }

            channel.triggerUserOutboundEvent(request, promise: nil)
        }
    }

    private func resolveReply() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !replyContinuations.isEmpty else { return nil }
            return replyContinuations.removeFirst()
        }
        continuation?.resume(returning: ())
    }

    private func failOldestReply(_ error: Error) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !replyContinuations.isEmpty else { return nil }
            return replyContinuations.removeFirst()
        }
        continuation?.resume(throwing: error)
    }

    private func pendingReplies() -> [CheckedContinuation<Void, Error>] {
        lock.withLock {
            let pending = replyContinuations
            replyContinuations = []
            return pending
        }
    }
}
