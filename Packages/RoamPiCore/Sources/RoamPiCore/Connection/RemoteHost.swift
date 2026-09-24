import Foundation

/// The verified-SSH entry point for one saved profile. UI code decides when a
/// user approves a fingerprint; this type owns the endpoint-bound probe, trust
/// write, device identity, and construction of a terminal session.
public struct RemoteHost: Sendable {
    private let probe: any SSHProbeTransporting

    public init(probe: any SSHProbeTransporting = NIOSSHProbeTransport()) {
        self.probe = probe
    }

    public func devicePublicKey() async throws -> String {
        try await probe.publicKey()
    }

    /// Runs only the fixed read-only SSH probe. Trust is never implied by a
    /// saved profile; the underlying Keychain pin blocks changed keys.
    public func verify(_ profile: ConnectionProfile) async throws -> ProbeResult {
        try await probe.runProbe(endpoint: profile.endpoint, mode: .standardKey)
    }

    /// Called only after the user compares the fingerprint with an independent
    /// source and approves this exact host and port.
    public func trust(_ fingerprint: String, for profile: ConnectionProfile) async throws {
        try await probe.trust(fingerprint: fingerprint, endpoint: profile.endpoint)
    }

    public func terminalSession(
        for profile: ConnectionProfile,
        transport: (any TerminalTransport)? = nil
    ) -> TerminalSession? {
        guard profile.sessionChoice == .terminal, let name = profile.tmuxSessionName else {
            return nil
        }
        return TerminalSession(
            endpoint: profile.endpoint,
            sessionName: name,
            workingDirectory: profile.projectDirectory,
            transport: transport
        )
    }
}
