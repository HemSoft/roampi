import SwiftUI

struct RootView: View {
    let snapshot: DashboardSnapshot
    var transportDemoMode = false

    var body: some View {
        if snapshot.machines.isEmpty {
            TransportProofView(demoMode: transportDemoMode)
        } else {
            DashboardView(snapshot: snapshot)
        }
    }
}
