import Foundation

/// Byte-level transport for one interactive terminal session.
///
/// The SwiftTerm view lives in the app; this protocol keeps the transport
/// (SSH PTY, or a scripted demo transport) swappable behind `TerminalSession`.
/// Terminal-specific code stays behind `TerminalSession`; SSH details never
/// reach SwiftUI views.
public protocol TerminalTransport: AnyObject, Sendable {
    /// Observed remote bytes destined for the terminal emulator.
    var onOutput: (@Sendable (Data) -> Void)? { get set }
    /// Observed end of the remote session with its optional exit status.
    var onClosed: (@Sendable (_ exitStatus: Int32?) -> Void)? { get set }

    /// Allocates the PTY and starts the approved command. Returns the live
    /// channel for input and resize requests.
    func open(columns: Int, rows: Int) async throws -> any TerminalChannel
    /// Ends this transport without terminating anything remote.
    func close() async throws
}

/// One live terminal channel: input, resize, and close.
public protocol TerminalChannel: Sendable {
    func write(_ data: Data) async throws
    func requestResize(columns: Int, rows: Int) throws
    func close() async
}

/// Concrete type erasure keeps Swift 6.2 from repeatedly lowering protocol
/// existentials through TerminalSession's async reconnect path.
final class TerminalChannelBox: @unchecked Sendable {
    private let base: any TerminalChannel

    init(_ base: any TerminalChannel) {
        self.base = base
    }

    func write(_ data: Data) async throws {
        try await base.write(data)
    }

    func requestResize(columns: Int, rows: Int) throws {
        try base.requestResize(columns: columns, rows: rows)
    }

    func close() async {
        await base.close()
    }
}

final class TerminalTransportBox: @unchecked Sendable {
    private let base: any TerminalTransport

    init(_ base: any TerminalTransport) {
        self.base = base
    }

    var onOutput: (@Sendable (Data) -> Void)? {
        get { base.onOutput }
        set { base.onOutput = newValue }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { base.onClosed }
        set { base.onClosed = newValue }
    }

    var sshTransport: SSHPTYTransport? {
        base as? SSHPTYTransport
    }

    func open(columns: Int, rows: Int) async throws -> TerminalChannelBox {
        try await TerminalChannelBox(base.open(columns: columns, rows: rows))
    }

    func close() async throws {
        try await base.close()
    }
}

/// The SSH PTY transport: connects, allocates a PTY with an explicit terminal
/// type and viewport, and runs the approved tmux attach command.
final class SSHPTYTransport: @unchecked Sendable, TerminalTransport {
    private struct Resources {
        let channel: SSHSessionChannel?
        let connection: SSHSessionConnection?
    }

    private let endpoint: RemoteEndpoint
    private let authentication: SSHAuthenticationMode
    private let sessionName: TmuxSessionName
    private let workingDirectory: RemoteWorkingDirectory
    private let terminalType: String
    private let credentials: any SSHSessionCredentials

    private let lock = NSLock()
    private var connection: SSHSessionConnection?
    private var channel: SSHSessionChannel?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    init(
        endpoint: RemoteEndpoint,
        authentication: SSHAuthenticationMode,
        sessionName: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory,
        terminalType: String = "xterm-256color",
        credentials: any SSHSessionCredentials = SecureTransportStore.shared
    ) {
        self.endpoint = endpoint
        self.authentication = authentication
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
        self.terminalType = terminalType
        self.credentials = credentials
    }

    func open(columns: Int, rows: Int) async throws -> any TerminalChannel {
        let connection: SSHSessionConnection
        if let existing = lock.withLock({ self.connection }) {
            connection = existing
        } else {
            let transport = SSHSessionTransport(credentials: credentials)
            connection = try await transport.connect(
                endpoint: endpoint,
                mode: authentication
            )
            lock.withLock { self.connection = connection }
        }

        do {
            let attachCommand = TmuxCommand.attachOrCreate(
                session: sessionName,
                workingDirectory: workingDirectory
            )
            let sessionChannel = try await connection.openPTYSession(
                command: attachCommand,
                terminalType: terminalType,
                columns: columns,
                rows: rows
            )

            sessionChannel.onOutput = { [weak self] data, isStdErr in
                guard !isStdErr else { return }
                guard let handler = self?.lock.withLock({ self?.outputHandler }) else {
                    return
                }
                handler(data)
            }
            sessionChannel.onClosed = { [weak self] in
                guard let handler = self?.lock.withLock({ self?.closedHandler }) else {
                    return
                }
                handler(nil)
            }

            lock.withLock { self.channel = sessionChannel }
            return sessionChannel
        } catch {
            await connection.close()
            lock.withLock { self.connection = nil }
            throw error
        }
    }

    /// Queries the tmux pane process ID for the configured session on a second
    /// exec channel of the same connection. Reconnect logic compares this
    /// value against the identity recorded before the interruption.
    func paneProcessID() async throws -> Int32? {
        let connection: SSHSessionConnection? = lock.withLock { connection }
        guard let connection else {
            throw SessionDiagnostic.notAttached
        }
        let command = TmuxCommand.paneProcessID(session: sessionName)
        let channel = try await connection.openExecSession(command: command)
        defer { Task { await channel.close() } }

        let collector = PaneProcessIDCollector()
        channel.onOutput = { data, isStdErr in
            guard !isStdErr else { return }
            collector.feed(data)
        }
        channel.onClosed = {
            collector.finish()
        }

        for _ in 0 ..< 200 {
            if collector.isComplete {
                return collector.paneProcessID
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SessionDiagnostic.timedOut
    }

    func close() async throws {
        let resources: Resources = lock.withLock {
            let resources = Resources(channel: channel, connection: connection)
            channel = nil
            connection = nil
            return resources
        }
        await resources.channel?.close()
        await resources.connection?.close()
    }
}

/// Collects one pane process ID from an exec channel.
private final class PaneProcessIDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var done = false

    func feed(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            done = data.contains(0x0A)
        }
    }

    func finish() {
        lock.withLock {
            done = true
        }
    }

    var isComplete: Bool {
        lock.withLock { done }
    }

    var paneProcessID: Int32? {
        lock.withLock {
            guard done else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int32(text)
        }
    }
}
