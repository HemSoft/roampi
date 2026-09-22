import RoamPiCore
import SwiftUI

/// Routes between the transport-proof screen, the demo dashboard, and the new
/// terminal and RPC session screens.
struct RootView: View {
    let snapshot: DashboardSnapshot
    var transportDemoMode = false
    var developmentTransportProfile: DevelopmentTransportProfile?
    var developmentSessionProfile: DevelopmentSessionProfile?
    var sessionRoute: SessionRoute?

    enum SessionRoute: Equatable {
        case terminalDemo
        case rpcDemo
    }

    var body: some View {
        switch sessionRoute {
        case .terminalDemo:
            TerminalScreenView(model: TerminalScreenModel(session: TerminalSession(
                endpoint: try! RemoteEndpoint(connectionString: "demo@fixture"),
                sessionName: TmuxSessionName("roampi-demo")!,
                workingDirectory: RemoteWorkingDirectory("/tmp/roampi-demo")!,
                transport: ScriptedTerminalTransport()
            )))
        case .rpcDemo:
            RPCSessionView(model: RPCScreenModel(session: RPCSession(
                endpoint: try! RemoteEndpoint(connectionString: "demo@fixture"),
                workingDirectory: RemoteWorkingDirectory("/tmp/roampi-demo")!,
                transport: ScriptedRPCTransport()
            )))
        case .none:
            if let developmentSessionProfile {
                DevelopmentSessionScreen(profile: developmentSessionProfile)
            } else if snapshot.machines.isEmpty {
                TransportProofView(
                    demoMode: transportDemoMode,
                    developmentProfile: developmentTransportProfile
                )
            } else {
                DashboardView(snapshot: snapshot)
            }
        }
    }
}

/// Hosts one real development-profile session for physical validation.
struct DevelopmentSessionScreen: View {
    let profile: DevelopmentSessionProfile

    var body: some View {
        switch profile.mode {
        case .terminal:
            TerminalScreenView(
                model: TerminalScreenModel(session: profile.makeTerminalSession())
            )
        case .rpc:
            RPCSessionView(
                model: RPCScreenModel(session: profile.makeRPCSession())
            )
        }
    }
}
