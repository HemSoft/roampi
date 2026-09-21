import Foundation

enum HostKeyDecision: Equatable, Sendable {
    case confirm(fingerprint: String)
    case trusted
    case changed
}

enum HostKeyPolicy {
    static func evaluate(storedFingerprint: String?, presentedFingerprint: String) -> HostKeyDecision {
        guard let storedFingerprint else {
            return .confirm(fingerprint: presentedFingerprint)
        }
        return storedFingerprint == presentedFingerprint ? .trusted : .changed
    }
}
