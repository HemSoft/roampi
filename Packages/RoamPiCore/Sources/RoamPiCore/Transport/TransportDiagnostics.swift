import Foundation

public enum TransportDiagnostic: Equatable, Sendable {
    case authenticationFailed
    case cancelled
    case commandFailed
    case connectionFailed
    case connectionRefused
    case dnsFailed
    case duplicateProbe
    case hostKeyChanged
    case invalidEndpoint
    case keyUnavailable
    case timedOut

    public var userMessage: String {
        switch self {
        case .authenticationFailed:
            "The host did not accept this device key. Check the account or authorize its public key."
        case .cancelled:
            "The probe was cancelled."
        case .commandFailed:
            "The harmless probe did not return the expected result."
        case .connectionFailed:
            "The SSH connection failed. Check the network route and remote SSH availability."
        case .connectionRefused:
            "The host refused the SSH connection. Check its SSH service and selected port."
        case .dnsFailed:
            "The host name could not be resolved. Check the name or use a reachable IP address."
        case .duplicateProbe:
            "A probe is already running."
        case .hostKeyChanged:
            "The saved host key changed. RoamPi blocked the connection before authentication."
        case .invalidEndpoint:
            "Enter a valid user@host value and optional port."
        case .keyUnavailable:
            "The device key is unavailable."
        case .timedOut:
            "The SSH check timed out. Check the network route or selected port and retry."
        }
    }
}

public enum TransportError: Error, Equatable, Sendable {
    case diagnostic(TransportDiagnostic)
    case hostKeyConfirmationRequired(fingerprint: String)
}
