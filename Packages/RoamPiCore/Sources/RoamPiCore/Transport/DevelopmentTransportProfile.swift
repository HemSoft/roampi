import Foundation

public struct DevelopmentTransportProfile: Sendable {
    public static let launchArgument = "--install-development-transport-profile"

    public let endpoint: RemoteEndpoint
    public let expectedFingerprints: Set<String>

    public static func consumeIfRequested(arguments: [String]) -> DevelopmentTransportProfile? {
        #if DEBUG
            guard arguments.contains(launchArgument) else { return nil }

            let manager = FileManager.default
            guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                return nil
            }
            let url = caches.appendingPathComponent("roampi-development-transport-profile.json")
            try? manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            defer { try? manager.removeItem(at: url) }

            guard let data = try? Data(contentsOf: url), data.count <= 4096,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let endpoint = try? RemoteEndpoint(connectionString: payload.connectionString),
                  !payload.expectedFingerprints.isEmpty,
                  payload.expectedFingerprints.count <= 10,
                  payload.expectedFingerprints.allSatisfy(Self.isValidFingerprint)
            else {
                return nil
            }

            return DevelopmentTransportProfile(
                endpoint: endpoint,
                expectedFingerprints: Set(payload.expectedFingerprints)
            )
        #else
            return nil
        #endif
    }

    public static func exportPublicKey(_ value: String) {
        #if DEBUG
            guard value.hasPrefix("ssh-ed25519 "), value.utf8.count <= 1024,
                  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else {
                return
            }
            let url = caches.appendingPathComponent("roampi-development-public-key.txt")
            do {
                try Data(value.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        #endif
    }

    private static func isValidFingerprint(_ value: String) -> Bool {
        value.hasPrefix("SHA256:") && value.count <= 80 && value.dropFirst(7).allSatisfy {
            $0.isLetter || $0.isNumber || "+/".contains($0)
        }
    }

    private struct Payload: Decodable {
        let connectionString: String
        let expectedFingerprints: [String]
    }
}
