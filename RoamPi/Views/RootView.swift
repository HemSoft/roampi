import SwiftUI

struct RootView: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        if snapshot.machines.isEmpty {
            WelcomeView(snapshot: snapshot)
        } else {
            DashboardView(snapshot: snapshot)
        }
    }
}

private struct WelcomeView: View {
    let snapshot: DashboardSnapshot

    var body: some View {
        ContentUnavailableView {
            Label("RoamPi", systemImage: "terminal.fill")
        } description: {
            Text(snapshot.subtitle)
        } actions: {
            Text("Remote connection setup is coming next.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
