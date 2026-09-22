import Foundation
@testable import RoamPiCore
import Testing

/// Disposable SSH integration tests. Each test uses a generated keypair, a
/// user-level sshd on a private high port, a temporary working directory, and
/// disposable tmux sessions. Production tests never touch the live tailnet.
private final class LockedTerminalOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var text: String {
        lock.withLock { String(decoding: storage, as: UTF8.self) }
    }

    func append(_ data: Data) {
        lock.withLock { storage.append(data) }
    }

    func reset() {
        lock.withLock { storage = Data() }
    }
}

@MainActor
@Suite(.serialized)
struct SSHFixtureIntegrationTests {
    private func makeFixture() throws -> SSHFixture {
        try SSHFixture()
    }

    @Test("PTY allocation, input, and resize ride one channel without a second process")
    func ptyResizeAndStableProcess() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("resize")
        let transport = fixture.makeTransport(sessionName: sessionName)
        let terminal = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: transport
        )

        try await terminal.start()
        #expect(terminal.phase == .attached)

        let beforeSize = try await fixture.exec(
            "tmux display-message -p -t '\(sessionName)' '#{pane_width} #{pane_height}'"
        )
        // tmux reserves one row for its status line.
        #expect(beforeSize == "80 23")

        try terminal.submitViewportSize(columns: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(300))

        let afterSize = try await fixture.exec(
            "tmux display-message -p -t '\(sessionName)' '#{pane_width} #{pane_height}'"
        )
        #expect(afterSize == "120 39")

        let panePID = try await fixture.paneProcessID(sessionName: sessionName)
        #expect(panePID != nil)
        #expect(try await fixture.tmuxSessionCount(name: sessionName) == 1)

        try await terminal.detach()
        try await fixture.killSession(name: sessionName)
    }

    @Test("Reconnect attaches the same tmux session without creating a duplicate")
    func reconnectSameSessionNoDuplicate() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("reconnect")
        let session = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec cat"
        )
        try await session.start()
        #expect(session.phase == .attached)

        let firstPID = try await #require(fixture.paneProcessID(sessionName: sessionName))
        try await session.detach()
        #expect(session.phase == .detached)

        try await Task.sleep(for: .milliseconds(200))

        try await session.reconnect()
        #expect(session.phase == .attached)
        #expect(session.lastProcessIdentityUnchanged == true)

        let secondPID = try await #require(fixture.paneProcessID(sessionName: sessionName))
        #expect(secondPID == firstPID)
        #expect(try await fixture.tmuxSessionCount(name: sessionName) == 1)

        try await session.detach()
        try await fixture.killSession(name: sessionName)
    }

    @Test("Reconnect attaches when the original project path is gone")
    func reconnectIgnoresMissingProjectPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("missing-path")
        let session = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec cat"
        )
        try await session.start()
        try await session.detach()
        let movedDirectory = fixture.workDirectory.deletingLastPathComponent()
            .appendingPathComponent("work-moved")
        try FileManager.default.moveItem(at: fixture.workDirectory, to: movedDirectory)

        try await session.reconnect()

        #expect(session.phase == .attached)
        #expect(session.lastProcessIdentityUnchanged == true)
        try await session.close()
        try await fixture.killSession(name: sessionName)
    }

    @Test("Reconnect never forwards output from a replacement pane")
    func reconnectSuppressesReplacementOutput() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("replaced")
        let output = LockedTerminalOutput()
        let session = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec cat"
        )
        session.onOutput = { output.append($0) }
        try await session.start()
        try await session.detach()
        output.reset()

        try await fixture.killSession(name: sessionName)
        let replacementCommand = "printf 'UNRELATED_REPLACEMENT'; exec cat"
        _ = try await fixture.exec(
            "cd \(ShellQuoting.quote(fixture.workDirectory.path)) && tmux new-session -d -s "
                + "\(ShellQuoting.quote(sessionName)) \(ShellQuoting.quote(replacementCommand))"
        )
        try await session.reconnect()

        #expect(session.phase == .failed(.processIdentityChanged))
        #expect(!output.text.contains("UNRELATED_REPLACEMENT"))
        try await session.close()
        try await fixture.killSession(name: sessionName)
    }

    @Test("First attach rejects a same-launcher preflight replacement")
    func firstAttachRejectsPreflightReplacement() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("preflight-race")
        let existing = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec cat"
        )
        try await existing.start()
        try await existing.detach()

        let validatedSessionName = try #require(TmuxSessionName(sessionName))
        let validatedDirectory = try #require(RemoteWorkingDirectory(fixture.workDirectory.path))
        let transport = SSHPTYTransport(
            endpoint: fixture.endpoint,
            authentication: .standardKey,
            sessionName: validatedSessionName,
            workingDirectory: validatedDirectory,
            paneCommand: "exec cat",
            credentials: fixture.credentials,
            postPreflightHook: {
                try await fixture.killSession(name: sessionName)
                _ = try await fixture.exec(
                    "cd \(ShellQuoting.quote(fixture.workDirectory.path)) && tmux new-session -d -s "
                        + "\(ShellQuoting.quote(sessionName)) \(ShellQuoting.quote("exec cat"))"
                )
            }
        )
        _ = try await transport.open(columns: 80, rows: 24)

        do {
            _ = try await transport.paneIdentity()
            Issue.record("Expected replacement identity rejection")
        } catch let diagnostic as SessionDiagnostic {
            #expect(diagnostic == .processIdentityChanged)
        }
        try await transport.close()
        try await fixture.killSession(name: sessionName)
    }

    @Test("First attach rejects an unrelated existing Node pane")
    func rejectsIncompatibleExistingPane() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("incompatible")
        let existing = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec node"
        )
        try await existing.start()
        #expect(existing.phase == .attached)
        try await existing.detach()

        let expectedPi = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(sessionName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec pi"
        )
        try await expectedPi.start()

        #expect(expectedPi.phase == .failed(.processIdentityChanged))
        try await expectedPi.close()
        try await fixture.killSession(name: sessionName)
    }

    @Test("Overlapping tmux names never use prefix matching")
    func overlappingNamesStayDistinct() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let shortName = fixture.sessionName("overlap")
        let longName = shortName + "-dev"
        let longer = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(longName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec cat"
        )
        try await longer.start()
        try await longer.detach()

        let shorter = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName(shortName)),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            credentials: fixture.credentials,
            paneCommand: "exec cat"
        )
        try await shorter.start()

        #expect(shorter.phase == .attached)
        #expect(try await fixture.tmuxSessionCount(name: shortName) == 1)
        #expect(try await fixture.tmuxSessionCount(name: longName) == 1)
        try await shorter.close()
        try await fixture.killSession(name: shortName)
        try await fixture.killSession(name: longName)
    }

    @Test("Atomic creation refuses a concurrent tmux name collision")
    func atomicCreationRefusesConcurrentCollision() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("collision")
        let session = try #require(TmuxSessionName(sessionName))
        let directory = try #require(RemoteWorkingDirectory(fixture.workDirectory.path))
        _ = try await fixture.exec(
            "cd \(ShellQuoting.quote(directory.absolutePath)) && tmux new-session -d -s "
                + "\(ShellQuoting.quote(sessionName)) "
                + ShellQuoting.quote("exec node -e 'setInterval(() => {}, 1000)'")
        )

        _ = try await fixture.exec(
            TmuxCommand.attachOrCreate(
                session: session,
                workingDirectory: directory,
                paneCommand: "exec pi"
            )
        )
        let identity = try await fixture.exec(TmuxCommand.paneProcessID(session: session))
        let fields = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)

        #expect(try await fixture.tmuxSessionCount(name: sessionName) == 1)
        #expect(fields.count == 4)
        #expect(fields[2] == "\"exec node -e 'setInterval(() => {}, 1000)'\"")
        #expect(fields[3].isEmpty)
        try await fixture.killSession(name: sessionName)
    }

    @Test("Tmux commands suppress login-profile output and resolve its PATH")
    func tmuxSuppressesProfileOutputAndResolvesLoginPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("login-path")
        let session = try #require(TmuxSessionName(sessionName))
        _ = try await fixture.exec(
            "cd \(ShellQuoting.quote(fixture.workDirectory.path)) && tmux new-session -d -s "
                + "\(ShellQuoting.quote(sessionName)) \(ShellQuoting.quote("exec cat"))"
        )

        let noisyShell = fixture.root.appendingPathComponent("noisy-login-shell")
        try Data(
            "#!/bin/sh\necho profile-noise\necho profile-error >&2\nexec /bin/zsh \"$@\"\n".utf8
        ).write(to: noisyShell)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: noisyShell.path)

        let identity = try await fixture.exec(
            "SHELL=\(ShellQuoting.quote(noisyShell.path)); export SHELL; "
                + "PATH=/usr/bin:/bin; export PATH; "
                + TmuxCommand.paneProcessID(session: session)
        )
        let fields = identity.split(separator: "|", omittingEmptySubsequences: false)
        #expect(fields.count == 4)
        #expect(!identity.contains("profile-noise"))
        #expect(!identity.contains("profile-error"))
        try await fixture.killSession(name: sessionName)
    }

    @Test("Transport creation rejects a concurrent same-name pane")
    func transportCreationRejectsConcurrentPane() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let sessionName = fixture.sessionName("transport-collision")
        let validatedSessionName = try #require(TmuxSessionName(sessionName))
        let validatedDirectory = try #require(RemoteWorkingDirectory(fixture.workDirectory.path))
        let transport = SSHPTYTransport(
            endpoint: fixture.endpoint,
            authentication: .standardKey,
            sessionName: validatedSessionName,
            workingDirectory: validatedDirectory,
            paneCommand: "exec cat",
            credentials: fixture.credentials,
            postPreflightHook: {
                _ = try await fixture.exec(
                    "cd \(ShellQuoting.quote(fixture.workDirectory.path)) && tmux new-session -d -s "
                        + "\(ShellQuoting.quote(sessionName)) \(ShellQuoting.quote("exec cat"))"
                )
            }
        )
        _ = try await transport.open(columns: 80, rows: 24)

        do {
            _ = try await transport.paneIdentity()
            Issue.record("Expected concurrent creation rejection")
        } catch let diagnostic as SessionDiagnostic {
            #expect(diagnostic == .processIdentityChanged)
        }
        try await transport.close()
        #expect(try await fixture.tmuxSessionCount(name: sessionName) == 1)
        try await fixture.killSession(name: sessionName)
    }

    @Test("RPC mode exchanges one strict LF-delimited request and response")
    func rpcStrictExchange() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let transport = try fixture.makeRPCTransport()
        let session = try RPCSession(
            endpoint: fixture.endpoint,
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: transport
        )

        try await session.start()
        #expect(session.phase == .attached)

        let exchange = try #require(session.lastExchange)
        #expect(exchange.succeeded)
        #expect(exchange.responseFrameCount == 1)
        #expect(exchange.eventFrameCount == 1)

        let followUp = try await session.exchange(
            PiRPCRequest(identifier: "follow-up", kind: .getState)
        )
        #expect(followUp.isSuccessResponse(command: "get_state"))

        try await session.close()
        #expect(session.phase == .closed)
    }

    @Test("RPC protocol failure survives SSH channel teardown")
    func protocolFailureSurvivesChannelTeardown() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let session = try RPCSession(
            endpoint: fixture.endpoint,
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: fixture.makeRPCTransport(wrongCommandMode: true)
        )
        try await session.start()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.phase == .failed(.malformedFrame))
        try await session.close()
    }

    @Test("RPC framing rejects a CR-only separator from the remote side")
    func rpcRejectsCROnlyFrames() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let transport = try fixture.makeRPCTransport(crOnlyMode: true)
        let session = try RPCSession(
            endpoint: fixture.endpoint,
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: transport
        )

        try await session.start()
        #expect(terminalFailed(session))
        try? await session.close()
    }

    @Test("RPC framing rejects a trailing partial frame at process end")
    func rpcRejectsTrailingPartial() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let transport = try fixture.makeRPCTransport(partialTrailerMode: true)
        let session = try RPCSession(
            endpoint: fixture.endpoint,
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: transport
        )

        try await session.start()
        try await Task.sleep(for: .milliseconds(500))
        #expect(terminalFailed(session))
        try? await session.close()
    }

    @Test("RPC mode rejects an oversized frame")
    func rpcRejectsOversizedFrame() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let transport = try fixture.makeRPCTransport(oversizedMode: true)
        let session = try RPCSession(
            endpoint: fixture.endpoint,
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: transport
        )

        try await session.start()
        try await Task.sleep(for: .seconds(1))
        #expect(terminalFailed(session))
        try? await session.close()
    }

    @Test("Terminal and RPC adapters share the PiSession interface")
    func sharedInterface() throws {
        let endpoint = try RemoteEndpoint(connectionString: "demo@fixture")
        let directory = try #require(RemoteWorkingDirectory("/tmp"))
        let sessionName = try #require(TmuxSessionName("roampi-interface"))
        let terminal: any PiSession = TerminalSession(
            endpoint: endpoint,
            sessionName: sessionName,
            workingDirectory: directory,
            transport: ScriptedTerminalTransport()
        )
        let rpc: any PiSession = RPCSession(
            endpoint: endpoint,
            workingDirectory: directory,
            transport: ScriptedRPCTransport()
        )

        #expect(terminal.phase == .idle)
        #expect(rpc.phase == .idle)
    }

    private func terminalFailed(_ session: RPCSession) -> Bool {
        session.phase == .failed(.malformedFrame) || session.phase == .failed(.frameTooLarge)
    }
}
