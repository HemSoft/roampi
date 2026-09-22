import Foundation

public enum SSHAuthenticationMode: String, CaseIterable, Identifiable, Sendable {
    case standardKey
    case tailscaleSSHThenKey

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .standardKey:
            "Ed25519 key"
        case .tailscaleSSHThenKey:
            "Tailscale SSH, then key"
        }
    }
}

public enum SSHAuthenticationOffer: Equatable, Sendable {
    case none
    case publicKey
}

struct SSHAuthenticationPlan: Sendable {
    static let serviceName = "ssh-connection"

    private(set) var remainingOffers: [SSHAuthenticationOffer]

    init(mode: SSHAuthenticationMode) {
        switch mode {
        case .standardKey:
            remainingOffers = [.publicKey]
        case .tailscaleSSHThenKey:
            remainingOffers = [.none, .publicKey]
        }
    }

    mutating func nextOffer(serverAllowsPublicKey: Bool) -> SSHAuthenticationOffer? {
        while !remainingOffers.isEmpty {
            let next = remainingOffers.removeFirst()
            if next == .publicKey, !serverAllowsPublicKey {
                continue
            }
            return next
        }
        return nil
    }
}
