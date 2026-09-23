import Crypto
import Foundation

/// Debug-only profile that stages one approved session for physical-device
/// validation. Consumed once at launch, like the transport profile: the file
/// is read from the app's private cache container and deleted immediately.
/// Release builds cannot consume it.
public struct DevelopmentSessionProfile: Sendable {
    public static let launchArgument = "--install-development-session-profile"

    public enum Mode: String, Decodable, Sendable {
        case terminal
        case rpc
    }

    public let endpoint: RemoteEndpoint
    public let expectedFingerprint: String
    public let sessionName: TmuxSessionName
    public let workingDirectory: RemoteWorkingDirectory
    public let mode: Mode

    public static func consumeIfRequested(arguments: [String]) -> DevelopmentSessionProfile? {
        #if DEBUG
            guard arguments.contains(launchArgument) else { return nil }

            let manager = FileManager.default
            guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let url = caches.appendingPathComponent("roampi-development-session-profile.json")
            defer { try? manager.removeItem(at: url) }

            guard let data = try? Data(contentsOf: url), data.count <= 4096,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let endpoint = try? RemoteEndpoint(connectionString: payload.connectionString),
                  payload.expectedFingerprints.count == 1,
                  let expectedFingerprint = payload.expectedFingerprints.first,
                  isValidFingerprint(expectedFingerprint),
                  let sessionName = TmuxSessionName(payload.sessionName),
                  let workingDirectory = RemoteWorkingDirectory(payload.workingDirectory)
            else {
                return nil
            }

            return DevelopmentSessionProfile(
                endpoint: endpoint,
                expectedFingerprint: expectedFingerprint,
                sessionName: sessionName,
                workingDirectory: workingDirectory,
                mode: payload.mode
            )
        #else
            return nil
        #endif
    }

    public static func exportPublicKey(_ value: String) {
        DevelopmentTransportProfile.exportPublicKey(value)
    }

    /// Builds a terminal session whose host-key trust is limited to the
    /// independently staged, one-time development pin.
    public func makeTerminalSession() -> TerminalSession {
        TerminalSession(
            endpoint: endpoint,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            credentials: DevelopmentSessionCredentials(
                expectedFingerprint: expectedFingerprint
            )
        )
    }

    /// Builds an RPC session with the same one-time host-key pin.
    public func makeRPCSession() -> RPCSession {
        RPCSession(
            endpoint: endpoint,
            workingDirectory: workingDirectory,
            credentials: DevelopmentSessionCredentials(
                expectedFingerprint: expectedFingerprint
            )
        )
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.hasPrefix("SHA256:") && value.count <= 80 && value.dropFirst(7).allSatisfy {
            $0.isLetter || $0.isNumber || "+/".contains($0)
        }
    }

    private struct Payload: Decodable {
        let connectionString: String
        let expectedFingerprints: [String]
        let sessionName: String
        let workingDirectory: String
        let mode: Mode
    }
}

private struct DevelopmentSessionCredentials: SSHSessionCredentials {
    let expectedFingerprint: String
    private let store = SecureTransportStore.shared

    func privateKey() async throws -> Curve25519.Signing.PrivateKey {
        try await store.privateKey()
    }

    func fingerprint(for _: RemoteEndpoint) async throws -> String? {
        expectedFingerprint
    }

    func save(fingerprint _: String, for _: RemoteEndpoint) async throws {
        // The staged pin is read-only and the profile is deleted at launch.
    }
}
