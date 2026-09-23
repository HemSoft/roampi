import Crypto
import Foundation

public struct RoamPiActionTrustIdentity: Equatable, Sendable {
    public let value: String
    public let configurationHash: String

    public init(value: String, configurationHash: String) {
        self.value = value
        self.configurationHash = configurationHash
    }
}

public struct RoamPiResolvedSSHDestination: Equatable, Sendable {
    public let host: String
    public let username: String
    public let port: Int

    public init(host: String, username: String, port: Int) {
        self.host = host
        self.username = username
        self.port = port
    }
}

public struct EffectiveRoamPiAction: Equatable, Sendable {
    public let action: RoamPiAction
    public let sourceFile: String
    public let configurationHash: String

    public init(action: RoamPiAction, sourceFile: String, configurationHash: String) {
        self.action = action
        self.sourceFile = sourceFile
        self.configurationHash = configurationHash
    }
}

public struct EffectiveRoamPiDataSource: Equatable, Sendable {
    public let dataSource: RoamPiDataSource
    public let sourceFile: String
    public let configurationHash: String

    public var requiresApproval: Bool {
        dataSource.type == .command
    }

    public init(dataSource: RoamPiDataSource, sourceFile: String, configurationHash: String) {
        self.dataSource = dataSource
        self.sourceFile = sourceFile
        self.configurationHash = configurationHash
    }
}

public enum RoamPiActionTrustIdentityBuilder {
    public static func configurationHash(for canonicalConfiguration: Data) -> String {
        digest(canonicalConfiguration)
    }

    public static func build(
        action: EffectiveRoamPiAction,
        resolvedDestination: RoamPiResolvedSSHDestination,
        resolvedWorkingDirectory: String
    ) throws -> RoamPiActionTrustIdentity {
        try build(
            action: action.action,
            sourceFile: action.sourceFile,
            resolvedDestination: resolvedDestination,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            configurationHash: action.configurationHash
        )
    }

    public static func build(
        action: RoamPiAction,
        sourceFile: String,
        resolvedDestination: RoamPiResolvedSSHDestination,
        resolvedWorkingDirectory: String,
        canonicalConfiguration: Data
    ) throws -> RoamPiActionTrustIdentity {
        try build(
            action: action,
            sourceFile: sourceFile,
            resolvedDestination: resolvedDestination,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            configurationHash: configurationHash(for: canonicalConfiguration)
        )
    }

    public static func build(
        action: RoamPiAction,
        sourceFile: String,
        resolvedDestination: RoamPiResolvedSSHDestination,
        resolvedWorkingDirectory: String,
        configurationHash: String
    ) throws -> RoamPiActionTrustIdentity {
        let payload: String
        switch action.type {
        case .prompt:
            guard let prompt = action.prompt else {
                throw RoamPiConfigurationDiagnostic(code: .missingValue, location: "$action.prompt")
            }
            payload = "prompt\u{0}" + prompt
        case .command:
            guard let command = action.command else {
                throw RoamPiConfigurationDiagnostic(code: .missingValue, location: "$action.command")
            }
            payload = "command\u{0}" + command
        }
        return try buildCommandIdentity(
            identifier: action.id,
            payload: payload,
            sourceFile: sourceFile,
            resolvedDestination: resolvedDestination,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            configurationHash: configurationHash
        )
    }

    public static func build(
        dataSource: EffectiveRoamPiDataSource,
        resolvedDestination: RoamPiResolvedSSHDestination,
        resolvedWorkingDirectory: String
    ) throws -> RoamPiActionTrustIdentity {
        guard dataSource.requiresApproval, let command = dataSource.dataSource.command else {
            throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: "$dataSource.command")
        }
        return try buildCommandIdentity(
            identifier: dataSource.dataSource.id,
            payload: "data-source-command\u{0}" + command,
            sourceFile: dataSource.sourceFile,
            resolvedDestination: resolvedDestination,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            configurationHash: dataSource.configurationHash
        )
    }

    private static func buildCommandIdentity(
        identifier: String,
        payload: String,
        sourceFile: String,
        resolvedDestination: RoamPiResolvedSSHDestination,
        resolvedWorkingDirectory: String,
        configurationHash: String
    ) throws -> RoamPiActionTrustIdentity {
        guard isBoundedValue(sourceFile, maximumBytes: 512),
              isBoundedValue(identifier, maximumBytes: 128),
              isBoundedValue(resolvedDestination.host, maximumBytes: 253),
              isBoundedValue(resolvedDestination.username, maximumBytes: 64),
              (1 ... 65535).contains(resolvedDestination.port),
              isSafeAbsolutePath(resolvedWorkingDirectory)
        else {
            throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: "$trust")
        }
        guard configurationHash.utf8.count == 64,
              configurationHash.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else {
            throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: "$trust.configurationHash")
        }

        var identityData = Data()
        for value in [
            sourceFile,
            identifier,
            payload,
            resolvedDestination.host,
            resolvedDestination.username,
            String(resolvedDestination.port),
            resolvedWorkingDirectory,
            configurationHash,
        ] {
            appendLengthPrefixed(value, to: &identityData)
        }
        return RoamPiActionTrustIdentity(
            value: digest(identityData),
            configurationHash: configurationHash
        )
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isBoundedValue(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        isBoundedValue(value, maximumBytes: 256) && value.hasPrefix("/") &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
