import Crypto
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

final class NIOSSHProbeTransport: SSHProbeTransporting, @unchecked Sendable {
    private static let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private static let harmlessCommand = "printf roampi-transport-proof"
    private static let expectedOutput = "roampi-transport-proof"

    private let store: SecureTransportStore

    init(store: SecureTransportStore = SecureTransportStore()) {
        self.store = store
    }

    func publicKey() async throws -> String {
        try await store.publicKey()
    }

    func trust(fingerprint: String, endpoint: RemoteEndpoint) async throws {
        try await store.save(fingerprint: fingerprint, for: endpoint)
    }

    func runProbe(endpoint: RemoteEndpoint, mode: SSHAuthenticationMode) async throws -> ProbeResult {
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
                    try channel.pipeline.syncOperations.addHandlers(handler, ConnectionErrorHandler())
                }
            }
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
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
            throw TransportError.diagnostic(.connectionFailed)
        }

        return try await withTaskCancellationHandler {
            defer { channel.close(promise: nil) }
            do {
                try Task.checkCancellation()
                let commandFuture: EventLoopFuture<Void> = channel.pipeline.handler(type: NIOSSHHandler.self)
                    .flatMap { handler in
                        let completion = channel.eventLoop.makePromise(of: Void.self)
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
                                        expectedOutput: Self.expectedOutput,
                                        completion: completion
                                    ),
                                    ConnectionErrorHandler()
                                )
                            }
                        }
                        return child.futureResult.flatMap { childChannel in
                            completion.futureResult
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

private final class AuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var plan: SSHAuthenticationPlan
    private var recordedOffer: SSHAuthenticationOffer?

    var lastOffer: SSHAuthenticationOffer? {
        lock.withLock { recordedOffer }
    }

    init(mode: SSHAuthenticationMode, username: String, privateKey: NIOSSHPrivateKey) {
        plan = SSHAuthenticationPlan(mode: mode)
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let next = lock.withLock {
            let offer = plan.nextOffer(serverAllowsPublicKey: availableMethods.contains(.publicKey))
            recordedOffer = offer
            return offer
        }

        switch next {
        case .some(.none):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none)
            )
        case .some(.publicKey):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: "",
                    offer: .privateKey(.init(privateKey: privateKey))
                )
            )
        case nil:
            nextChallengePromise.succeed(nil)
        }
    }
}

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let storedFingerprint: String?
    private var recordedValidationError: TransportError?

    var validationError: TransportError? {
        lock.withLock { recordedValidationError }
    }

    init(storedFingerprint: String?) {
        self.storedFingerprint = storedFingerprint
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        guard let fingerprint = Self.fingerprint(hostKey) else {
            let error = TransportError.diagnostic(.hostKeyChanged)
            record(error)
            validationCompletePromise.fail(error)
            return
        }

        switch HostKeyPolicy.evaluate(
            storedFingerprint: storedFingerprint,
            presentedFingerprint: fingerprint
        ) {
        case let .confirm(fingerprint):
            let error = TransportError.hostKeyConfirmationRequired(fingerprint: fingerprint)
            record(error)
            validationCompletePromise.fail(error)
        case .trusted:
            validationCompletePromise.succeed(())
        case .changed:
            let error = TransportError.diagnostic(.hostKeyChanged)
            record(error)
            validationCompletePromise.fail(error)
        }
    }

    private func record(_ error: TransportError) {
        lock.withLock {
            recordedValidationError = error
        }
    }

    private static func fingerprint(_ key: NIOSSHPublicKey) -> String? {
        let fields = String(openSSHPublicKey: key).split(separator: " ", maxSplits: 1)
        guard fields.count == 2, let keyData = Data(base64Encoded: String(fields[1])) else {
            return nil
        }
        let digest = SHA256.hash(data: keyData)
        return "SHA256:\(Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }
}

private final class ProbeCommandHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let expectedOutput: String
    private var output = ByteBuffer()
    private var completion: EventLoopPromise<Void>?

    init(command: String, expectedOutput: String, completion: EventLoopPromise<Void>) {
        self.command = command
        self.expectedOutput = expectedOutput
        self.completion = completion
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            loopBoundContext.value.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request, promise: nil)
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

private final class ConnectionErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }
}
