import Darwin
import NIOCore
import NIOPosix

/// Classifies only pre-authentication connect failures. Never displays the
/// underlying error: NIO errors can contain a user name, address, or port.
enum ProbeConnectionFailure {
    static func diagnostic(for error: Error) -> TransportDiagnostic {
        if let attempts = error as? NIOConnectionError {
            if !attempts.connectionErrors.isEmpty {
                let reasons = attempts.connectionErrors.map { reason(for: $0.error) }
                if reasons.allSatisfy({ $0 == .connectionRefused }) {
                    return .connectionRefused
                }
                if reasons.contains(.timedOut) {
                    return .timedOut
                }
                return .connectionFailed
            }
            if attempts.dnsAError != nil || attempts.dnsAAAAError != nil {
                return .dnsFailed
            }
        }
        if error is SocketAddressError.UnknownHost {
            return .dnsFailed
        }
        if let addressError = error as? SocketAddressError,
           case .unknown = addressError
        {
            return .dnsFailed
        }
        return reason(for: error)
    }

    private static func reason(for error: Error) -> TransportDiagnostic {
        if let io = error as? IOError {
            switch io.errnoCode {
            case ECONNREFUSED: return .connectionRefused
            case ETIMEDOUT: return .timedOut
            default: return .connectionFailed
            }
        }
        if let channel = error as? ChannelError,
           case .connectTimeout = channel
        {
            return .timedOut
        }
        return .connectionFailed
    }
}
