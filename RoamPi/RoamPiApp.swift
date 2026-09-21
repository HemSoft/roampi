import SwiftUI

@main
struct RoamPiApp: App {
    private let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    var body: some Scene {
        WindowGroup {
            RootView(snapshot: isDemo ? DemoFixture.dashboard : .empty)
        }
    }
}
