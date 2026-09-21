import Foundation

enum TransportDiagnostic: Equatable, Sendable {
    case authenticationFailed
    case cancelled
    case commandFailed
    case connectionFailed
    case duplicateProbe
    case hostKeyChanged
    case invalidEndpoint
    case keyUnavailable

    var userMessage: String {
        switch self {
        case .authenticationFailed:
            "Authentication failed. Verify the selected method and remote authorization."
        case .cancelled:
            "The probe was cancelled."
        case .commandFailed:
            "The harmless probe did not return the expected result."
        case .connectionFailed:
            "The SSH connection failed. Check Tailscale and remote SSH availability."
        case .duplicateProbe:
            "A probe is already running."
        case .hostKeyChanged:
            "The saved host key changed. RoamPi blocked the connection before authentication."
        case .invalidEndpoint:
            "Enter a valid user@host value and optional port."
        case .keyUnavailable:
            "The device key is unavailable."
        }
    }
}

enum TransportError: Error, Equatable, Sendable {
    case diagnostic(TransportDiagnostic)
    case hostKeyConfirmationRequired(fingerprint: String)
}
