import Crypto
import Foundation
import NIOSSH
import Security

actor SecureTransportStore {
    private enum Account {
        static let privateKey = "transport-ed25519-v1"

        static func hostKey(for endpoint: RemoteEndpoint) -> String {
            let digest = SHA256.hash(data: Data(endpoint.hostIdentity.utf8))
            return "host-\(digest.map { String(format: "%02x", $0) }.joined())"
        }
    }

    private let service = "com.hemsoft.RoamPi.transport"

    func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let stored = try read(account: Account.privateKey) {
            do {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
            } catch {
                throw TransportError.diagnostic(.keyUnavailable)
            }
        }

        let key = Curve25519.Signing.PrivateKey()
        try write(Data(key.rawRepresentation), account: Account.privateKey)
        return key
    }

    func publicKey() throws -> String {
        let key = try privateKey()
        return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey)
    }

    func fingerprint(for endpoint: RemoteEndpoint) throws -> String? {
        guard let data = try read(account: Account.hostKey(for: endpoint)),
              let fingerprint = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return fingerprint
    }

    func save(fingerprint: String, for endpoint: RemoteEndpoint) throws {
        try write(Data(fingerprint.utf8), account: Account.hostKey(for: endpoint))
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw TransportError.diagnostic(.keyUnavailable)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw TransportError.diagnostic(.keyUnavailable)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                throw TransportError.diagnostic(.keyUnavailable)
            }
        } else if updateStatus != errSecSuccess {
            throw TransportError.diagnostic(.keyUnavailable)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
