import Foundation

@MainActor
final class TransportProofModel: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case awaitingConfirmation(String)
        case succeeded(ProbeResult)
        case failed(String)
    }

    @Published var advancedPort = ""
    @Published var authenticationMode = SSHAuthenticationMode.standardKey
    @Published var connectionString = ""
    @Published private(set) var publicKey = ""
    @Published private(set) var state = State.idle

    var isEndpointLocked: Bool {
        switch state {
        case .running, .awaitingConfirmation:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }

    var usesDevelopmentProfile: Bool {
        !expectedFingerprints.isEmpty
    }

    private let coordinator: ProbeCoordinator
    private let developmentEndpoint: RemoteEndpoint?
    private let expectedFingerprints: Set<String>
    private var currentTask: Task<Void, Never>?
    private var pendingEndpoint: RemoteEndpoint?

    init(
        coordinator: ProbeCoordinator,
        demoMode: Bool = false,
        developmentProfile: DevelopmentTransportProfile? = nil
    ) {
        self.coordinator = coordinator
        developmentEndpoint = developmentProfile?.endpoint
        expectedFingerprints = developmentProfile?.expectedFingerprints ?? []
        if developmentProfile != nil {
            connectionString = "operator@staged-test-host"
        } else if demoMode {
            connectionString = "operator@studio-mini"
        }
    }

    deinit {
        currentTask?.cancel()
    }

    func loadPublicKey() {
        guard publicKey.isEmpty else { return }
        Task {
            do {
                publicKey = try await coordinator.publicKey()
                if usesDevelopmentProfile {
                    DevelopmentTransportProfile.exportPublicKey(publicKey)
                }
            } catch {
                state = .failed(TransportDiagnostic.keyUnavailable.userMessage)
            }
        }
    }

    func runProbe() {
        let endpoint: RemoteEndpoint
        if let developmentEndpoint {
            endpoint = developmentEndpoint
        } else {
            do {
                endpoint = try RemoteEndpoint(connectionString: connectionString, advancedPort: advancedPort)
            } catch {
                state = .failed(TransportDiagnostic.invalidEndpoint.userMessage)
                return
            }
        }

        pendingEndpoint = endpoint
        currentTask?.cancel()
        state = .running
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.run(endpoint: endpoint, mode: authenticationMode)
                state = .succeeded(result)
            } catch let TransportError.hostKeyConfirmationRequired(fingerprint) {
                state = .awaitingConfirmation(fingerprint)
            } catch let TransportError.diagnostic(diagnostic) {
                state = .failed(diagnostic.userMessage)
            } catch is CancellationError {
                state = .failed(TransportDiagnostic.cancelled.userMessage)
            } catch {
                state = .failed(TransportDiagnostic.connectionFailed.userMessage)
            }
        }
    }

    func isExpectedFingerprint(_ fingerprint: String) -> Bool {
        !usesDevelopmentProfile || expectedFingerprints.contains(fingerprint)
    }

    func rejectHostKey() {
        currentTask?.cancel()
        currentTask = nil
        pendingEndpoint = nil
        state = .idle
    }

    func confirmHostKeyAndReconnect() {
        guard case let .awaitingConfirmation(fingerprint) = state,
              let endpoint = pendingEndpoint
        else {
            return
        }

        if developmentEndpoint == nil {
            guard let displayedEndpoint = try? RemoteEndpoint(
                connectionString: connectionString,
                advancedPort: advancedPort
            ), displayedEndpoint == endpoint else {
                pendingEndpoint = nil
                state = .failed(TransportDiagnostic.invalidEndpoint.userMessage)
                return
            }
        }

        currentTask?.cancel()
        state = .running
        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.trust(fingerprint: fingerprint, endpoint: endpoint)
                let result = try await coordinator.run(endpoint: endpoint, mode: authenticationMode)
                state = .succeeded(result)
            } catch let TransportError.diagnostic(diagnostic) {
                state = .failed(diagnostic.userMessage)
            } catch {
                state = .failed(TransportDiagnostic.connectionFailed.userMessage)
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}

actor DemoProbeTransport: SSHProbeTransporting {
    private var trusted = false

    func publicKey() -> String {
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJvYW1waS1kZW1vLWtleS1ub3QtZm9yLXVzZQ=="
    }

    func runProbe(endpoint _: RemoteEndpoint, mode: SSHAuthenticationMode) throws -> ProbeResult {
        guard trusted else {
            throw TransportError.hostKeyConfirmationRequired(
                fingerprint: "SHA256:RoamPiDemoFingerprintNotForProduction"
            )
        }
        return ProbeResult(
            elapsedMilliseconds: 84,
            authentication: mode == .standardKey ? .publicKey : .none
        )
    }

    func trust(fingerprint _: String, endpoint _: RemoteEndpoint) {
        trusted = true
    }
}
