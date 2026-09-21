import SwiftUI

struct RootView: View {
    let snapshot: DashboardSnapshot
    var transportDemoMode = false
    var developmentTransportProfile: DevelopmentTransportProfile?

    var body: some View {
        if snapshot.machines.isEmpty {
            TransportProofView(
                demoMode: transportDemoMode,
                developmentProfile: developmentTransportProfile
            )
        } else {
            DashboardView(snapshot: snapshot)
        }
    }
}
