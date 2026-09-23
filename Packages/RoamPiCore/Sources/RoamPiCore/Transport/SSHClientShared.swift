import Crypto
import Foundation
import NIOCore
import NIOSSH

// Shared SSH client machinery used by both the transport probe and the long-lived
// session transport. The classes here were extracted verbatim from the probe so
// both paths authenticate and verify host keys identically.

final class PendingConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var continuation: CheckedContinuation<Channel, Error>?
    private var finished = false
    private var resolvedChannel: Channel?

    func wait(for future: EventLoopFuture<Channel>) async throws -> Channel {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let wasCancelled = lock.withLock {
                    if cancelled {
                        return true
                    }
                    self.continuation = continuation
                    return false
                }

                future.whenComplete { [self] result in
                    complete(with: result)
                }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func cancel() {
        let (continuation, channel) = lock.withLock {
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            return (continuation, resolvedChannel)
        }
        continuation?.resume(throwing: CancellationError())
        channel?.close(promise: nil)
    }

    private func complete(with result: Result<Channel, Error>) {
        let action: (CheckedContinuation<Channel, Error>?, Channel?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true

            if case let .success(channel) = result {
                resolvedChannel = channel
                if cancelled {
                    return (nil, channel)
                }
            }

            let continuation = self.continuation
            self.continuation = nil
            return (continuation, nil)
        }
        action.1?.close(promise: nil)
        action.0?.resume(with: result)
    }
}

final class AuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var plan: SSHAuthenticationPlan
    private var recordedOffer: SSHAuthenticationOffer?
    private var exhaustedOffers = false
    private var exhaustionHandler: (@Sendable () -> Void)?

    var lastOffer: SSHAuthenticationOffer? {
        lock.withLock { recordedOffer }
    }

    var didExhaustOffers: Bool {
        lock.withLock { exhaustedOffers }
    }

    init(mode: SSHAuthenticationMode, username: String, privateKey: NIOSSHPrivateKey) {
        plan = SSHAuthenticationPlan(mode: mode)
        self.username = username
        self.privateKey = privateKey
    }

    func closeChannelWhenExhausted(_ handler: @escaping @Sendable () -> Void) {
        let shouldClose = lock.withLock {
            exhaustionHandler = handler
            return exhaustedOffers
        }
        if shouldClose {
            handler()
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let (next, exhaustionHandler) = lock.withLock {
            let offer = plan.nextOffer(serverAllowsPublicKey: availableMethods.contains(.publicKey))
            recordedOffer = offer
            exhaustedOffers = offer == nil
            return (offer, exhaustedOffers ? self.exhaustionHandler : nil)
        }
        exhaustionHandler?()

        switch next {
        case .some(.none):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: SSHAuthenticationPlan.serviceName,
                    offer: .none
                )
            )
        case .some(.publicKey):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(
                    username: username,
                    serviceName: SSHAuthenticationPlan.serviceName,
                    offer: .privateKey(.init(privateKey: privateKey))
                )
            )
        case nil:
            nextChallengePromise.succeed(nil)
        }
    }
}

final class SSHOperationDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false

    var didExpire: Bool {
        lock.withLock { expired }
    }

    func expire() {
        lock.withLock {
            expired = true
        }
    }
}

final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
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

final class AuthenticationCompletionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private var completion: EventLoopPromise<Void>?
    private var future: EventLoopFuture<Void>?

    var completionFuture: EventLoopFuture<Void> {
        precondition(future != nil, "Authentication handler must be added before awaiting completion")
        return future!
    }

    func handlerAdded(context: ChannelHandlerContext) {
        precondition(completion == nil, "Authentication handler cannot be added twice")
        let promise = context.eventLoop.makePromise(of: Void.self)
        completion = promise
        future = promise.futureResult
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            completion?.succeed(())
            completion = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail()
        context.fireChannelInactive()
    }

    func handlerRemoved(context _: ChannelHandlerContext) {
        fail()
    }

    private func fail() {
        completion?.fail(TransportError.diagnostic(.authenticationFailed))
        completion = nil
    }
}

final class ConnectionErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }
}
