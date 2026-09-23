import Foundation

public struct RemoteEndpoint: Equatable, Sendable {
    public static let defaultPort = 22

    public let username: String
    public let host: String
    public let port: Int

    public var hostIdentity: String {
        "\(host.lowercased()):\(port)"
    }

    public init(connectionString: String, advancedPort: String? = nil) throws {
        let input = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let separator = input.firstIndex(of: "@"),
              input[separator...].dropFirst().firstIndex(of: "@") == nil
        else {
            throw RemoteEndpointError.invalidConnectionString
        }

        let username = String(input[..<separator])
        let destination = String(input[input.index(after: separator)...])
        guard Self.isValidUsername(username) else {
            throw RemoteEndpointError.invalidUsername
        }

        let parsed = try Self.parseDestination(destination)
        let explicitPort = try Self.parseAdvancedPort(advancedPort)
        if parsed.port != nil, explicitPort != nil {
            throw RemoteEndpointError.duplicatePort
        }

        self.username = username
        host = parsed.host
        port = parsed.port ?? explicitPort ?? Self.defaultPort
    }

    private static func parseDestination(_ destination: String) throws -> (host: String, port: Int?) {
        guard !destination.isEmpty else {
            throw RemoteEndpointError.invalidHost
        }

        if destination.hasPrefix("[") {
            guard let closingBracket = destination.firstIndex(of: "]") else {
                throw RemoteEndpointError.invalidHost
            }
            let hostStart = destination.index(after: destination.startIndex)
            let host = String(destination[hostStart ..< closingBracket])
            let suffix = destination[destination.index(after: closingBracket)...]
            guard isValidIPv6Literal(host) else {
                throw RemoteEndpointError.invalidHost
            }
            if suffix.isEmpty {
                return (host, nil)
            }
            guard suffix.first == ":" else {
                throw RemoteEndpointError.invalidHost
            }
            return try (host, parsePort(String(suffix.dropFirst())))
        }

        let colonCount = destination.filter { $0 == ":" }.count
        if colonCount > 1 {
            guard isValidIPv6Literal(destination) else {
                throw RemoteEndpointError.invalidHost
            }
            return (destination, nil)
        }

        if let colon = destination.lastIndex(of: ":") {
            let host = String(destination[..<colon])
            let port = String(destination[destination.index(after: colon)...])
            guard isValidHost(host) else {
                throw RemoteEndpointError.invalidHost
            }
            return try (host, parsePort(port))
        }

        guard isValidHost(destination) else {
            throw RemoteEndpointError.invalidHost
        }
        return (destination, nil)
    }

    private static func parseAdvancedPort(_ value: String?) throws -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try parsePort(trimmed)
    }

    private static func parsePort(_ value: String) throws -> Int {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let port = Int(value),
              (1 ... 65535).contains(port)
        else {
            throw RemoteEndpointError.invalidPort
        }
        return port
    }

    private static func isValidUsername(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy {
            $0.isLetter || $0.isNumber || "._-".contains($0)
        }
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        if isValidIPv4Literal(value) {
            return true
        }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
                label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func isValidIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && Int(part).map { (0 ... 255).contains($0) } == true
        }
    }

    private static func isValidIPv6Literal(_ value: String) -> Bool {
        let parts = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addressPart = parts.first, !addressPart.isEmpty else { return false }
        if parts.count == 2 {
            let scope = parts[1]
            guard !scope.isEmpty, scope.utf8.count <= 63, scope.utf8.allSatisfy({ byte in
                switch byte {
                case 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                    true
                default:
                    false
                }
            }) else {
                return false
            }
        }
        var address = in6_addr()
        return addressPart.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}

public enum RemoteEndpointError: Error, Equatable {
    case duplicatePort
    case invalidConnectionString
    case invalidHost
    case invalidPort
    case invalidUsername
}
