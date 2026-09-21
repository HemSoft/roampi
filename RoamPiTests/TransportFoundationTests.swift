import Foundation
@testable import RoamPi
import Testing

@Suite("SSH transport foundation")
struct TransportFoundationTests {
    @Test(
        "Connection strings parse supported host forms",
        arguments: [
            ("person@machine", nil, "machine", 22),
            ("person@machine.example.ts.net:2222", nil, "machine.example.ts.net", 2222),
            ("person@100.64.0.1", "2200", "100.64.0.1", 2200),
            ("person@[fd7a:115c:a1e0::1]:2022", nil, "fd7a:115c:a1e0::1", 2022),
        ]
    )
    func parsesConnectionStrings(input: String, advancedPort: String?, host: String, port: Int) throws {
        let endpoint = try RemoteEndpoint(connectionString: input, advancedPort: advancedPort)

        #expect(endpoint.username == "person")
        #expect(endpoint.host == host)
        #expect(endpoint.port == port)
    }

    @Test(
        "Connection strings reject ambiguous or unsafe values",
        arguments: [
            "missing-user",
            "@host",
            "person@",
            "person@@host",
            "person name@host",
            "person@host:0",
            "person@host:65536",
            "person@bad host",
            "person@[not-ipv6]",
        ]
    )
    func rejectsConnectionStrings(input: String) {
        #expect(throws: Error.self) {
            try RemoteEndpoint(connectionString: input)
        }
    }

    @Test("A port is accepted in only one place")
    func rejectsDuplicatePort() {
        #expect(throws: RemoteEndpointError.duplicatePort) {
            try RemoteEndpoint(connectionString: "person@host:2222", advancedPort: "2200")
        }
    }

    @Test("Host-key policy confirms, trusts, and blocks changes")
    func hostKeyTransitions() {
        #expect(HostKeyPolicy
            .evaluate(storedFingerprint: nil, presentedFingerprint: "key-a") == .confirm(fingerprint: "key-a"))
        #expect(HostKeyPolicy.evaluate(storedFingerprint: "key-a", presentedFingerprint: "key-a") == .trusted)
        #expect(HostKeyPolicy.evaluate(storedFingerprint: "key-a", presentedFingerprint: "key-b") == .changed)
    }

    @Test("Tailscale authentication falls back to a key")
    func tailscaleFallback() {
        var plan = SSHAuthenticationPlan(mode: .tailscaleSSHThenKey)

        #expect(plan.nextOffer(serverAllowsPublicKey: true) == SSHAuthenticationOffer.none)
        #expect(plan.nextOffer(serverAllowsPublicKey: true) == SSHAuthenticationOffer.publicKey)
        #expect(plan.nextOffer(serverAllowsPublicKey: true) == nil)
    }

    @Test("Key-only authentication stops when the server rejects public keys")
    func unavailableKeyAuthentication() {
        var plan = SSHAuthenticationPlan(mode: .standardKey)

        #expect(plan.nextOffer(serverAllowsPublicKey: false) == nil)
    }

    @Test("Diagnostics never interpolate connection details")
    func diagnosticsRedactSecrets() {
        let sensitiveValues = ["person", "machine.example.ts.net", "100.64.0.1", "/private/project"]

        for diagnostic in [
            TransportDiagnostic.authenticationFailed,
            .cancelled,
            .commandFailed,
            .connectionFailed,
            .duplicateProbe,
            .hostKeyChanged,
            .invalidEndpoint,
            .keyUnavailable,
        ] {
            #expect(sensitiveValues.allSatisfy { !diagnostic.userMessage.contains($0) })
        }
    }

    @Test("Coordinator rejects a duplicate command")
    func duplicateProbe() async throws {
        let transport = BlockingProbeTransport()
        let coordinator = ProbeCoordinator(transport: transport)
        let endpoint = try RemoteEndpoint(connectionString: "person@machine")
        let first = Task { try await coordinator.run(endpoint: endpoint, mode: .standardKey) }
        await transport.waitUntilStarted()

        await #expect(throws: TransportError.diagnostic(.duplicateProbe)) {
            try await coordinator.run(endpoint: endpoint, mode: .standardKey)
        }

        await transport.finish()
        _ = try await first.value
        #expect(await transport.commandCount == 1)
    }

    @Test("Cancelling a probe reaches the transport")
    func cancellation() async throws {
        let transport = CancellationProbeTransport()
        let coordinator = ProbeCoordinator(transport: transport)
        let endpoint = try RemoteEndpoint(connectionString: "person@machine")
        let task = Task { try await coordinator.run(endpoint: endpoint, mode: .standardKey) }
        await transport.waitUntilStarted()

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await transport.wasCancelled)
    }
}

private actor BlockingProbeTransport: SSHProbeTransporting {
    private(set) var commandCount = 0
    private var isFinished = false
    private var isStarted = false

    func publicKey() -> String {
        "public"
    }

    func runProbe(endpoint _: RemoteEndpoint, mode _: SSHAuthenticationMode) async throws -> ProbeResult {
        commandCount += 1
        isStarted = true
        while !isFinished {
            try await Task.sleep(for: .milliseconds(5))
        }
        return ProbeResult(elapsedMilliseconds: 1, authentication: .publicKey)
    }

    func trust(fingerprint _: String, endpoint _: RemoteEndpoint) {}

    func waitUntilStarted() async {
        while !isStarted {
            await Task.yield()
        }
    }

    func finish() {
        isFinished = true
    }
}

private actor CancellationProbeTransport: SSHProbeTransporting {
    private(set) var wasCancelled = false
    private var isStarted = false

    func publicKey() -> String {
        "public"
    }

    func runProbe(endpoint _: RemoteEndpoint, mode _: SSHAuthenticationMode) async throws -> ProbeResult {
        isStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
            return ProbeResult(elapsedMilliseconds: 1, authentication: .publicKey)
        } catch {
            wasCancelled = true
            throw error
        }
    }

    func trust(fingerprint _: String, endpoint _: RemoteEndpoint) {}

    func waitUntilStarted() async {
        while !isStarted {
            await Task.yield()
        }
    }
}
