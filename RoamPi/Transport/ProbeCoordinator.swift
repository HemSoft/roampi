import Foundation
import RoamPiCore

actor ProbeCoordinator {
    private let transport: any SSHProbeTransporting
    private var isRunning = false

    init(transport: any SSHProbeTransporting) {
        self.transport = transport
    }

    func publicKey() async throws -> String {
        try await transport.publicKey()
    }

    func trust(fingerprint: String, endpoint: RemoteEndpoint) async throws {
        try await transport.trust(fingerprint: fingerprint, endpoint: endpoint)
    }

    func run(endpoint: RemoteEndpoint, mode: SSHAuthenticationMode) async throws -> ProbeResult {
        guard !isRunning else {
            throw TransportError.diagnostic(.duplicateProbe)
        }
        isRunning = true
        defer { isRunning = false }
        return try await transport.runProbe(endpoint: endpoint, mode: mode)
    }
}
