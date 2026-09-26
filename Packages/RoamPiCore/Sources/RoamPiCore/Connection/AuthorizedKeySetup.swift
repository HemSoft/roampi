import Foundation

/// A command for the user to review and run in the already authorized account's
/// shell on the host. RoamPi never executes it. Repeating it adds no duplicate.
public struct AuthorizedKeySetup: Equatable, Sendable {
    public let command: String

    public init?(publicKey: String) {
        let parts = publicKey.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "ssh-ed25519",
              parts[1].utf8.count <= 128,
              parts[1].utf8.allSatisfy({
                  (65 ... 90).contains($0) || (97 ... 122).contains($0)
                      || (48 ... 57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61
              }),
              let decoded = Data(base64Encoded: String(parts[1])),
              decoded.count == 51,
              decoded.prefix(4).elementsEqual([0, 0, 0, 11]),
              decoded.dropFirst(4).prefix(11).elementsEqual("ssh-ed25519".utf8),
              decoded.dropFirst(15).prefix(4).elementsEqual([0, 0, 0, 32])
        else { return nil }

        let key = ShellQuoting.quote(publicKey)
        command = """
        umask 077; mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh" && touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys" && { grep -Fqx -- \(key) "$HOME/.ssh/authorized_keys" || printf '%s\\n' \(key) >> "$HOME/.ssh/authorized_keys"; }
        """
    }
}
