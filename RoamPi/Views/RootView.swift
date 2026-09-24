import RoamPiCore
import SwiftUI

/// Routes between saved hosts, explicit development proofs, and demo screens.
struct RootView: View {
    let snapshot: DashboardSnapshot
    var transportDemoMode = false
    var savedHostsDemoMode = false
    var developmentTransportProfile: DevelopmentTransportProfile?
    var missingDevelopmentTransportFixture = false
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
            } else if !snapshot.machines.isEmpty {
                DashboardView(snapshot: snapshot)
            } else if missingDevelopmentTransportFixture {
                Text("No development transport profile staged.")
                    .accessibilityIdentifier("missing-development-transport-fixture")
            } else if transportDemoMode || developmentTransportProfile != nil {
                TransportProofView(
                    demoMode: transportDemoMode,
                    developmentProfile: developmentTransportProfile
                )
            } else {
                SavedHostsView(demo: savedHostsDemoMode)
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
