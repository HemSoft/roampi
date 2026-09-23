import Foundation

public struct ProbeResult: Equatable, Sendable {
    public let elapsedMilliseconds: Int
    public let authentication: SSHAuthenticationOffer

    public init(elapsedMilliseconds: Int, authentication: SSHAuthenticationOffer) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.authentication = authentication
    }
}

public protocol SSHProbeTransporting: Sendable {
    func publicKey() async throws -> String
    func runProbe(endpoint: RemoteEndpoint, mode: SSHAuthenticationMode) async throws -> ProbeResult
    func trust(fingerprint: String, endpoint: RemoteEndpoint) async throws
}
