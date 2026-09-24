import Darwin
import Foundation

/// Small local profile file. Each operation reads the current file before a
/// change; failures never replace a saved set with an empty one.
public actor ConnectionStore {
    private struct Document: Codable {
        let version: Int
        var profiles: [ConnectionProfile]
    }

    private static let version = 1
    private static let maximumProfiles = 128
    private static let maximumBytes = 128 * 1024
    private static let filename = "connection-profiles.json"
    private static let processLock = NSLock()

    private let directoryURL: URL
    private var fileURL: URL {
        directoryURL.appendingPathComponent(Self.filename)
    }

    /// Supply a disposable directory in tests. The production store belongs in
    /// this app's Application Support directory, never a shared or remote path.
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func applicationStore() throws -> ConnectionStore {
        let support: URL
        do {
            support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        } catch {
            throw ConnectionStoreError.storageUnavailable
        }
        return ConnectionStore(directoryURL: support.appendingPathComponent("RoamPi", isDirectory: true))
    }

    public func list() throws -> [ConnectionProfile] {
        try Self.processLock.withLock { try readDocument().profiles }
    }

    public func add(_ profile: ConnectionProfile) throws {
        try Self.processLock.withLock {
            var document = try readDocument()
            guard !document.profiles.contains(where: { $0.id == profile.id }) else {
                throw ConnectionStoreError.duplicateProfile
            }
            guard document.profiles.count < Self.maximumProfiles else {
                throw ConnectionStoreError.storeTooLarge
            }
            document.profiles.append(profile)
            try writeDocument(document)
        }
    }

    public func update(_ profile: ConnectionProfile) throws {
        try Self.processLock.withLock {
            var document = try readDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == profile.id }) else {
                throw ConnectionStoreError.profileNotFound
            }
            document.profiles[index] = profile
            try writeDocument(document)
        }
    }

    public func remove(id: UUID) throws {
        try Self.processLock.withLock {
            var document = try readDocument()
            guard let index = document.profiles.firstIndex(where: { $0.id == id }) else {
                throw ConnectionStoreError.profileNotFound
            }
            document.profiles.remove(at: index)
            try writeDocument(document)
        }
    }

    private func readDocument() throws -> Document {
        guard try checkDirectoryIfPresent() else {
            return Document(version: Self.version, profiles: [])
        }
        let stat = try metadata(at: fileURL)
        guard let stat else { return Document(version: Self.version, profiles: []) }
        guard stat.st_mode & S_IFMT == S_IFREG,
              stat.st_uid == getuid(),
              stat.st_mode & 0o077 == 0,
              stat.st_size >= 0,
              stat.st_size <= Self.maximumBytes
        else {
            throw ConnectionStoreError.corruptStore
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= Self.maximumBytes else { throw ConnectionStoreError.corruptStore }
            // Check the version before decoding profiles so a future schema is
            // never misreported as ordinary corruption or overwritten.
            let header = try JSONDecoder().decode(VersionHeader.self, from: data)
            guard header.version == Self.version else { throw ConnectionStoreError.unsupportedVersion }
            try validateFields(in: data)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.profiles.count <= Self.maximumProfiles,
                  Set(document.profiles.map(\.id)).count == document.profiles.count
            else {
                throw ConnectionStoreError.corruptStore
            }
            return document
        } catch let error as ConnectionStoreError {
            throw error
        } catch {
            throw ConnectionStoreError.corruptStore
        }
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    /// Codable otherwise discards unknown fields, including accidentally
    /// serialized secret-bearing ones. The version must change for a new field.
    private func validateFields(in data: Data) throws {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let document = value as? [String: Any],
              Set(document.keys) == ["version", "profiles"],
              let profiles = document["profiles"] as? [[String: Any]],
              profiles.count <= Self.maximumProfiles
        else {
            throw ConnectionStoreError.corruptStore
        }
        let required: Set = [
            "id", "displayName", "connectionString", "port", "projectDirectory",
            "sessionChoice", "credentialReference",
        ]
        for profile in profiles {
            let fields = Set(profile.keys)
            guard fields == required || fields == required.union(["tmuxSessionName"]) else {
                throw ConnectionStoreError.corruptStore
            }
        }
    }

    private func writeDocument(_ document: Document) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(document)
            guard data.count <= Self.maximumBytes else { throw ConnectionStoreError.storeTooLarge }
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard try checkDirectoryIfPresent() else { throw ConnectionStoreError.storageUnavailable }
            let temporary = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let result = temporary.path.withCString { source in
                fileURL.path.withCString { destination in
                    Darwin.rename(source, destination)
                }
            }
            guard result == 0 else { throw ConnectionStoreError.storageUnavailable }
        } catch let error as ConnectionStoreError {
            throw error
        } catch {
            throw ConnectionStoreError.storageUnavailable
        }
    }

    private func checkDirectoryIfPresent() throws -> Bool {
        guard let stat = try metadata(at: directoryURL) else { return false }
        guard stat.st_mode & S_IFMT == S_IFDIR,
              stat.st_uid == getuid(),
              stat.st_mode & 0o077 == 0
        else {
            throw ConnectionStoreError.storageUnavailable
        }
        return true
    }

    /// lstat refuses symlinks at both the directory and file boundary.
    private func metadata(at url: URL) throws -> stat? {
        var value = stat()
        let result = url.path.withCString { Darwin.lstat($0, &value) }
        if result == 0 {
            return value
        }
        if errno == ENOENT {
            return nil
        }
        throw ConnectionStoreError.storageUnavailable
    }
}

public enum ConnectionStoreError: Error, Equatable, Sendable {
    case corruptStore
    case duplicateProfile
    case profileNotFound
    case storageUnavailable
    case storeTooLarge
    case unsupportedVersion

    public var userMessage: String {
        switch self {
        case .corruptStore: "Saved connections could not be read. Your data was not replaced."
        case .duplicateProfile: "This connection is already saved."
        case .profileNotFound: "This saved connection no longer exists."
        case .storageUnavailable: "Saved connections are unavailable on this device."
        case .storeTooLarge: "The saved connection limit was reached."
        case .unsupportedVersion: "Saved connections use a newer format. Update RoamPi before editing them."
        }
    }
}
