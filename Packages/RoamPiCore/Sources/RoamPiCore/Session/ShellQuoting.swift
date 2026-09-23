import Foundation

/// POSIX shell quoting for values that have already passed validation.
/// Only values validated by `TmuxSessionName` or `RemoteWorkingDirectory` reach
/// this helper; it still refuses control characters defensively.
enum ShellQuoting {
    /// Quote one argument so the remote login shell treats it as a single word.
    static func quote(_ value: String) -> String {
        precondition(
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            "Control characters must be rejected by validation before quoting"
        )
        if value.isEmpty {
            return "''"
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

/// A validated tmux session name. tmux target syntax reserves separators such
/// as `:` and `.`, and the shell treats many characters specially, so only a
/// small safe alphabet is accepted.
public struct TmuxSessionName: Equatable, Sendable {
    static let maximumLength = 64

    public let rawValue: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumLength,
              trimmed.unicodeScalars.allSatisfy(Self.isAllowedScalar),
              let first = trimmed.unicodeScalars.first,
              Self.isAllowedFirstScalar(first)
        else {
            return nil
        }
        self.rawValue = trimmed
    }

    private static func isAllowedFirstScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar)
            || ("A" ... "Z").contains(scalar)
            || ("0" ... "9").contains(scalar)
            || scalar == "_"
    }

    private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        isAllowedFirstScalar(scalar) || scalar == "-"
    }
}

/// A validated absolute working directory for remote sessions. The directory
/// comes from the user's saved profile, so it is treated as untrusted input:
/// absolute paths only, no traversal components, and a small character set.
public struct RemoteWorkingDirectory: Equatable, Sendable {
    static let maximumLength = 256

    public let absolutePath: String

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.utf8.isEmpty,
              trimmed.utf8.count <= Self.maximumLength,
              trimmed.unicodeScalars.allSatisfy(Self.isAllowedScalar)
        else {
            return nil
        }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard components.allSatisfy(Self.isValidComponent) else {
            return nil
        }

        if trimmed == "/" {
            absolutePath = "/"
        } else {
            absolutePath = "/" + components.joined(separator: "/")
        }
    }

    private static func isAllowedScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar)
            || ("A" ... "Z").contains(scalar)
            || ("0" ... "9").contains(scalar)
            || scalar == "/"
            || scalar == "_"
            || scalar == "-"
            || scalar == "."
            || scalar == " "
    }

    private static func isValidComponent(_ component: Substring) -> Bool {
        switch component {
        case ".", "..", "-", " ":
            false
        default:
            true
        }
    }
}
