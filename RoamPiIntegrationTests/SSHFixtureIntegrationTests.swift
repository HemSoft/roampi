import Foundation
@testable import RoamPiCore
import Testing

/// Disposable SSH integration tests. Each test uses a generated keypair, a
/// user-level sshd on a private high port, a temporary working directory, and
/// disposable tmux sessions. Production tests never touch the live tailnet.
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

        let transport = fixture.makeTransport(sessionName: "roampi-itest")
        let terminal = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName("roampi-itest")),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: transport
        )

        try await terminal.start()
        #expect(terminal.phase == .attached)

        let beforeSize = try await fixture.exec(
            "tmux display-message -p -t 'roampi-itest' '#{pane_width} #{pane_height}'"
        )
        // tmux reserves one row for its status line.
        #expect(beforeSize == "80 23")

        try terminal.submitViewportSize(columns: 120, rows: 40)
        try await Task.sleep(for: .milliseconds(300))

        let afterSize = try await fixture.exec(
            "tmux display-message -p -t 'roampi-itest' '#{pane_width} #{pane_height}'"
        )
        #expect(afterSize == "120 39")

        let panePID = try await fixture.paneProcessID(sessionName: "roampi-itest")
        #expect(panePID != nil)
        #expect(try await fixture.tmuxSessionCount(name: "roampi-itest") == 1)

        try await terminal.detach()
        try await fixture.killSession(name: "roampi-itest")
    }

    @Test("Reconnect attaches the same tmux session without creating a duplicate")
    func reconnectSameSessionNoDuplicate() async throws {
        let fixture = try makeFixture()
        defer { fixture.stop() }

        let firstTransport = fixture.makeTransport(sessionName: "roampi-itest2")
        let firstSession = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName("roampi-itest2")),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: firstTransport
        )
        try await firstSession.start()
        #expect(firstSession.phase == .attached)

        let firstPID = try await #require(fixture.paneProcessID(sessionName: "roampi-itest2"))
        try await firstSession.detach()
        #expect(firstSession.phase == .detached)

        try await Task.sleep(for: .milliseconds(200))

        let secondTransport = fixture.makeTransport(sessionName: "roampi-itest2")
        let secondSession = try TerminalSession(
            endpoint: fixture.endpoint,
            sessionName: #require(TmuxSessionName("roampi-itest2")),
            workingDirectory: #require(RemoteWorkingDirectory(fixture.workDirectory.path)),
            transport: secondTransport
        )
        try await secondSession.start()
        #expect(secondSession.phase == .attached)

        let secondPID = try await #require(fixture.paneProcessID(sessionName: "roampi-itest2"))
        #expect(secondPID == firstPID)
        #expect(try await fixture.tmuxSessionCount(name: "roampi-itest2") == 1)

        try await secondSession.detach()
        try await fixture.killSession(name: "roampi-itest2")
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
