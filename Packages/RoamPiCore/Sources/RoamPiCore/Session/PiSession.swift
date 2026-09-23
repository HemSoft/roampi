import Foundation

/// One Pi session as observed by SwiftUI views. The protocol deliberately keeps
/// SSH, tmux, and JSONL details out of the interface: views observe `phase` and
/// call the five actions, never transport APIs.
public protocol PiSession: Sendable {
    /// Current connection phase. Observable without exposing transport types.
    var phase: PiSessionPhase { get }

    /// Open the session. For terminal mode this allocates a PTY and attaches or
    /// creates the approved tmux session. For RPC mode this starts `pi --mode rpc`.
    func start() async throws

    /// Interrupt the running Pi work. Terminal mode sends an interrupt byte
    /// through the PTY; RPC mode sends the `abort` command.
    func interrupt() async throws

    /// Detach without ending anything remote. The tmux session and Pi process
    /// keep running after the iOS view disconnects.
    func detach() async throws

    /// Reconnect to the same remote session. Must never create a duplicate
    /// tmux session or Pi process.
    func reconnect() async throws

    /// End the iOS-side view of this session. Terminal mode detaches and leaves
    /// tmux running; RPC mode ends the remote process.
    func close() async throws
}

/// Connection phases with distinct disconnect, reconnect, interrupt, detach, and
/// close states so diagnostics stay honest about what happened.
public enum PiSessionPhase: Hashable, Sendable {
    case idle
    case connecting
    case attached
    /// User-requested interrupt is in flight. Returns to `attached`.
    case interrupted
    /// User chose detach. Nothing remote was terminated.
    case detached
    /// Unexpected transport loss. Remote session may still be alive.
    case disconnected
    /// Active reconnect attempt.
    case reconnecting
    /// User closed the view; the session is winding down.
    case closing
    case closed
    case failed(SessionDiagnostic)

    public var userLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .connecting:
            "Connecting"
        case .attached:
            "Attached"
        case .interrupted:
            "Interrupted"
        case .detached:
            "Detached"
        case .disconnected:
            "Disconnected"
        case .reconnecting:
            "Reconnecting"
        case .closing:
            "Closing"
        case .closed:
            "Closed"
        case .failed:
            "Failed"
        }
    }

    /// True when the underlying connection is, or is expected to become, live.
    public var isConnectedOrRecovering: Bool {
        switch self {
        case .connecting, .attached, .interrupted, .reconnecting:
            true
        case .idle, .detached, .disconnected, .closing, .closed, .failed:
            false
        }
    }
}

/// Bounded, redacted diagnostics for session failures. Messages never
/// interpolate usernames, hostnames, commands, paths, or terminal content.
public enum SessionDiagnostic: Error, Equatable, Sendable {
    case authenticationFailed
    case cancelled
    case commandFailed
    case connectionFailed
    case duplicateRequest
    case duplicateSession
    case frameTooLarge
    case hostKeyChanged
    case invalidEndpoint
    case invalidWorkingDirectory
    case invalidSessionName
    case keyUnavailable
    case malformedFrame
    case notAttached
    case invalidState
    case peerClosed
    case processIdentityChanged
    case timedOut
    case unexpectedRemoteClose

    public var userMessage: String {
        switch self {
        case .authenticationFailed:
            "Authentication failed. Verify the selected method and remote authorization."
        case .cancelled:
            "The operation was cancelled."
        case .commandFailed:
            "The remote command failed."
        case .connectionFailed:
            "The SSH connection failed. Check the network route and remote SSH availability."
        case .duplicateRequest:
            "A request with this identifier is already pending."
        case .duplicateSession:
            "A session with this name is already managed in this view."
        case .frameTooLarge:
            "A remote frame exceeded the size limit and the exchange stopped."
        case .hostKeyChanged:
            "The saved host key changed. RoamPi blocked the connection before authentication."
        case .invalidEndpoint:
            "Enter a valid user@host value and optional port."
        case .invalidWorkingDirectory:
            "Enter an approved absolute project directory."
        case .invalidSessionName:
            "Enter a tmux session name using letters, numbers, underscores, or non-leading dashes."
        case .keyUnavailable:
            "The device key is unavailable."
        case .malformedFrame:
            "A remote frame was not valid JSON and the exchange stopped."
        case .notAttached:
            "No terminal session is attached."
        case .invalidState:
            "The session is in a state that does not allow this action."
        case .peerClosed:
            "The remote side closed the session."
        case .processIdentityChanged:
            "The tmux process identity changed. RoamPi stopped before continuing."
        case .timedOut:
            "The remote operation timed out. Check the host and try again."
        case .unexpectedRemoteClose:
            "The remote process ended unexpectedly."
        }
    }
}

/// Combines a diagnostic with the phase it should leave the session in.
public struct SessionFailure: Error, Equatable, Sendable {
    public let diagnostic: SessionDiagnostic
    public let phase: PiSessionPhase
}
