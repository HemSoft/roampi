import RoamPiCore
import SwiftUI

@main
struct RoamPiApp: App {
    private let arguments: [String]
    private let developmentTransportProfile: DevelopmentTransportProfile?
    private let missingDevelopmentTransportFixture: Bool
    private let developmentSessionProfile: DevelopmentSessionProfile?
    private let sessionRoute: RootView.SessionRoute?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        self.arguments = arguments
        #if DEBUG
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            let fixture = caches?.appendingPathComponent("roampi-development-transport-profile.json")
            missingDevelopmentTransportFixture = arguments.contains(DevelopmentTransportProfile.launchArgument)
                && !(fixture.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        #else
            missingDevelopmentTransportFixture = false
        #endif
        developmentTransportProfile = DevelopmentTransportProfile.consumeIfRequested(arguments: arguments)
        let sessionProfile = DevelopmentSessionProfile.consumeIfRequested(arguments: arguments)
        developmentSessionProfile = sessionProfile
        if arguments.contains("--terminal-demo") {
            sessionRoute = .terminalDemo
        } else if arguments.contains("--rpc-demo") {
            sessionRoute = .rpcDemo
        } else {
            sessionRoute = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                snapshot: arguments.contains("--demo") ? DemoFixture.dashboard : .empty,
                transportDemoMode: arguments.contains("--transport-proof-demo"),
                savedHostsDemoMode: arguments.contains("--saved-hosts-demo"),
                developmentTransportProfile: developmentTransportProfile,
                missingDevelopmentTransportFixture: missingDevelopmentTransportFixture,
                developmentSessionProfile: developmentSessionProfile,
                sessionRoute: sessionRoute
            )
            .task {
                #if DEBUG
                    guard arguments.contains("--export-development-public-key") else { return }
                    do {
                        let publicKey = try await NIOSSHProbeTransport().publicKey()
                        DevelopmentSessionProfile.exportPublicKey(publicKey)
                        print("Development public-key export succeeded.")
                    } catch {
                        print("Development public-key export failed.")
                    }
                #endif
            }
        }
    }
}
