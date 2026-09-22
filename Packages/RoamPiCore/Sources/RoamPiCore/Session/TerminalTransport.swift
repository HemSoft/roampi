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

/// Ensures one terminal channel reports at most one closure, even when an
/// overflow-triggered close is followed by the transport's real callback.
final class OneShotTerminalClosureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

struct TmuxPaneIdentity: Equatable, Sendable {
    let processID: Int32
    let executable: String
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
    private let paneCommand: String
    private let compatiblePaneExecutables: Set<String>
    private let attachExisting: Bool
    private let credentials: any SSHSessionCredentials
    private let closureGate = OneShotTerminalClosureGate()

    private let lock = NSLock()
    private var connection: SSHSessionConnection?
    private var channel: SSHSessionChannel?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var exitStatus: Int32?
    private var isClosed = false

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
        paneCommand: String = "exec pi",
        attachExisting: Bool = false,
        credentials: any SSHSessionCredentials = SecureTransportStore.shared
    ) {
        self.endpoint = endpoint
        self.authentication = authentication
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
        self.terminalType = terminalType
        self.paneCommand = paneCommand
        compatiblePaneExecutables = Self.compatiblePaneExecutables(for: paneCommand)
        self.attachExisting = attachExisting
        self.credentials = credentials
    }

    func open(columns: Int, rows: Int) async throws -> any TerminalChannel {
        guard !lock.withLock({ isClosed }) else {
            throw SessionDiagnostic.cancelled
        }

        let connection: SSHSessionConnection
        if let existing = lock.withLock({ self.connection }) {
            connection = existing
        } else {
            let transport = SSHSessionTransport(credentials: credentials)
            connection = try await transport.connect(
                endpoint: endpoint,
                mode: authentication
            )
            let closeImmediately = lock.withLock {
                guard !isClosed else { return true }
                self.connection = connection
                return false
            }
            if closeImmediately {
                await connection.close()
                throw SessionDiagnostic.cancelled
            }
        }

        do {
            let existingIdentity: (processID: Int32, command: String)? = if attachExisting {
                nil
            } else {
                try await queryPaneIdentity(connection: connection)
            }
            if let existingIdentity,
               !compatiblePaneExecutables.contains(existingIdentity.command)
            {
                throw SessionDiagnostic.processIdentityChanged
            }
            let shouldAttachExisting = attachExisting || existingIdentity != nil
            let attachCommand = if shouldAttachExisting {
                TmuxCommand.attachExisting(
                    session: sessionName,
                    workingDirectory: workingDirectory
                )
            } else {
                TmuxCommand.attachOrCreate(
                    session: sessionName,
                    workingDirectory: workingDirectory,
                    paneCommand: paneCommand
                )
            }
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
            sessionChannel.onOutputOverflow = { [weak self, weak sessionChannel] in
                self?.reportClosure(exitStatus: 1)
                if let sessionChannel {
                    Task { await sessionChannel.close() }
                }
            }
            sessionChannel.onExit = { [weak self] status in
                self?.lock.withLock { self?.exitStatus = status }
            }
            sessionChannel.onClosed = { [weak self] in
                guard let self else { return }
                let exitStatus = lock.withLock { self.exitStatus }
                reportClosure(exitStatus: exitStatus)
            }

            lock.withLock { self.channel = sessionChannel }
            return sessionChannel
        } catch {
            await connection.close()
            lock.withLock { self.connection = nil }
            throw error
        }
    }

    static func compatiblePaneExecutables(for paneCommand: String) -> Set<String> {
        let commandParts = paneCommand.split(separator: " ")
        let launcher: String = if commandParts.count == 2, commandParts[0] == "exec" {
            URL(fileURLWithPath: String(commandParts[1])).lastPathComponent
        } else {
            "pi"
        }
        // The npm-installed Pi launcher uses a Node shebang, so tmux reports
        // the direct pane process as `node` even though the command was `pi`.
        return launcher == "pi" ? ["pi", "node"] : [launcher]
    }

    private func reportClosure(exitStatus: Int32?) {
        guard closureGate.claim() else { return }
        lock.withLock { closedHandler }?(exitStatus)
    }

    /// Queries the tmux pane process ID for the configured session on a second
    /// exec channel of the same connection. Reconnect logic compares this
    /// value against the identity recorded before the interruption.
    func paneIdentity() async throws -> TmuxPaneIdentity? {
        let connection: SSHSessionConnection? = lock.withLock { self.connection }
        guard let connection else {
            throw SessionDiagnostic.notAttached
        }
        guard let identity = try await queryPaneIdentity(connection: connection) else {
            return nil
        }
        guard compatiblePaneExecutables.contains(identity.command) else {
            throw SessionDiagnostic.processIdentityChanged
        }
        return TmuxPaneIdentity(
            processID: identity.processID,
            executable: identity.command
        )
    }

    private func queryPaneIdentity(
        connection: SSHSessionConnection
    ) async throws -> (processID: Int32, command: String)? {
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

        for attempt in 0 ..< 200 {
            if collector.isComplete {
                if let failure = collector.failureDiagnostic {
                    throw failure
                }
                if let processID = collector.paneProcessID,
                   let command = collector.paneCommand
                {
                    return (processID, command)
                }
                if attempt >= 10 {
                    return nil
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw SessionDiagnostic.timedOut
    }

    func close() async throws {
        let resources: Resources = lock.withLock {
            isClosed = true
            let resources = Resources(channel: channel, connection: connection)
            channel = nil
            connection = nil
            return resources
        }
        await resources.channel?.close()
        await resources.connection?.close()
    }
}

/// Collects one strictly bounded decimal pane process ID from an exec channel.
final class PaneProcessIDCollector: @unchecked Sendable {
    private static let maxResponseBytes = 64
    private static let whitespace = CharacterSet(charactersIn: " \t\r\n")

    private let lock = NSLock()
    private var data = Data()
    private var done = false
    private var invalid = false
    private var overflowed = false

    func feed(_ chunk: Data) {
        lock.withLock {
            if done, data.isEmpty {
                done = false
            }
            guard !done else { return }
            guard data.count + chunk.count <= Self.maxResponseBytes else {
                invalid = true
                overflowed = true
                done = true
                return
            }
            data.append(chunk)
            if data.contains(where: { byte in
                let isDigit = (0x30 ... 0x39).contains(byte)
                let isLetter = (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
                return !isDigit && !isLetter && ![0x09, 0x0A, 0x0D, 0x20, 0x2D, 0x2E, 0x5F].contains(byte)
            }) {
                invalid = true
                done = true
                return
            }
            if data.contains(0x0A) {
                validateAndFinish()
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !done else { return }
            if data.isEmpty {
                done = true
            } else {
                validateAndFinish()
            }
        }
    }

    var isComplete: Bool {
        lock.withLock { done }
    }

    var failed: Bool {
        lock.withLock { invalid }
    }

    var failureDiagnostic: SessionDiagnostic? {
        lock.withLock {
            guard invalid else { return nil }
            return overflowed ? .frameTooLarge : .malformedFrame
        }
    }

    var paneProcessID: Int32? {
        lock.withLock { parsedIdentity()?.processID }
    }

    var paneCommand: String? {
        lock.withLock { parsedIdentity()?.command }
    }

    private func validateAndFinish() {
        invalid = parsedIdentity() == nil
        done = true
    }

    private func parsedIdentity() -> (processID: Int32, command: String)? {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: Self.whitespace)
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2,
              parts[0].utf8.count <= 10,
              let processID = Int32(parts[0]),
              !parts[1].isEmpty,
              parts[1].utf8.count <= 32
        else {
            return nil
        }
        return (processID, String(parts[1]))
    }
}
