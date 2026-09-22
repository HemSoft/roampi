import RoamPiCore
import SwiftUI

/// SwiftUI screen for the native RPC adapter. Shows bounded exchange counts
/// and phase; framing and SSH details stay behind `RPCSession`.
struct RPCSessionView: View {
    @StateObject private var model: RPCScreenModel

    init(model: RPCScreenModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionPhaseBanner(
                title: "Pi RPC",
                phase: model.phase,
                detail: model.phaseDetail
            )
            .accessibilityIdentifier("rpc-phase-banner")

            if let exchange = model.exchange {
                VStack(alignment: .leading, spacing: 4) {
                    Text(exchange.succeeded ? "RPC exchange completed" : "RPC exchange failed")
                        .font(.headline)
                        .accessibilityIdentifier("rpc-exchange-result")
                    Text("Response frames: \(exchange.responseFrameCount)")
                        .font(.subheadline)
                    Text("Event frames: \(exchange.eventFrameCount)")
                        .font(.subheadline)
                }
                .padding(.horizontal, 12)
                .accessibilityElement(children: .combine)
            } else {
                Text("No RPC exchange yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("rpc-exchange-empty")
            }

            Spacer()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button("Send state request") {
                        model.sendStateRequest()
                    }
                    .accessibilityIdentifier("rpc-send-state")

                    Button("Interrupt") {
                        model.interrupt()
                    }
                    .accessibilityIdentifier("rpc-interrupt")

                    Button("Reconnect") {
                        model.reconnect()
                    }
                    .disabled(!model.canReconnect)
                    .accessibilityIdentifier("rpc-reconnect")

                    Button("Close") {
                        model.close()
                    }
                    .accessibilityIdentifier("rpc-close")
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 12)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.08))
        .foregroundStyle(.white)
        .onAppear {
            model.startIfNeeded()
        }
    }
}

/// Observable bridge between the RPC adapter and its SwiftUI screen.
@MainActor
final class RPCScreenModel: ObservableObject {
    @Published private(set) var phase: PiSessionPhase = .idle
    @Published private(set) var phaseDetail: String?
    @Published private(set) var exchange: RPCSession.ExchangeResult?
    @Published private(set) var hasStarted = false

    let session: RPCSession

    var canReconnect: Bool {
        switch phase {
        case .detached, .disconnected, .failed:
            true
        default:
            false
        }
    }

    init(session: RPCSession) {
        self.session = session
        session.onPhaseChange = { [weak self] newPhase in
            Task { @MainActor in
                self?.phase = newPhase
                self?.refreshExchange()
            }
        }
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            do {
                try await session.start()
            } catch let failure as SessionFailure {
                phaseDetail = failure.diagnostic.userMessage
            } catch let diagnostic as SessionDiagnostic {
                phaseDetail = diagnostic.userMessage
            } catch {
                phaseDetail = SessionDiagnostic.connectionFailed.userMessage
            }
        }
    }

    func sendStateRequest() {
        Task {
            do {
                let response = try await session.exchange(
                    PiRPCRequest(identifier: "ui-\(UUID().uuidString)", kind: .getState)
                )
                if response.isSuccessResponse(command: "get_state") {
                    phaseDetail = "The state request completed."
                }
            } catch let failure as SessionFailure {
                phaseDetail = failure.diagnostic.userMessage
            } catch {
                phaseDetail = SessionDiagnostic.connectionFailed.userMessage
            }
        }
    }

    func interrupt() {
        Task {
            try? await session.interrupt()
        }
    }

    func reconnect() {
        phaseDetail = nil
        Task {
            try? await session.reconnect()
        }
    }

    func close() {
        Task {
            try? await session.close()
        }
    }

    private func refreshExchange() {
        exchange = session.lastExchange
    }
}
