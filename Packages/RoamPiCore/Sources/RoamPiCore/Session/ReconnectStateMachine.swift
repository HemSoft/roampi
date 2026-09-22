import Foundation

/// Validates phase transitions for one Pi session.
///
/// The transition table keeps disconnect, reconnect, interrupt, detach, and
/// close distinct. Illegal transitions are refused, and a second connection
/// attempt while attached is rejected as a duplicate-session risk.
struct ReconnectStateMachine: Sendable {
    private enum PhaseKey: Hashable {
        case idle
        case connecting
        case attached
        case interrupted
        case detached
        case disconnected
        case reconnecting
        case closing
        case closed
        case failed
    }

    private(set) var phase: PiSessionPhase = .idle

    private static let allowedTransitions: [PhaseKey: Set<PhaseKey>] = [
        .idle: [.connecting, .failed, .closed],
        .connecting: [.attached, .disconnected, .closing, .failed, .closed],
        .attached: [.interrupted, .detached, .disconnected, .closing, .failed],
        .interrupted: [.attached, .detached, .disconnected, .closing, .failed],
        .detached: [.reconnecting, .closing, .failed],
        .disconnected: [.reconnecting, .closing, .failed],
        .reconnecting: [.attached, .disconnected, .closing, .failed],
        .closing: [.closed],
        .closed: [],
        .failed: [.reconnecting, .closing],
    ]

    mutating func beginConnecting() throws {
        try transition(to: .connecting)
    }

    mutating func markAttached() throws {
        try transition(to: .attached)
    }

    mutating func beginInterrupt() throws {
        try transition(to: .interrupted)
    }

    mutating func endInterrupt() throws {
        try transition(to: .attached)
    }

    mutating func detach() throws {
        try transition(to: .detached)
    }

    mutating func markDisconnected() throws {
        try transition(to: .disconnected)
    }

    mutating func beginReconnect() throws {
        try transition(to: .reconnecting)
    }

    mutating func beginClose() throws {
        try transition(to: .closing)
    }

    mutating func markClosed() throws {
        try transition(to: .closed)
    }

    mutating func fail(_ diagnostic: SessionDiagnostic) throws {
        try transition(to: .failed(diagnostic))
    }

    func canTransition(to candidate: PiSessionPhase) -> Bool {
        Self.allowedTransitions[Self.key(for: phase), default: []]
            .contains(Self.key(for: candidate))
    }

    private mutating func transition(to candidate: PiSessionPhase) throws {
        guard canTransition(to: candidate) else {
            throw SessionFailure(diagnostic: .invalidState, phase: phase)
        }
        phase = candidate
    }

    private static func key(for phase: PiSessionPhase) -> PhaseKey {
        switch phase {
        case .idle:
            .idle
        case .connecting:
            .connecting
        case .attached:
            .attached
        case .interrupted:
            .interrupted
        case .detached:
            .detached
        case .disconnected:
            .disconnected
        case .reconnecting:
            .reconnecting
        case .closing:
            .closing
        case .closed:
            .closed
        case .failed:
            .failed
        }
    }
}
