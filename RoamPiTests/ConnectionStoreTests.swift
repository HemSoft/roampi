import Foundation
@testable import RoamPiCore
import Testing

@Suite("Saved SSH connection profiles")
struct ConnectionStoreTests {
    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("roampi-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func terminalProfile(
        id: UUID = UUID(),
        connectionString: String = "person@host.example.ts.net:2222"
    ) throws -> ConnectionProfile {
        try ConnectionProfile(
            id: id,
            displayName: "Work laptop",
            connectionString: connectionString,
            projectDirectory: "/home/person/project",
            sessionChoice: .terminal,
            tmuxSessionName: "pi_work"
        )
    }

    private func failure(_ operation: () async throws -> Void) async -> ConnectionStoreError? {
        do {
            try await operation()
            return nil
        } catch let error as ConnectionStoreError {
            return error
        } catch {
            return nil
        }
    }

    @Test("CRUD survives a new store with stable ID and non-default port")
    func persistsAcrossRelaunch() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ConnectionStore(directoryURL: directory)
        let profile = try terminalProfile()
        try await first.add(profile)
        let relaunched = ConnectionStore(directoryURL: directory)
        let saved = try #require(await relaunched.list().first)
        #expect(saved == profile)
        #expect(saved.endpoint.port == 2222)
        #expect(saved.id == profile.id)
        #expect(saved.projectDirectory.absolutePath == "/home/person/project")

        let edited = try ConnectionProfile(
            id: saved.id, displayName: "Updated", connectionString: "person@192.0.2.10",
            projectDirectory: "/home/person/project", sessionChoice: .nativeRPC
        )
        try await relaunched.update(edited)
        #expect(try await first.list() == [edited])
        try await first.remove(id: edited.id)
        #expect(try await ConnectionStore(directoryURL: directory).list().isEmpty)
    }

    @Test("IPv6, DNS and IPv4 round-trip through the validated endpoint parser")
    func endpointForms() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directoryURL: directory)
        let inputs = ["person@[fe80::1%en0]:2200", "person@192.0.2.10", "person@pi.example.com"]
        for input in inputs {
            try await store.add(terminalProfile(connectionString: input))
        }
        let read = try await ConnectionStore(directoryURL: directory).list()
        #expect(read.map(\.endpoint.host) == ["fe80::1%en0", "192.0.2.10", "pi.example.com"])
        #expect(read.map(\.endpoint.port) == [2200, 22, 22])
    }

    @Test("Malformed or unsupported data never replaces saved profiles")
    func failsClosedOnCorruptData() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directoryURL: directory)
        let profile = try terminalProfile()
        try await store.add(profile)
        let file = directory.appendingPathComponent("connection-profiles.json")
        let goodData = try Data(contentsOf: file)
        let newer = try #require(String(data: goodData, encoding: .utf8))
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        try Data(newer.utf8).write(to: file)
        #expect(await failure { _ = try await store.list() } == .unsupportedVersion)
        #expect(await failure { try await store.add(profile) } == .unsupportedVersion)
        #expect(try Data(contentsOf: file) == Data(newer.utf8))

        try Data("{invalid-json".utf8).write(to: file)
        #expect(await failure { _ = try await store.list() } == .corruptStore)
        #expect(await failure { try await store.remove(id: profile.id) } == .corruptStore)
        #expect(try Data(contentsOf: file) == Data("{invalid-json".utf8))
    }

    @Test("Duplicate, unknown and malformed profile records are blocked")
    func rejectsDuplicatesAndTampering() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directoryURL: directory)
        let profile = try terminalProfile()
        try await store.add(profile)
        #expect(await failure { try await store.add(profile) } == .duplicateProfile)
        #expect(await failure { try await store.remove(id: UUID()) } == .profileNotFound)
        let file = directory.appendingPathComponent("connection-profiles.json")
        let original = try #require(String(data: Data(contentsOf: file), encoding: .utf8))
        for changed in [
            original.replacingOccurrences(of: "person@host.example.ts.net", with: "person@host;bad.example"),
            original.replacingOccurrences(of: "project", with: ".."),
            original.replacingOccurrences(of: "pi_work", with: "pi;rm"),
            original.replacingOccurrences(of: "transport-ed25519-v1", with: "unknown-key"),
            original.replacingOccurrences(of: "\"profiles\":[", with: "\"password\":\"secret\",\"profiles\":["),
        ] {
            #expect(changed != original)
            try Data(changed.utf8).write(to: file)
            #expect(await failure { _ = try await store.list() } == .corruptStore)
            #expect(try Data(contentsOf: file) == Data(changed.utf8))
        }
    }

    @Test("Unsafe fields never become a profile")
    func rejectsInjection() throws {
        for value in ["person@host;rm", "person@host\nextra", "person@host'bad", "person@host:0"] {
            #expect(throws: ConnectionProfileError.invalidEndpoint) {
                try ConnectionProfile(
                    displayName: "Work",
                    connectionString: value,
                    projectDirectory: "/safe",
                    sessionChoice: .terminal,
                    tmuxSessionName: "pi"
                )
            }
        }
        for path in ["relative/path", "/safe/../secret", "/safe;rm", "/safe\nsecret"] {
            #expect(throws: ConnectionProfileError.invalidProjectDirectory) {
                try ConnectionProfile(
                    displayName: "Work",
                    connectionString: "person@host",
                    projectDirectory: path,
                    sessionChoice: .terminal,
                    tmuxSessionName: "pi"
                )
            }
        }
        #expect(throws: ConnectionProfileError.invalidDisplayName) {
            try ConnectionProfile(
                displayName: "Work\nsecret",
                connectionString: "person@host",
                projectDirectory: "/safe",
                sessionChoice: .terminal,
                tmuxSessionName: "pi"
            )
        }
        #expect(throws: ConnectionProfileError.invalidTmuxSessionName) {
            try ConnectionProfile(
                displayName: "Work",
                connectionString: "person@host",
                projectDirectory: "/safe",
                sessionChoice: .terminal,
                tmuxSessionName: "pi;bad"
            )
        }
        #expect(throws: ConnectionProfileError.invalidSessionChoice) {
            try ConnectionProfile(
                displayName: "Work",
                connectionString: "person@host",
                projectDirectory: "/safe",
                sessionChoice: .nativeRPC,
                tmuxSessionName: "pi"
            )
        }
    }

    @Test("Persisted data contains only metadata and a Keychain reference")
    func redactsSecrets() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directoryURL: directory)
        try await store.add(terminalProfile())
        let file = directory.appendingPathComponent("connection-profiles.json")
        let data = try Data(contentsOf: file)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("transport-ed25519-v1"))
        for sensitive in ["PRIVATE KEY", "password", "auth.json", "fingerprint", "providerToken", "terminalContent"] {
            #expect(!text.contains(sensitive))
        }
        for error in [ConnectionStoreError.corruptStore, .unsupportedVersion, .storageUnavailable] {
            #expect(!error.userMessage.contains("person"))
            #expect(!error.userMessage.contains("/home/"))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions & 0o077 == 0)
    }

    @Test("Oversized and linked storage fails without following another file")
    func refusesUnsafeStorage() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directoryURL: directory)
        let file = directory.appendingPathComponent("connection-profiles.json")
        try Data(repeating: 65, count: 128 * 1024 + 1).write(to: file)
        #expect(await failure { _ = try await store.list() } == .corruptStore)
        try FileManager.default.removeItem(at: file)

        let target = directory.appendingPathComponent("untouched.json")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(await failure { _ = try await store.list() } == .corruptStore)
        #expect(await failure { try await store.add(terminalProfile()) } == .corruptStore)
        #expect(try Data(contentsOf: target) == Data("sentinel".utf8))
    }

    @Test("Read-only listing does not create a file or directory")
    func readWithoutMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("roampi-absent-\(UUID().uuidString)")
        let store = ConnectionStore(directoryURL: directory)
        #expect(try await store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
