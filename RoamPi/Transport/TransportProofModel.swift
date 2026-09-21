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

    private let coordinator: ProbeCoordinator
    private var currentTask: Task<Void, Never>?
    private var pendingEndpoint: RemoteEndpoint?

    init(coordinator: ProbeCoordinator, demoMode: Bool = false) {
        self.coordinator = coordinator
        if demoMode {
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
            } catch {
                state = .failed(TransportDiagnostic.keyUnavailable.userMessage)
            }
        }
    }

    func runProbe() {
        let endpoint: RemoteEndpoint
        do {
            endpoint = try RemoteEndpoint(connectionString: connectionString, advancedPort: advancedPort)
        } catch {
            state = .failed(TransportDiagnostic.invalidEndpoint.userMessage)
            return
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

    func confirmHostKeyAndReconnect() {
        guard case let .awaitingConfirmation(fingerprint) = state,
              let endpoint = pendingEndpoint
        else {
            return
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
