import Foundation

/// Local session defaults for one manually authorized SSH destination. A profile
/// is not a statement of host-key trust or remote readiness.
public struct ConnectionProfile: Codable, Equatable, Sendable, Identifiable {
    public enum SessionChoice: String, Codable, Sendable {
        case terminal
        case nativeRPC
    }

    /// An identifier for a Keychain-managed identity, never key material.
    /// Imported identities can be added in a separately reviewed workflow.
    public enum CredentialReference: String, Codable, Sendable {
        case deviceEd25519 = "transport-ed25519-v1"
    }

    public let id: UUID
    public let displayName: String
    public let endpoint: RemoteEndpoint
    public let projectDirectory: RemoteWorkingDirectory
    public let sessionChoice: SessionChoice
    public let tmuxSessionName: TmuxSessionName?
    public let credentialReference: CredentialReference

    public init(
        id: UUID = UUID(),
        displayName: String,
        connectionString: String,
        advancedPort: String? = nil,
        projectDirectory: String,
        sessionChoice: SessionChoice,
        tmuxSessionName: String? = nil,
        credentialReference: CredentialReference = .deviceEd25519
    ) throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.utf8.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ConnectionProfileError.invalidDisplayName
        }

        let endpoint: RemoteEndpoint
        do {
            endpoint = try RemoteEndpoint(connectionString: connectionString, advancedPort: advancedPort)
        } catch {
            throw ConnectionProfileError.invalidEndpoint
        }
        guard let directory = RemoteWorkingDirectory(projectDirectory) else {
            throw ConnectionProfileError.invalidProjectDirectory
        }
        let sessionName: TmuxSessionName?
        switch sessionChoice {
        case .terminal:
            guard let tmuxSessionName, let validated = TmuxSessionName(tmuxSessionName) else {
                throw ConnectionProfileError.invalidTmuxSessionName
            }
            sessionName = validated
        case .nativeRPC:
            guard tmuxSessionName == nil else {
                throw ConnectionProfileError.invalidSessionChoice
            }
            sessionName = nil
        }

        self.id = id
        self.displayName = name
        self.endpoint = endpoint
        self.projectDirectory = directory
        self.sessionChoice = sessionChoice
        self.tmuxSessionName = sessionName
        self.credentialReference = credentialReference
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, connectionString, port, projectDirectory
        case sessionChoice, tmuxSessionName, credentialReference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            connectionString: container.decode(String.self, forKey: .connectionString),
            advancedPort: String(container.decode(Int.self, forKey: .port)),
            projectDirectory: container.decode(String.self, forKey: .projectDirectory),
            sessionChoice: container.decode(SessionChoice.self, forKey: .sessionChoice),
            tmuxSessionName: container.decodeIfPresent(String.self, forKey: .tmuxSessionName),
            credentialReference: container.decode(CredentialReference.self, forKey: .credentialReference)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
        try container.encode("\(endpoint.username)@\(host)", forKey: .connectionString)
        try container.encode(endpoint.port, forKey: .port)
        try container.encode(projectDirectory.absolutePath, forKey: .projectDirectory)
        try container.encode(sessionChoice, forKey: .sessionChoice)
        try container.encodeIfPresent(tmuxSessionName?.rawValue, forKey: .tmuxSessionName)
        try container.encode(credentialReference, forKey: .credentialReference)
    }
}

public enum ConnectionProfileError: Error, Equatable, Sendable {
    case invalidDisplayName
    case invalidEndpoint
    case invalidProjectDirectory
    case invalidTmuxSessionName
    case invalidSessionChoice

    public var userMessage: String {
        switch self {
        case .invalidDisplayName: "Enter a short display name without control characters."
        case .invalidEndpoint: "Enter a valid SSH user, host, and optional port."
        case .invalidProjectDirectory: "Enter a valid absolute project directory."
        case .invalidTmuxSessionName: "Enter a valid tmux session name for terminal mode."
        case .invalidSessionChoice: "Choose one compatible session mode and name."
        }
    }
}
