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

public enum RoamPiActionTrustIdentityBuilder {
    public static func configurationHash(for canonicalConfiguration: Data) -> String {
        digest(canonicalConfiguration)
    }

    public static func build(
        action: EffectiveRoamPiAction,
        resolvedHost: String,
        resolvedWorkingDirectory: String
    ) throws -> RoamPiActionTrustIdentity {
        try build(
            action: action.action,
            sourceFile: action.sourceFile,
            resolvedHost: resolvedHost,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            configurationHash: action.configurationHash
        )
    }

    public static func build(
        action: RoamPiAction,
        sourceFile: String,
        resolvedHost: String,
        resolvedWorkingDirectory: String,
        canonicalConfiguration: Data
    ) throws -> RoamPiActionTrustIdentity {
        try build(
            action: action,
            sourceFile: sourceFile,
            resolvedHost: resolvedHost,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            configurationHash: configurationHash(for: canonicalConfiguration)
        )
    }

    public static func build(
        action: RoamPiAction,
        sourceFile: String,
        resolvedHost: String,
        resolvedWorkingDirectory: String,
        configurationHash: String
    ) throws -> RoamPiActionTrustIdentity {
        guard isBoundedValue(sourceFile, maximumBytes: 512),
              isBoundedValue(resolvedHost, maximumBytes: 253),
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

        var identityData = Data()
        for value in [
            sourceFile,
            action.id,
            payload,
            resolvedHost,
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
