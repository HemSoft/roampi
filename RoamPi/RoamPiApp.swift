import SwiftUI

@main
struct RoamPiApp: App {
    private let arguments = ProcessInfo.processInfo.arguments

    var body: some Scene {
        WindowGroup {
            RootView(
                snapshot: arguments.contains("--demo") ? DemoFixture.dashboard : .empty,
                transportDemoMode: arguments.contains("--transport-proof-demo")
            )
        }
    }
}
