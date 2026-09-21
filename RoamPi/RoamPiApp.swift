import SwiftUI

@main
struct RoamPiApp: App {
    private let arguments: [String]
    private let developmentTransportProfile: DevelopmentTransportProfile?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        self.arguments = arguments
        developmentTransportProfile = DevelopmentTransportProfile.consumeIfRequested(arguments: arguments)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                snapshot: arguments.contains("--demo") ? DemoFixture.dashboard : .empty,
                transportDemoMode: arguments.contains("--transport-proof-demo"),
                developmentTransportProfile: developmentTransportProfile
            )
        }
    }
}
