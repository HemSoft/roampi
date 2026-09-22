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

    func releaseVerifiedOutput() throws {
        try sshTransport?.releaseVerifiedOutput()
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
    let startCommand: String

    func hasSameProcess(as other: TmuxPaneIdentity) -> Bool {
        processID == other.processID
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
    private let paneCommand: String
    private let compatiblePaneExecutables: Set<String>
    private let attachExisting: Bool
    private let credentials: any SSHSessionCredentials
    private let postPreflightHook: (@Sendable () async throws -> Void)?
    private let closureGate = OneShotTerminalClosureGate()

    private let lock = NSLock()
    private var connection: SSHSessionConnection?
    private var channel: SSHSessionChannel?
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var heldOutput: [Data] = []
    private var heldOutputBytes = 0
    private var heldOutputOverflowed = false
    private var outputVerified = false
    private var adoptedPaneProcessID: Int32?
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
        paneCommand: String = PiTerminalCommand.start,
        attachExisting: Bool = false,
        credentials: any SSHSessionCredentials = SecureTransportStore.shared,
        postPreflightHook: (@Sendable () async throws -> Void)? = nil
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
        self.postPreflightHook = postPreflightHook
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
            let existingIdentity: (processID: Int32, command: String, startCommand: String)? = if attachExisting {
                nil
            } else {
                try await queryPaneIdentity(connection: connection)
            }
            if let existingIdentity,
               existingIdentity.startCommand != Self.reportedStartCommand(for: paneCommand)
            {
                throw SessionDiagnostic.processIdentityChanged
            }
            if let existingIdentity {
                lock.withLock { adoptedPaneProcessID = existingIdentity.processID }
                try await postPreflightHook?()
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
                self?.receiveUnverifiedOutput(data)
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

    private func receiveUnverifiedOutput(_ data: Data) {
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
            if outputVerified {
                return outputHandler
            }
            guard !heldOutputOverflowed,
                  heldOutputBytes + data.count <= 4 * 1024 * 1024
            else {
                heldOutput = []
                heldOutputBytes = 0
                heldOutputOverflowed = true
                return nil
            }
            heldOutput.append(Data(data))
            heldOutputBytes += data.count
            return nil
        }
        handler?(data)
    }

    func releaseVerifiedOutput() throws {
        while true {
            let batch: (chunks: [Data], handler: (@Sendable (Data) -> Void)?) = try lock.withLock {
                guard !heldOutputOverflowed else {
                    throw SessionDiagnostic.frameTooLarge
                }
                guard !heldOutput.isEmpty else {
                    outputVerified = true
                    return ([], outputHandler)
                }
                let chunks = heldOutput
                heldOutput = []
                heldOutputBytes = 0
                return (chunks, outputHandler)
            }
            guard !batch.chunks.isEmpty else { return }
            for chunk in batch.chunks {
                batch.handler?(chunk)
            }
        }
    }

    static func shouldRetryLauncher(
        startCommand: String,
        expectedStartCommand: String,
        executable: String,
        compatibleExecutables: Set<String>
    ) -> Bool {
        startCommand == expectedStartCommand && !compatibleExecutables.contains(executable)
    }

    static func reportedStartCommand(for paneCommand: String) -> String {
        let escaped = paneCommand.reduce(into: "") { result, character in
            if character == "\\" || character == "\"" || character == "$" || character == "`" {
                result.append("\\")
            }
            result.append(character)
        }
        return "\"\(escaped)\""
    }

    static func launcherPaneExecutable(for paneCommand: String) -> String {
        let commandParts = paneCommand.split(separator: " ")
        if commandParts.count == 2, commandParts[0] == "exec" {
            return URL(fileURLWithPath: String(commandParts[1])).lastPathComponent
        }
        return "pi"
    }

    static func compatiblePaneExecutables(for paneCommand: String) -> Set<String> {
        let launcher = launcherPaneExecutable(for: paneCommand)
        // A pane created by this transport may resolve Pi's Node shebang. An
        // unrecorded pre-existing Node pane remains ambiguous and is rejected.
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
        if let adoptedPaneProcessID = lock.withLock({ self.adoptedPaneProcessID }),
           identity.processID != adoptedPaneProcessID
        {
            throw SessionDiagnostic.processIdentityChanged
        }
        if !attachExisting {
            guard identity.startCommand == Self.reportedStartCommand(for: paneCommand) else {
                throw SessionDiagnostic.processIdentityChanged
            }
            guard !Self.shouldRetryLauncher(
                startCommand: identity.startCommand,
                expectedStartCommand: Self.reportedStartCommand(for: paneCommand),
                executable: identity.command,
                compatibleExecutables: compatiblePaneExecutables
            ) else {
                // A validated login-shell launcher may still be loading its
                // profile before it replaces itself with Pi/Node.
                return nil
            }
        }
        return TmuxPaneIdentity(
            processID: identity.processID,
            executable: identity.command,
            startCommand: identity.startCommand
        )
    }

    private func queryPaneIdentity(
        connection: SSHSessionConnection
    ) async throws -> (processID: Int32, command: String, startCommand: String)? {
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
                   let command = collector.paneCommand,
                   let startCommand = collector.paneStartCommand
                {
                    return (processID, command, startCommand)
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
            heldOutput = []
            heldOutputBytes = 0
            return resources
        }
        await resources.channel?.close()
        await resources.connection?.close()
    }
}

/// Collects one strictly bounded decimal pane process ID from an exec channel.
final class PaneProcessIDCollector: @unchecked Sendable {
    private static let maxResponseBytes = 192
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
                byte != 0x0A && byte != 0x0D && byte != 0x7C
                    && !(0x20 ... 0x7E).contains(byte)
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

    var paneStartCommand: String? {
        lock.withLock { parsedIdentity()?.startCommand }
    }

    private func validateAndFinish() {
        invalid = parsedIdentity() == nil
        done = true
    }

    private func parsedIdentity() -> (processID: Int32, command: String, startCommand: String)? {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: Self.whitespace)
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        let command = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: Self.whitespace)
            : ""
        let startCommand = parts.count > 2
            ? String(parts[2]).trimmingCharacters(in: Self.whitespace)
            : ""
        guard parts.count == 3,
              parts[0].utf8.count <= 10,
              let processID = Int32(parts[0]),
              !command.isEmpty,
              command.utf8.count <= 32,
              !startCommand.isEmpty,
              startCommand.utf8.count <= 128
        else {
            return nil
        }
        return (processID, command, startCommand)
    }
}
