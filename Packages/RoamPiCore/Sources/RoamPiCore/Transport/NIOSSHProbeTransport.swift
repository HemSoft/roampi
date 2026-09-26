import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public final class NIOSSHProbeTransport: SSHProbeTransporting, @unchecked Sendable {
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private static let harmlessCommand = "printf roampi-transport-proof"
    private static let expectedOutput = "roampi-transport-proof"
    private static let operationTimeout = TimeAmount.seconds(30)

    private let store: SecureTransportStore

    public init() {
        store = SecureTransportStore.shared
    }

    init(store: SecureTransportStore) {
        self.store = store
    }

    public func publicKey() async throws -> String {
        try await store.publicKey()
    }

    public func trust(fingerprint: String, endpoint: RemoteEndpoint) async throws {
        try await store.save(fingerprint: fingerprint, for: endpoint)
    }

    public func runProbe(endpoint: RemoteEndpoint, mode: SSHAuthenticationMode) async throws -> ProbeResult {
        let privateKey = try await store.privateKey()
        let storedFingerprint = try await store.fingerprint(for: endpoint)
        let authentication = AuthenticationDelegate(
            mode: mode,
            username: endpoint.username,
            privateKey: NIOSSHPrivateKey(ed25519Key: privateKey)
        )
        let hostKeys = HostKeyDelegate(storedFingerprint: storedFingerprint)
        let started = ContinuousClock.now

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
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel: Channel
        do {
            let connectionFuture = bootstrap.connect(host: endpoint.host, port: endpoint.port)
            channel = try await PendingConnection().wait(for: connectionFuture)
        } catch let error as TransportError {
            throw error
        } catch is CancellationError {
            throw TransportError.diagnostic(.cancelled)
        } catch {
            if let validationError = hostKeys.validationError {
                throw validationError
            }
            if Task.isCancelled {
                throw TransportError.diagnostic(.cancelled)
            }
            throw TransportError.diagnostic(ProbeConnectionFailure.diagnostic(for: error))
        }

        authentication.closeChannelWhenExhausted {
            channel.close(promise: nil)
        }
        let deadline = SSHOperationDeadline()
        let timeoutTask = channel.eventLoop.scheduleTask(in: Self.operationTimeout) {
            deadline.expire()
            channel.close(promise: nil)
        }

        return try await withTaskCancellationHandler {
            defer {
                timeoutTask.cancel()
                channel.close(promise: nil)
            }
            do {
                try Task.checkCancellation()
                let commandFuture: EventLoopFuture<Void> = channel.pipeline
                    .handler(type: AuthenticationCompletionHandler.self)
                    .flatMap(\.completionFuture)
                    .flatMap { channel.pipeline.handler(type: NIOSSHHandler.self) }
                    .flatMap { handler in
                        let child = channel.eventLoop.makePromise(of: Channel.self)
                        handler.createChannel(child) { childChannel, type in
                            guard type == .session else {
                                return childChannel.eventLoop.makeFailedFuture(
                                    TransportError.diagnostic(.commandFailed)
                                )
                            }
                            return childChannel.eventLoop.makeCompletedFuture {
                                try childChannel.pipeline.syncOperations.addHandlers(
                                    ProbeCommandHandler(
                                        command: Self.harmlessCommand,
                                        expectedOutput: Self.expectedOutput
                                    ),
                                    ConnectionErrorHandler()
                                )
                            }
                        }
                        return child.futureResult.flatMap { childChannel in
                            childChannel.pipeline.handler(type: ProbeCommandHandler.self)
                                .flatMap(\.completionFuture)
                                .flatMap { childChannel.close() }
                                .flatMapError { error in
                                    childChannel.close().flatMapThrowing { throw error }
                                }
                        }
                    }
                try await commandFuture.get()
                let elapsed = started.duration(to: .now)
                return ProbeResult(
                    elapsedMilliseconds: Self.milliseconds(elapsed),
                    authentication: authentication.lastOffer ?? .publicKey
                )
            } catch {
                if let validationError = hostKeys.validationError {
                    throw validationError
                }
                if authentication.didExhaustOffers {
                    throw TransportError.diagnostic(.authenticationFailed)
                }
                if deadline.didExpire {
                    throw TransportError.diagnostic(.timedOut)
                }
                if Task.isCancelled || error is CancellationError {
                    throw TransportError.diagnostic(.cancelled)
                }
                if let transportError = error as? TransportError {
                    throw transportError
                }
                throw TransportError.diagnostic(.connectionFailed)
            }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds * 1000
        let attoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(seconds + attoseconds)
    }
}

private final class ProbeCommandHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let expectedOutput: String
    private var output = ByteBuffer()
    private var completion: EventLoopPromise<Void>?
    private var future: EventLoopFuture<Void>?

    var completionFuture: EventLoopFuture<Void> {
        precondition(future != nil, "Probe handler must be added before awaiting completion")
        return future!
    }

    init(command: String, expectedOutput: String) {
        self.command = command
        self.expectedOutput = expectedOutput
    }

    func handlerAdded(context: ChannelHandlerContext) {
        precondition(completion == nil, "Probe handler cannot be added twice")
        let promise = context.eventLoop.makePromise(of: Void.self)
        completion = promise
        future = promise.futureResult
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            loopBoundContext.value.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        let reply = context.eventLoop.makePromise(of: Void.self)
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        reply.futureResult.whenFailure { [weak self] _ in
            self?.fail(context: loopBoundContext.value)
        }
        context.triggerUserOutboundEvent(request, promise: reply)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case var .byteBuffer(bytes) = channelData.data,
              channelData.type == .channel,
              output.readableBytes + bytes.readableBytes <= 128
        else {
            fail(context: context)
            return
        }
        output.writeBuffer(&bytes)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelFailureEvent {
            fail(context: context)
            return
        }
        if event is ChannelSuccessEvent {
            return
        }
        if let status = event as? SSHChannelRequestEvent.ExitStatus {
            let text = output.readString(length: output.readableBytes)
            if status.exitStatus == 0, text == expectedOutput {
                succeed()
            } else {
                fail(context: context)
            }
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(context: context)
        context.fireChannelInactive()
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        completion?.fail(TransportError.diagnostic(.commandFailed))
        completion = nil
    }

    private func succeed() {
        completion?.succeed(())
        completion = nil
    }

    private func fail(context: ChannelHandlerContext) {
        completion?.fail(TransportError.diagnostic(.commandFailed))
        completion = nil
        context.close(promise: nil)
    }
}
