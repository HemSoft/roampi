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

public enum RoamPiActionTrustIdentityBuilder {
    public static func build(
        action: RoamPiAction,
        sourceFile: String,
        resolvedHost: String,
        resolvedWorkingDirectory: String,
        canonicalConfiguration: Data
    ) throws -> RoamPiActionTrustIdentity {
        guard isBoundedValue(sourceFile, maximumBytes: 512),
              isBoundedValue(resolvedHost, maximumBytes: 253),
              isSafeAbsolutePath(resolvedWorkingDirectory)
        else {
            throw RoamPiConfigurationDiagnostic(code: .invalidValue, location: "$trust")
        }

        let configurationHash = digest(canonicalConfiguration)
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
