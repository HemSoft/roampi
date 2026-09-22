import Foundation
@testable import RoamPiCore
import Testing

@Suite("JSONL framing")
struct JSONLFramingTests {
    @Test("One frame in one feed")
    func singleFrame() throws {
        var decoder = JSONLFrameDecoder()
        let frames = try decoder.feed(Data(#"{"type":"get_state"}"#.utf8 + [0x0A]))

        #expect(frames.count == 1)
        let value = try JSONLFrameDecoder.decode(frames[0])
        #expect(value["type"]?.stringValue == "get_state")
    }

    @Test("Multiple frames split across feeds arrive in order")
    func splitAcrossFeeds() throws {
        var decoder = JSONLFrameDecoder()
        let payload = Data(
            #"{"type":"a"}"#.utf8 + [0x0A]
                + #"{"type":"b"}"#.utf8 + [0x0A]
        )

        let first = try decoder.feed(payload[0 ..< 5])
        #expect(first.isEmpty)
        let rest = try decoder.feed(payload[5...])
        #expect(rest.count == 2)
        #expect(try JSONLFrameDecoder.decode(rest[0])["type"]?.stringValue == "a")
        #expect(try JSONLFrameDecoder.decode(rest[1])["type"]?.stringValue == "b")
    }

    @Test("A large transport chunk of individually bounded records is accepted")
    func acceptsLargeAggregateChunk() throws {
        var decoder = JSONLFrameDecoder()
        let record = Data("{\"ok\":true}\n".utf8)
        var chunk = Data()
        while chunk.count <= JSONLFraming.maxFrameBytes {
            chunk.append(record)
        }

        let frames = try decoder.feed(chunk)

        #expect(frames.count == chunk.count / record.count)
    }

    @Test("One byte at a time still yields one frame")
    func byteAtATime() throws {
        var decoder = JSONLFrameDecoder()
        let payload = Data(#"{"k":1}"#.utf8 + [0x0A])
        var frames: [Data] = []
        for byte in payload {
            frames += try decoder.feed(Data([byte]))
        }
        #expect(frames.count == 1)
    }

    @Test("A CR-only separator is rejected")
    func rejectsCROnlySeparator() {
        var decoder = JSONLFrameDecoder()
        #expect(throws: JSONLFraming.FrameError.framingError) {
            try decoder.feed(Data("{\"a\":1}\u{0D}{\"b\":2}\u{0A}".utf8))
        }
    }

    @Test("An embedded raw CR is rejected")
    func rejectsEmbeddedCR() {
        var decoder = JSONLFrameDecoder()
        #expect(throws: JSONLFraming.FrameError.framingError) {
            try decoder.feed(Data("{\"a\":\u{0D}1}\u{0A}".utf8))
        }
    }

    @Test("A CRLF line ending is tolerated by stripping the trailing CR")
    func toleratesCRLF() throws {
        var decoder = JSONLFrameDecoder()
        let frames = try decoder.feed(Data("{\"a\":1}\u{0D}\u{0A}".utf8))

        #expect(frames.count == 1)
        #expect(try JSONLFrameDecoder.decode(frames[0])["a"] != nil)
    }

    @Test("Unicode line separators do not split a frame")
    func doesNotSplitOnUnicodeSeparators() throws {
        var decoder = JSONLFrameDecoder()
        // U+2028 inside a JSON string is valid content and must not split.
        let frames = try decoder.feed(Data(#"{"s":"a b"}"#.utf8 + [0x0A]))

        #expect(frames.count == 1)
        #expect(try JSONLFrameDecoder.decode(frames[0])["s"]?.stringValue == "a b")
    }

    @Test("A Unicode line separator used as a record separator is rejected as malformed")
    func rejectsUnicodeSeparatorFraming() {
        var decoder = JSONLFrameDecoder()
        // Two objects glued with U+2028: one frame, invalid JSON, rejected.
        #expect(throws: JSONLFraming.FrameError.malformedJSON) {
            try decoder.feed(Data("{\"a\":1} {\"b\":2}\u{0A}".utf8))
        }
    }

    @Test("Malformed JSON is rejected")
    func rejectsMalformedJSON() {
        var decoder = JSONLFrameDecoder()
        #expect(throws: JSONLFraming.FrameError.malformedJSON) {
            try decoder.feed(Data("not-json\u{0A}".utf8))
        }
    }

    @Test("An empty frame is rejected")
    func rejectsEmptyFrame() {
        var decoder = JSONLFrameDecoder()
        #expect(throws: JSONLFraming.FrameError.malformedJSON) {
            try decoder.feed(Data([0x0A]))
        }
    }

    @Test("A non-object JSON value is rejected")
    func rejectsNonObject() {
        var decoder = JSONLFrameDecoder()
        #expect(throws: JSONLFraming.FrameError.malformedJSON) {
            try decoder.feed(Data("[1,2]\u{0A}".utf8))
        }
    }

    @Test("An oversized unterminated frame is rejected at the limit")
    func rejectsOversizedFrame() {
        var decoder = JSONLFrameDecoder()
        let chunk = Data(repeating: 0x61, count: 4096)

        #expect(throws: JSONLFraming.FrameError.frameTooLarge) {
            for _ in 0 ..< (JSONLFraming.maxFrameBytes / 4096 + 1) {
                _ = try decoder.feed(chunk)
            }
        }
    }

    @Test("An oversized complete frame is rejected before decoding")
    func rejectsOversizedCompleteFrame() {
        var decoder = JSONLFrameDecoder()
        var frame = Data(repeating: 0x61, count: JSONLFraming.maxFrameBytes + 1)
        frame.append(0x0A)

        #expect(throws: JSONLFraming.FrameError.frameTooLarge) {
            try decoder.feed(frame)
        }
    }

    @Test("A trailing partial frame is rejected when the stream ends")
    func rejectsTrailingPartialFrame() throws {
        var decoder = JSONLFrameDecoder()
        _ = try decoder.feed(Data("{\"a\":1}".utf8))

        #expect(throws: JSONLFraming.FrameError.trailingPartialFrame) {
            try decoder.finish()
        }
    }

    @Test("A clean stream end accepts no trailing bytes")
    func acceptsCleanEnd() throws {
        var decoder = JSONLFrameDecoder()
        _ = try decoder.feed(Data("{\"a\":1}\u{0A}".utf8))

        try decoder.finish()
    }

    @Test("Outgoing frames escape Unicode line separators and end with LF")
    func outgoingEscaping() throws {
        let frame = try JSONLOutgoing.encode([
            "id": .string("r1"),
            "type": .string("prompt"),
            "message": .string("line split"),
        ])

        #expect(frame.last == 0x0A)
        let text = String(decoding: frame.dropLast(), as: UTF8.self)
        #expect(!text.contains("\u{2028}"))
        #expect(text.contains("\\u2028"))
    }

    @Test("Outbound JSON escaping cannot exceed the frame limit")
    func rejectsExpandedOutgoingFrame() {
        let message = String(repeating: "\u{0001}", count: PiRPCRequest.maximumMessageBytes)
        let request = PiRPCRequest(identifier: "expanded", kind: .prompt(message))

        #expect(throws: JSONLFraming.FrameError.frameTooLarge) {
            try request.encodedFrame()
        }
    }

    @Test("Numeric zero and one remain numbers rather than booleans")
    func preservesNumericTypes() throws {
        let value = try JSONLFrameDecoder.decode(
            Data(#"{"zero":0,"one":1,"false":false,"true":true}"#.utf8)
        )

        #expect(value["zero"] == .number(0))
        #expect(value["one"] == .number(1))
        #expect(value["false"] == .bool(false))
        #expect(value["true"] == .bool(true))
    }

    @Test("The frame limit is documented as one mebibyte")
    func frameLimit() {
        #expect(JSONLFraming.maxFrameBytes == 1_048_576)
    }
}

@Suite("Session foundations")
struct SessionFoundationTests {
    @Test("Session names accept the documented safe alphabet")
    func acceptsSessionNames() {
        #expect(TmuxSessionName("roampi-work")?.rawValue == "roampi-work")
        #expect(TmuxSessionName("RoamPi_1-a-b") != nil)
        #expect(TmuxSessionName(String(repeating: "a", count: 64)) != nil)
    }

    @Test(
        "Session names reject injection and unsafe forms",
        arguments: [
            "",
            "   ",
            "has space",
            "has:colon",
            "has.period",
            "semicolon;injection",
            "$(command)",
            "`command`",
            "back\\slash",
            "quote'name",
            "pipe|name",
            "amp&name",
            ".leading-dot",
            "-leading-dash",
            String(repeating: "a", count: 65),
            "new\nline",
            "tab\tname",
        ]
    )
    func rejectsSessionNames(input: String) {
        #expect(TmuxSessionName(input) == nil)
    }

    @Test("Working directories accept absolute safe paths")
    func acceptsWorkingDirectories() {
        #expect(RemoteWorkingDirectory("/home/user/project")?.absolutePath == "/home/user/project")
        #expect(RemoteWorkingDirectory("/")?.absolutePath == "/")
        #expect(RemoteWorkingDirectory("/opt/work dir")?.absolutePath == "/opt/work dir")
    }

    @Test(
        "Working directories reject traversal, relative, and injection forms",
        arguments: [
            "relative/path",
            "",
            "/../escape",
            "/safe/../escape",
            "/..",
            "/tmp;$x",
            "/tmp/$(x)",
            "/tmp/`x`",
            "/tmp/\u{0}",
            "/tmp\nx",
            "/tmp;x",
            "/tmp|pipe",
            String(repeating: "a", count: 257),
        ]
    )
    func rejectsWorkingDirectories(input: String) {
        #expect(RemoteWorkingDirectory(input) == nil)
    }

    @Test("Shell quoting escapes embedded single quotes")
    func quoting() {
        #expect(ShellQuoting.quote("simple") == "'simple'")
        #expect(ShellQuoting.quote("o'brien") == "'o'\\''brien'")
        #expect(ShellQuoting.quote("") == "''")
    }

    @Test("The attach command is the approved quoted form")
    func attachCommand() throws {
        let session = try #require(TmuxSessionName("roampi-proj"))
        let directory = try #require(RemoteWorkingDirectory("/home/user/proj"))

        let command = TmuxCommand.attachOrCreate(session: session, workingDirectory: directory)

        #expect(
            command == LoginShellCommand.run(
                "cd '/home/user/proj' && exec tmux new-session -s 'roampi-proj' "
                    + ShellQuoting.quote(
                        PiTerminalCommand.start(workingDirectory: directory)
                    ),
                suppressProfileOutput: true
            )
        )
    }

    @Test("Support commands quote the session name")
    func supportCommands() throws {
        let session = try #require(TmuxSessionName("roampi-proj"))

        #expect(
            TmuxCommand.hasSession(session: session)
                == LoginShellCommand.run(
                    "exec tmux has-session -t '=roampi-proj:' 2>/dev/null",
                    suppressProfileOutput: true
                )
        )
        #expect(
            try TmuxCommand.attachExisting(
                session: session,
                workingDirectory: #require(RemoteWorkingDirectory("/home/user/proj"))
            ) == LoginShellCommand.run(
                "exec tmux attach-session -t '=roampi-proj:'",
                suppressProfileOutput: true
            )
        )
        #expect(TmuxCommand
            .paneProcessID(session: session) == LoginShellCommand.run(
                "tmux has-session -t '=roampi-proj:' 2>/dev/null && exec tmux display-message -p -t '=roampi-proj:' '#{pane_pid}|#{pane_current_command}|#{pane_start_command}|#{E:ROAMPI_CREATION_ID}'",
                suppressProfileOutput: true
            ))
        #expect(
            TmuxCommand.killSession(session: session)
                == LoginShellCommand.run(
                    "exec tmux kill-session -t '=roampi-proj:' 2>/dev/null",
                    suppressProfileOutput: true
                )
        )
    }

    @Test("The RPC start command quotes the directory and pins rpc mode")
    func rpcCommand() throws {
        let directory = try #require(RemoteWorkingDirectory("/home/user/proj"))

        let command = PiRPCCommand.start(workingDirectory: directory)

        #expect(
            command == LoginShellCommand.run(
                "cd '/home/user/proj' && exec pi --mode rpc --no-session",
                suppressProfileOutput: true
            )
        )
    }

    @Test("Resize coalescing sends the first size immediately")
    func firstResizeSendsImmediately() {
        var coalescer = ResizeCoalescer()

        let decision = coalescer.submit(columns: 100, rows: 40)

        #expect(decision?.sendNow == ResizeCoalescer.Size(columns: 100, rows: 40))
        #expect(decision?.pending == nil)
        #expect(coalescer.hasPending == false)
    }

    @Test("Resize coalescing replaces pending sizes instead of sending each")
    func burstReplacesPending() {
        var coalescer = ResizeCoalescer()
        _ = coalescer.submit(columns: 100, rows: 40)

        let second = coalescer.submit(columns: 90, rows: 38)
        let third = coalescer.submit(columns: 80, rows: 30)

        #expect(second?.sendNow == nil)
        #expect(second?.pending == ResizeCoalescer.Size(columns: 90, rows: 38))
        #expect(third?.sendNow == nil)
        #expect(third?.pending == ResizeCoalescer.Size(columns: 80, rows: 30))
        #expect(coalescer.hasPending)

        #expect(coalescer.flush() == ResizeCoalescer.Size(columns: 80, rows: 30))
        #expect(coalescer.hasPending == false)
        #expect(coalescer.flush() == nil)
    }

    @Test("Resize coalescing clamps to bounded dimensions")
    func clampsToLimits() {
        var coalescer = ResizeCoalescer()

        let huge = coalescer.submit(columns: 100_000, rows: 0)
        #expect(huge?.sendNow == ResizeCoalescer.Size(columns: 500, rows: 1))

        let next = coalescer.submit(columns: 1, rows: 1)
        #expect(next?.pending == ResizeCoalescer.Size(columns: 2, rows: 1))
    }

    @Test("A duplicate viewport size sends nothing")
    func duplicateSizeSendsNothing() {
        var coalescer = ResizeCoalescer()
        _ = coalescer.submit(columns: 80, rows: 24)

        #expect(coalescer.submit(columns: 80, rows: 24) == nil)
    }

    @Test("Reconnect transitions follow the documented table")
    func reconnectTransitions() throws {
        var machine = ReconnectStateMachine()

        try machine.beginConnecting()
        try machine.markAttached()
        try machine.markDisconnected()
        try machine.beginReconnect()
        try machine.markAttached()
        try machine.beginInterrupt()
        try machine.endInterrupt()
        try machine.detach()
        try machine.beginReconnect()
        try machine.markAttached()
        try machine.beginClose()
        try machine.markClosed()

        #expect(machine.phase == .closed)
    }

    @Test("Illegal transitions are refused")
    func refusesIllegalTransitions() {
        var machine = ReconnectStateMachine()

        #expect(throws: Error.self) {
            try machine.markAttached()
        }
        #expect(throws: Error.self) {
            try machine.beginReconnect()
        }

        try? machine.beginConnecting()
        #expect(throws: Error.self) {
            try machine.beginConnecting()
        }

        try? machine.markAttached()
        #expect(throws: Error.self) {
            try machine.beginConnecting()
        }
        #expect(throws: Error.self) {
            try machine.markAttached()
        }
    }

    @Test("Connecting and reconnecting can close, and interrupted can detach")
    func lifecycleActionsRemainAvailableDuringWork() throws {
        var connecting = ReconnectStateMachine()
        try connecting.beginConnecting()
        try connecting.beginClose()
        try connecting.markClosed()

        var interrupted = ReconnectStateMachine()
        try interrupted.beginConnecting()
        try interrupted.markAttached()
        try interrupted.beginInterrupt()
        try interrupted.detach()
        #expect(interrupted.phase == .detached)
    }

    @Test("A stalled terminal interrupt publishes its in-flight phase")
    func stalledInterruptPublishesPhase() async throws {
        let transport = BlockingInterruptTerminalTransport()
        let phases = LockedPhaseCollector()
        let session = try TerminalSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            sessionName: #require(TmuxSessionName("interrupt-phase")),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        session.onPhaseChange = { phases.append($0) }
        try await session.start()

        let interrupt = Task { try await session.interrupt() }
        for _ in 0 ..< 100 where !transport.isWriteStalled {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.phase == .interrupted)
        #expect(phases.values.contains(.interrupted))

        transport.releaseWrite()
        try await interrupt.value
        #expect(session.phase == .attached)
        #expect(phases.values.last == .attached)
        try await session.close()
    }

    @Test("Terminal close reaches closed when transport teardown throws")
    func terminalCloseSurvivesTeardownFailure() async throws {
        let transport = ThrowingCloseTerminalTransport()
        let session = try TerminalSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            sessionName: #require(TmuxSessionName("roampi-close-failure")),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()

        do {
            try await session.close()
            Issue.record("Expected terminal teardown failure")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .connectionFailed)
            #expect(failure.phase == .closed)
        }
        #expect(session.phase == .closed)
    }

    @Test("Session diagnostics never interpolate connection details")
    func diagnosticsRedactSecrets() {
        let sensitiveValues = ["person", "machine.example.ts.net", "100.64.0.1", "/private/project", "roampi-proj"]

        for diagnostic in [
            SessionDiagnostic.authenticationFailed,
            .cancelled,
            .commandFailed,
            .connectionFailed,
            .duplicateRequest,
            .duplicateSession,
            .frameTooLarge,
            .hostKeyChanged,
            .invalidEndpoint,
            .invalidState,
            .invalidSessionName,
            .invalidWorkingDirectory,
            .keyUnavailable,
            .malformedFrame,
            .notAttached,
            .peerClosed,
            .processIdentityChanged,
            .timedOut,
            .unexpectedRemoteClose,
        ] {
            #expect(sensitiveValues.allSatisfy { !diagnostic.userMessage.contains($0) })
        }
    }

    @Test("Reconnect retains the bounded viewport for the replacement PTY")
    func reconnectUsesBoundedViewport() async throws {
        let transport = ScriptedTerminalTransport()
        let session = try TerminalSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            sessionName: #require(TmuxSessionName("roampi-resize")),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            deferredResizeInterval: .milliseconds(5)
        )

        try await session.start()
        try session.submitViewportSize(columns: 50000, rows: 0)
        try await session.detach()
        try await session.reconnect()

        #expect(transport.resizeRequests.last == ResizeCoalescer.Size(columns: 500, rows: 1))
        try await session.close()
    }

    @Test("Cancelling an attach leaves a bounded cancelled state")
    func cancellationIsBounded() async throws {
        let endpoint = try RemoteEndpoint(connectionString: "demo@fixture")
        let session = try TerminalSession(
            endpoint: endpoint,
            sessionName: #require(TmuxSessionName("roampi-cancel")),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: CancellingTerminalTransport()
        )

        let task = Task {
            try await session.start()
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        try await task.value

        #expect(session.phase == .failed(.cancelled))
    }

    @Test("Obsolete terminal attach cleanup cannot fail its replacement")
    func obsoleteAttachCleanupIsIgnored() async throws {
        let transport = AttachRaceTerminalTransport()
        let session = try TerminalSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            sessionName: #require(TmuxSessionName("roampi-attach-race")),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        let initialStart = Task { try await session.start() }
        for _ in 0 ..< 100 where session.phase != .failed(.commandFailed) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.phase == .failed(.commandFailed))

        try await session.reconnect()
        #expect(session.phase == .attached)
        transport.releaseFirstOpen()
        try await initialStart.value
        #expect(session.phase == .attached)
        try await session.detach()
    }

    @Test("An overflow closure is disarmed before one reconnect")
    func overflowClosureReconnectsOnce() async throws {
        let transport = OverflowRecoveryTerminalTransport()
        let session = try TerminalSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            sessionName: #require(TmuxSessionName("roampi-overflow")),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        try await session.start()
        #expect(session.phase == .failed(.commandFailed))

        try await session.reconnect()
        #expect(session.phase == .attached)
        #expect(transport.openCount == 2)
        #expect(transport.reportedClosureCount == 1)
        try await session.detach()
    }
}

@Suite("RPC session reliability")
struct RPCSessionReliabilityTests {
    @Test("Reconnect starts each RPC stream with a fresh decoder")
    func reconnectResetsDecoder() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        try await session.start()
        #expect(session.phase == .attached)
        transport.stopProcess()
        #expect(session.phase == .disconnected)

        try await session.reconnect()

        #expect(session.phase == .attached)
        #expect(session.lastExchange?.succeeded == true)
        try await session.close()
    }

    @Test("Startup records every event in the response transport batch")
    func startupAccountsForWholeResponseBatch() async throws {
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: ScriptedRPCTransport(startupEventInResponseBatch: true)
        )

        try await session.start()

        #expect(session.lastExchange?.responseFrameCount == 1)
        #expect(session.lastExchange?.eventFrameCount == 2)
        try await session.close()
    }

    @Test("Duplicate pending request identifiers are rejected")
    func rejectsDuplicatePendingIdentifiers() async throws {
        let transport = ControlledRPCTransport(respondsAfterStartup: false)
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .seconds(2)
        )
        try await session.start()

        let first = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "duplicate", kind: .getState)
            )
        }
        while transport.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        do {
            _ = try await session.exchange(
                PiRPCRequest(identifier: "duplicate", kind: .getState)
            )
            Issue.record("Expected duplicate request rejection")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .duplicateRequest)
        }

        first.cancel()
        _ = try? await first.value
        try await session.close()
    }

    @Test("A missing RPC response fails within the configured bound")
    func responseTimeoutIsBounded() async throws {
        let transport = ControlledRPCTransport(respondsAfterStartup: false)
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(40)
        )
        try await session.start()

        do {
            _ = try await session.exchange(
                PiRPCRequest(identifier: "no-response", kind: .getState)
            )
            Issue.record("Expected response timeout")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .timedOut)
        }

        for _ in 0 ..< 100 where !transport.didStop {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.didStop)
        try await session.close()
    }

    @Test("A stalled RPC interrupt publishes its in-flight phase")
    func stalledRPCInterruptPublishesPhase() async throws {
        let transport = StallingWriteRPCTransport()
        let phases = LockedPhaseCollector()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(40)
        )
        session.onPhaseChange = { phases.append($0) }
        try await session.start()

        let interrupt = Task { try await session.interrupt() }
        for _ in 0 ..< 100 where !transport.isWriteStalled {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.phase == .interrupted)
        #expect(phases.values.contains(.interrupted))

        do {
            try await interrupt.value
            Issue.record("Expected interrupt timeout")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .timedOut)
        }
        #expect(session.phase == .failed(.timedOut))
        #expect(phases.values.last == .failed(.timedOut))
        try await session.close()
    }

    @Test("A stalled RPC write is torn down at its response deadline")
    func stalledWriteHonorsDeadline() async throws {
        let transport = StallingWriteRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(40)
        )
        try await session.start()

        do {
            _ = try await session.exchange(
                PiRPCRequest(identifier: "stalled-write", kind: .prompt("bounded"))
            )
            Issue.record("Expected write timeout")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .timedOut)
        }

        #expect(transport.didClose)
        #expect(session.phase == .failed(.timedOut))
        try await session.close()
    }

    @Test("Lifecycle transitions stop claimed writes before reporting cancellation")
    func lifecycleTransitionsStopClaimedWrites() async throws {
        for action in ["detach", "close"] {
            let transport = StallingWriteRPCTransport()
            let session = try RPCSession(
                endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
                workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
                transport: transport,
                requestTimeout: .seconds(5)
            )
            try await session.start()
            let request = Task {
                try await session.exchange(
                    PiRPCRequest(identifier: "claimed-\(action)", kind: .prompt(action))
                )
            }
            for _ in 0 ..< 100 where !transport.isWriteStalled {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(transport.isWriteStalled)

            switch action {
            case "detach": try await session.detach()
            default: try await session.close()
            }

            do {
                _ = try await request.value
                Issue.record("Expected lifecycle cancellation for \(action)")
            } catch let failure as SessionFailure {
                #expect(failure.diagnostic == .cancelled)
                #expect(failure.phase == (action == "detach" ? .detached : .closing))
            }
            #expect(transport.didClose)
            switch action {
            case "detach":
                #expect(session.phase == .detached)
                try await session.close()
            default:
                #expect(session.phase == .closed)
            }
        }
    }

    @Test("Lifecycle retirement drains pending requests when transport close throws")
    func lifecycleRetirementSurvivesCloseFailure() async throws {
        for action in ["detach", "close"] {
            let transport = ControlledRPCTransport(
                respondsAfterStartup: false,
                throwsOnClose: true
            )
            let session = try RPCSession(
                endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
                workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
                transport: transport
            )
            try await session.start()
            let request = Task {
                try await session.exchange(
                    PiRPCRequest(identifier: "pending-\(action)", kind: .prompt("pending"))
                )
            }
            for _ in 0 ..< 100 where transport.requestCount < 2 {
                try await Task.sleep(for: .milliseconds(5))
            }

            do {
                if action == "detach" {
                    try await session.detach()
                } else {
                    try await session.close()
                }
                Issue.record("Expected teardown failure for \(action)")
            } catch let failure as SessionFailure {
                #expect(failure.diagnostic == .connectionFailed)
                #expect(failure.phase == (action == "detach" ? .detached : .closed))
            }
            do {
                _ = try await request.value
                Issue.record("Expected pending request cancellation for \(action)")
            } catch let failure as SessionFailure {
                #expect(failure.diagnostic == .cancelled)
                #expect(failure.phase == (action == "detach" ? .detached : .closing))
            }
            #expect(session.phase == (action == "detach" ? .detached : .closed))
            if action == "detach" {
                _ = try? await session.close()
            }
        }
    }

    @Test("Lifecycle retirement suppresses queued RPC writes")
    func lifecycleRetirementSuppressesQueuedWrite() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()

        let gate = RequestRegistrationGate()
        session.setRequestWriteHook { await gate.pause() }
        let request = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "queued-during-detach", kind: .prompt("do not send"))
            )
        }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }

        try await session.detach()
        session.setRequestWriteHook(nil)
        await gate.release()
        do {
            _ = try await request.value
            Issue.record("Expected detach cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(transport.requestFrames.count == 1)
        #expect(session.phase == .detached)
        try await session.close()
    }

    @Test("A request cannot register against a retired RPC stream")
    func requestRegistrationRejectsRetiredStream() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()

        let gate = RequestRegistrationGate()
        session.setRequestRegistrationHook { await gate.pause() }
        let request = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "retired-stream", kind: .getState)
            )
        }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }

        session.setRequestRegistrationHook(nil)
        try await session.detach()
        try await session.reconnect()
        await gate.release()

        do {
            _ = try await request.value
            Issue.record("Expected retired-stream cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }
        #expect(session.phase == .attached)
        try await session.close()
    }

    @Test("Cancellation before request registration cannot write or time out")
    func cancellationBeforeRegistration() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(40)
        )
        try await session.start()

        let gate = RequestRegistrationGate()
        session.setRequestRegistrationHook { await gate.pause() }
        let request = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "cancelled-before-registration", kind: .getState)
            )
        }
        while await !(gate.hasEntered) {
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        session.setRequestRegistrationHook(nil)
        await gate.release()

        do {
            _ = try await request.value
            Issue.record("Expected request cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(session.phase == .attached)
        try await session.close()
    }

    @Test("Cancellation after registration suppresses the pending RPC write")
    func cancellationAfterRegistrationSuppressesWrite() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()
        #expect(transport.requestFrames.count == 1)

        let gate = RequestRegistrationGate()
        session.setRequestWriteHook { await gate.pause() }
        let request = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "cancelled-after-registration", kind: .prompt("do not run"))
            )
        }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()

        do {
            _ = try await request.value
            Issue.record("Expected request cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }
        session.setRequestWriteHook(nil)
        await gate.release()
        try await Task.sleep(for: .milliseconds(20))

        #expect(transport.requestFrames.count == 1)
        #expect(session.phase == .failed(.cancelled))
        try await session.close()
    }

    @Test("Cancellation tears down an already-claimed RPC write")
    func cancellationTearsDownClaimedWrite() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()

        let gate = RequestRegistrationGate()
        let completion = RequestCompletionFlag()
        session.setRequestWriteClaimHook { await gate.pause() }
        let request = Task {
            do {
                let frame = try await session.exchange(
                    PiRPCRequest(identifier: "claimed-before-cancellation", kind: .prompt("ordered"))
                )
                await completion.markComplete()
                return frame
            } catch {
                await completion.markComplete()
                throw error
            }
        }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        for _ in 0 ..< 100 where await !completion.isComplete {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await completion.isComplete)

        session.setRequestWriteClaimHook(nil)
        await gate.release()
        do {
            _ = try await request.value
            Issue.record("Expected request cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }

        #expect(transport.requestFrames.count == 1)
        #expect(session.phase == .failed(.cancelled))
        try await session.close()
    }

    @Test("Concurrent RPC writes preserve registration order")
    func concurrentWritesPreserveOrder() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()

        let gate = RequestRegistrationGate()
        session.setRequestWriteHook { await gate.pause() }
        let first = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "first-write", kind: .prompt("first"))
            )
        }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "second-write", kind: .abort)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.requestFrames.count == 1)

        session.setRequestWriteHook(nil)
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        let identifiers = transport.requestFrames.dropFirst().compactMap { data -> String? in
            guard let object = try? JSONLFrameDecoder.decode(Data(data.dropLast())) else {
                return nil
            }
            return object["id"]?.stringValue
        }

        #expect(identifiers == ["first-write", "second-write"])
        try await session.close()
    }

    @Test("A fast RPC exit cannot install over its replacement")
    func fastExitCannotReplaceReconnect() async throws {
        let transport = FastExitRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        let initialStart = Task { try await session.start() }
        for _ in 0 ..< 100 where session.phase != .failed(.commandFailed) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.phase == .failed(.commandFailed))

        try await session.reconnect()
        #expect(session.phase == .attached)
        transport.releaseFirstOpen()
        try await initialStart.value
        #expect(session.phase == .attached)
        try await session.close()
    }

    @Test("A recorded fast-exit diagnosis survives open cleanup")
    func fastExitPreservesCommandFailure() async throws {
        let transport = FastExitRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        let initialStart = Task { try await session.start() }
        for _ in 0 ..< 100 where session.phase != .failed(.commandFailed) {
            try await Task.sleep(for: .milliseconds(5))
        }
        transport.releaseFirstOpen()
        try await initialStart.value

        #expect(session.phase == .failed(.commandFailed))
        try await session.close()
    }

    @Test("A clean fast RPC exit reports an unexpected remote close")
    func cleanFastExitPreservesRemoteClose() async throws {
        let transport = FastExitRPCTransport(firstExitStatus: 0)
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        let initialStart = Task { try await session.start() }
        for _ in 0 ..< 100 where session.phase != .failed(.unexpectedRemoteClose) {
            try await Task.sleep(for: .milliseconds(5))
        }
        transport.releaseFirstOpen()
        try await initialStart.value

        #expect(session.phase == .failed(.unexpectedRemoteClose))
        try await session.close()
    }

    @Test("A clean close before startup request registration is unexpected")
    func cleanCloseBeforeStartupRegistration() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        let gate = RequestRegistrationGate()
        session.setRequestRegistrationHook { await gate.pause() }
        let start = Task { try await session.start() }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }

        transport.stopProcess(exitStatus: 0)
        session.setRequestRegistrationHook(nil)
        await gate.release()
        try await start.value

        #expect(session.phase == .failed(.unexpectedRemoteClose))
        #expect(session.lastExchange == nil)
        try await session.close()
    }

    @Test("A clean close after startup response but before recording is unexpected")
    func cleanCloseBeforeStartupRecording() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        let gate = RequestRegistrationGate()
        session.setStartupExchangeHook { await gate.pause() }
        let start = Task { try await session.start() }
        while await !gate.hasEntered {
            try await Task.sleep(for: .milliseconds(5))
        }

        transport.stopProcess(exitStatus: 0)
        session.setStartupExchangeHook(nil)
        await gate.release()
        try await start.value

        #expect(session.phase == .failed(.unexpectedRemoteClose))
        #expect(session.lastExchange == nil)
        try await session.close()
    }

    @Test("A nonzero RPC process exit reports command failure")
    func nonzeroExitIsCommandFailure() async throws {
        let transport = ScriptedRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )
        try await session.start()

        transport.stopProcess(exitStatus: 127)

        #expect(session.phase == .failed(.commandFailed))
        try await session.close()
    }

    @Test("Detach resumes pending requests and preserves the detached phase")
    func detachDrainsPendingRequests() async throws {
        let transport = ControlledRPCTransport(respondsAfterStartup: false)
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(80)
        )
        try await session.start()

        let request = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "detach-pending", kind: .getState)
            )
        }
        while transport.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await session.detach()

        do {
            _ = try await request.value
            Issue.record("Expected detach cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.phase == .detached)
    }

    @Test("Close resumes pending requests and preserves the closed phase")
    func closeDrainsPendingRequests() async throws {
        let transport = ControlledRPCTransport(respondsAfterStartup: false)
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(80)
        )
        try await session.start()

        let request = Task {
            try await session.exchange(
                PiRPCRequest(identifier: "close-pending", kind: .getState)
            )
        }
        while transport.requestCount < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await session.close()

        do {
            _ = try await request.value
            Issue.record("Expected close cancellation")
        } catch let failure as SessionFailure {
            #expect(failure.diagnostic == .cancelled)
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.phase == .closed)
    }

    @Test("An obsolete timed-out open cannot fail its replacement")
    func timeoutReconnectKeepsReplacement() async throws {
        let transport = BlockingCloseRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport,
            requestTimeout: .milliseconds(30)
        )

        let initialStart = Task { try await session.start() }
        for _ in 0 ..< 100 where session.phase != .failed(.timedOut) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.phase == .failed(.timedOut))

        try await session.reconnect()
        #expect(session.phase == .attached)
        transport.releaseCloses()
        try await initialStart.value
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.phase == .attached)
        try await session.close()
    }

    @Test("A superseded RPC stream cannot disconnect its replacement")
    func ignoresSupersededStreamClosure() async throws {
        let transport = GenerationRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        try await session.start()
        transport.fireCurrentClosure()
        #expect(session.phase == .disconnected)
        try await session.reconnect()
        transport.fireSupersededClosure()
        try await Task.sleep(for: .milliseconds(20))

        #expect(session.phase == .attached)
        let response = try await session.exchange(
            PiRPCRequest(identifier: "after-reconnect", kind: .getState)
        )
        #expect(response.isSuccessResponse(command: "get_state"))
        try await session.close()
    }

    @Test("A response command must match its correlated request")
    func responseCommandMustMatchRequest() async throws {
        let transport = ScriptedRPCTransport(responseCommandOverride: "prompt")
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        try await session.start()

        for _ in 0 ..< 100 where !transport.stopped {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.phase == .failed(.malformedFrame))
        #expect(transport.stopped)
        try await session.close()
    }

    @Test("A response ID must correlate to a pending request")
    func responseIDMustMatchPendingRequest() async throws {
        let transport = ScriptedRPCTransport(responseIdentifierOverride: "unknown-id")
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        try await session.start()
        for _ in 0 ..< 100 where !transport.stopped {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(session.phase == .failed(.malformedFrame))
        #expect(transport.stopped)
        try await session.close()
    }

    @Test("A malformed frame later in one batch prevents recording success")
    func validatesWholeRPCBatchBeforeDispatch() async throws {
        let transport = InvalidBatchRPCTransport()
        let session = try RPCSession(
            endpoint: RemoteEndpoint(connectionString: "demo@fixture"),
            workingDirectory: #require(RemoteWorkingDirectory("/tmp")),
            transport: transport
        )

        try await session.start()

        #expect(session.phase == .failed(.malformedFrame))
        #expect(session.lastExchange == nil)
        try await session.close()
    }
}

private final class ControlledRPCTransport: @unchecked Sendable, RPCTransport {
    private let lock = NSLock()
    private let respondsAfterStartup: Bool
    private let throwsOnClose: Bool
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var requests = 0
    private var stopped = false

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    var requestCount: Int {
        lock.withLock { requests }
    }

    var didStop: Bool {
        lock.withLock { stopped }
    }

    init(respondsAfterStartup: Bool, throwsOnClose: Bool = false) {
        self.respondsAfterStartup = respondsAfterStartup
        self.throwsOnClose = throwsOnClose
    }

    func open() async throws -> any RPCChannel {
        ControlledRPCChannel(transport: self)
    }

    func close() async throws {
        lock.withLock { stopped = true }
        if throwsOnClose {
            throw SessionDiagnostic.connectionFailed
        }
    }

    func receive(_ data: Data) {
        let count = lock.withLock {
            requests += 1
            return requests
        }
        guard count == 1 || respondsAfterStartup,
              let request = try? JSONLFrameDecoder.decode(Data(data.dropLast())),
              let identifier = request["id"]?.stringValue
        else { return }
        let response = "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}\n"
        lock.withLock { outputHandler }?(Data(response.utf8))
    }
}

private final class ControlledRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: ControlledRPCTransport?

    init(transport: ControlledRPCTransport) {
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        transport?.receive(data)
    }

    func close() async {}
}

private actor RequestRegistrationGate {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        hasEntered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RequestCompletionFlag {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private final class LockedPhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PiSessionPhase] = []

    var values: [PiSessionPhase] {
        lock.withLock { storage }
    }

    func append(_ phase: PiSessionPhase) {
        lock.withLock { storage.append(phase) }
    }
}

private final class BlockingInterruptTerminalTransport: @unchecked Sendable, TerminalTransport {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    var onOutput: (@Sendable (Data) -> Void)?
    var onClosed: (@Sendable (Int32?) -> Void)?

    var isWriteStalled: Bool {
        lock.withLock { continuation != nil }
    }

    func open(columns _: Int, rows _: Int) async throws -> any TerminalChannel {
        BlockingInterruptTerminalChannel(transport: self)
    }

    func close() async throws {
        releaseWrite()
    }

    func stallWrite() async {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func releaseWrite() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class BlockingInterruptTerminalChannel: @unchecked Sendable, TerminalChannel {
    private weak var transport: BlockingInterruptTerminalTransport?

    init(transport: BlockingInterruptTerminalTransport) {
        self.transport = transport
    }

    func write(_: Data) async throws {
        await transport?.stallWrite()
    }

    func requestResize(columns _: Int, rows _: Int) throws {}

    func close() async {
        transport?.releaseWrite()
    }
}

private final class StallingWriteRPCTransport: @unchecked Sendable, RPCTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var writeCount = 0
    private var stalledWrite: CheckedContinuation<Void, Error>?
    private var closed = false

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    var didClose: Bool {
        lock.withLock { closed }
    }

    var isWriteStalled: Bool {
        lock.withLock { stalledWrite != nil }
    }

    func open() async throws -> any RPCChannel {
        lock.withLock {
            closed = false
            writeCount = 0
        }
        return StallingWriteRPCChannel(transport: self)
    }

    func close() async throws {
        closeChannel()
    }

    func write(_ data: Data) async throws {
        let index = lock.withLock {
            writeCount += 1
            return writeCount
        }
        if index == 1,
           let object = try? JSONLFrameDecoder.decode(Data(data.dropLast())),
           let identifier = object["id"]?.stringValue
        {
            let response = "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}\n"
            lock.withLock { outputHandler }?(Data(response.utf8))
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { stalledWrite = continuation }
        }
    }

    func closeChannel() {
        let resources: (CheckedContinuation<Void, Error>?, (@Sendable (Int32?) -> Void)?) =
            lock.withLock {
                guard !closed else { return (nil, nil) }
                closed = true
                let continuation = stalledWrite
                stalledWrite = nil
                return (continuation, closedHandler)
            }
        resources.0?.resume(throwing: CancellationError())
        resources.1?(nil)
    }
}

private final class StallingWriteRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: StallingWriteRPCTransport?

    init(transport: StallingWriteRPCTransport) {
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        try await transport?.write(data)
    }

    func close() async {
        transport?.closeChannel()
    }
}

private final class FastExitRPCTransport: @unchecked Sendable, RPCTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var openCount = 0
    private let firstExitStatus: Int32
    private var releaseRequested = false
    private var firstOpenContinuation: CheckedContinuation<Void, Never>?

    init(firstExitStatus: Int32 = 127) {
        self.firstExitStatus = firstExitStatus
    }

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    func open() async throws -> any RPCChannel {
        let index = lock.withLock {
            openCount += 1
            return openCount
        }
        if index == 1 {
            lock.withLock { closedHandler }?(firstExitStatus)
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard !releaseRequested else { return true }
                    firstOpenContinuation = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        return FastExitRPCChannel(transport: self, openIndex: index)
    }

    func close() async throws {}

    func releaseFirstOpen() {
        let continuation = lock.withLock {
            releaseRequested = true
            let continuation = firstOpenContinuation
            firstOpenContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    func receive(_ data: Data, openIndex: Int) {
        guard openIndex > 1,
              let request = try? JSONLFrameDecoder.decode(Data(data.dropLast())),
              let identifier = request["id"]?.stringValue
        else { return }
        let response = "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}\n"
        lock.withLock { outputHandler }?(Data(response.utf8))
    }
}

private final class FastExitRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: FastExitRPCTransport?
    private let openIndex: Int

    init(transport: FastExitRPCTransport, openIndex: Int) {
        self.transport = transport
        self.openIndex = openIndex
    }

    func write(_ data: Data) async throws {
        transport?.receive(data, openIndex: openIndex)
    }

    func close() async {}
}

private final class BlockingCloseRPCTransport: @unchecked Sendable, RPCTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var openCount = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closesReleased = false

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    func open() async throws -> any RPCChannel {
        let index = lock.withLock {
            openCount += 1
            return openCount
        }
        return BlockingCloseRPCChannel(transport: self, openIndex: index)
    }

    func close() async throws {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard !closesReleased else { return true }
                closeWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func releaseCloses() {
        let waiters = lock.withLock {
            closesReleased = true
            let waiters = closeWaiters
            closeWaiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func receive(_ data: Data, openIndex: Int) {
        guard openIndex > 1,
              let request = try? JSONLFrameDecoder.decode(Data(data.dropLast())),
              let identifier = request["id"]?.stringValue
        else { return }
        let response = "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}\n"
        lock.withLock { outputHandler }?(Data(response.utf8))
    }
}

private final class BlockingCloseRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: BlockingCloseRPCTransport?
    private let openIndex: Int

    init(transport: BlockingCloseRPCTransport, openIndex: Int) {
        self.transport = transport
        self.openIndex = openIndex
    }

    func write(_ data: Data) async throws {
        transport?.receive(data, openIndex: openIndex)
    }

    func close() async {}
}

private final class GenerationRPCTransport: @unchecked Sendable, RPCTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var supersededClosures: [@Sendable (Int32?) -> Void] = []

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    func open() async throws -> any RPCChannel {
        GenerationRPCChannel(transport: self)
    }

    func close() async throws {
        lock.withLock {
            if let closedHandler {
                supersededClosures.append(closedHandler)
            }
        }
    }

    func fireCurrentClosure() {
        lock.withLock { closedHandler }?(0)
    }

    func fireSupersededClosure() {
        let callback = lock.withLock { supersededClosures.first }
        callback?(0)
    }

    func receive(_ data: Data) {
        guard let request = try? JSONLFrameDecoder.decode(Data(data.dropLast())),
              let identifier = request["id"]?.stringValue
        else { return }
        let response = "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}\n"
        lock.withLock { outputHandler }?(Data(response.utf8))
    }
}

private final class GenerationRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: GenerationRPCTransport?

    init(transport: GenerationRPCTransport) {
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        transport?.receive(data)
    }

    func close() async {}
}

private final class InvalidBatchRPCTransport: @unchecked Sendable, RPCTransport {
    var onOutput: (@Sendable (Data) -> Void)?
    var onClosed: (@Sendable (Int32?) -> Void)?

    func open() async throws -> any RPCChannel {
        InvalidBatchRPCChannel(transport: self)
    }

    func close() async throws {}

    func receive(_ data: Data) {
        guard let request = try? JSONLFrameDecoder.decode(Data(data.dropLast())),
              let identifier = request["id"]?.stringValue
        else { return }
        let batch = "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\",\"success\":true}\n{\"success\":true}\n"
        onOutput?(Data(batch.utf8))
    }
}

private final class InvalidBatchRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: InvalidBatchRPCTransport?

    init(transport: InvalidBatchRPCTransport) {
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        transport?.receive(data)
    }

    func close() async {}
}

private final class AttachRaceTerminalTransport: @unchecked Sendable, TerminalTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var opens = 0
    private var releaseRequested = false
    private var firstOpenContinuation: CheckedContinuation<Void, Never>?

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    func open(columns _: Int, rows _: Int) async throws -> any TerminalChannel {
        let isFirst = lock.withLock {
            opens += 1
            return opens == 1
        }
        if isFirst {
            lock.withLock { closedHandler }?(1)
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    guard !releaseRequested else { return true }
                    firstOpenContinuation = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        return OverflowRecoveryTerminalChannel()
    }

    func close() async throws {}

    func releaseFirstOpen() {
        let continuation = lock.withLock {
            releaseRequested = true
            let continuation = firstOpenContinuation
            firstOpenContinuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class OverflowRecoveryTerminalTransport: @unchecked Sendable, TerminalTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private var gate = OneShotTerminalClosureGate()
    private var opens = 0
    private var reportedClosures = 0

    var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    var openCount: Int {
        lock.withLock { opens }
    }

    var reportedClosureCount: Int {
        lock.withLock { reportedClosures }
    }

    func open(columns _: Int, rows _: Int) async throws -> any TerminalChannel {
        let shouldOverflow = lock.withLock {
            opens += 1
            gate = OneShotTerminalClosureGate()
            return opens == 1
        }
        if shouldOverflow {
            reportClosure(1)
        }
        return OverflowRecoveryTerminalChannel()
    }

    func close() async throws {
        reportClosure(0)
    }

    private func reportClosure(_ status: Int32) {
        guard lock.withLock({ gate }).claim() else { return }
        let handler = lock.withLock {
            reportedClosures += 1
            return closedHandler
        }
        handler?(status)
    }
}

private struct OverflowRecoveryTerminalChannel: TerminalChannel {
    func write(_: Data) async throws {}
    func requestResize(columns _: Int, rows _: Int) throws {}
    func close() async {}
}

private final class ThrowingCloseTerminalTransport: @unchecked Sendable, TerminalTransport {
    private let base = ScriptedTerminalTransport()

    var onOutput: (@Sendable (Data) -> Void)? {
        get { base.onOutput }
        set { base.onOutput = newValue }
    }

    var onClosed: (@Sendable (Int32?) -> Void)? {
        get { base.onClosed }
        set { base.onClosed = newValue }
    }

    func open(columns: Int, rows: Int) async throws -> any TerminalChannel {
        try await base.open(columns: columns, rows: rows)
    }

    func close() async throws {
        try await base.close()
        throw SessionDiagnostic.connectionFailed
    }
}

private final class CancellingTerminalTransport: @unchecked Sendable, TerminalTransport {
    var onOutput: (@Sendable (Data) -> Void)?
    var onClosed: (@Sendable (Int32?) -> Void)?

    func open(columns _: Int, rows _: Int) async throws -> any TerminalChannel {
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }

    func close() async throws {}
}

@Suite("Pane process identity")
struct PaneProcessIdentityTests {
    @Test("The Pi launcher accepts its direct Node process identity")
    func acceptsNodeBackedPi() throws {
        let piExecutables = SSHPTYTransport.compatiblePaneExecutables(for: "exec pi")
        let catExecutables = SSHPTYTransport.compatiblePaneExecutables(for: "exec cat")

        #expect(piExecutables == ["pi", "node"])
        #expect(catExecutables == ["cat"])
        #expect(SSHPTYTransport.launcherPaneExecutable(for: "exec pi") == "pi")
        #expect(SSHPTYTransport.launcherPaneExecutable(for: "exec node") == "node")
        let reportedLauncher = try SSHPTYTransport.reportedStartCommand(
            for: PiTerminalCommand.start(
                workingDirectory: #require(RemoteWorkingDirectory("/tmp"))
            )
        )
        #expect(
            reportedLauncher
                == #""case \"\$SHELL\" in /*) exec \"\$SHELL\" -lc 'cd '\\''/tmp'\\'' && exec pi';; *) exit 127;; esac""#
        )
        #expect(
            SSHPTYTransport.shouldRetryLauncher(
                startCommand: reportedLauncher,
                expectedStartCommand: reportedLauncher,
                executable: "zsh",
                compatibleExecutables: piExecutables
            )
        )
        #expect(
            !SSHPTYTransport.shouldRetryLauncher(
                startCommand: reportedLauncher,
                expectedStartCommand: reportedLauncher,
                executable: "node",
                compatibleExecutables: piExecutables
            )
        )
    }

    @Test("Reconnect identity follows the stable pane PID")
    func stablePIDIgnoresForegroundTool() {
        let pi = TmuxPaneIdentity(
            processID: 12345,
            executable: "node",
            startCommand: "exec pi",
            creationIdentifier: "create-1"
        )
        let childTool = TmuxPaneIdentity(
            processID: 12345,
            executable: "sh",
            startCommand: "exec pi",
            creationIdentifier: "create-1"
        )
        let replacement = TmuxPaneIdentity(
            processID: 12345,
            executable: "node",
            startCommand: "exec pi",
            creationIdentifier: "create-2"
        )

        let markerless = TmuxPaneIdentity(
            processID: 12345,
            executable: "node",
            startCommand: "exec pi",
            creationIdentifier: nil
        )

        #expect(pi.hasSameProcess(as: childTool))
        #expect(!pi.hasSameProcess(as: replacement))
        #expect(!markerless.hasSameProcess(as: markerless))
    }

    @Test("Pane PID collection accepts one bounded decimal line")
    func acceptsPID() {
        let collector = PaneProcessIDCollector()
        collector.feed(Data("12345|cat|\"exec cat\"|create-1\r\n".utf8))

        #expect(collector.isComplete)
        #expect(!collector.failed)
        #expect(collector.paneProcessID == 12345)
        #expect(collector.paneCommand == "cat")
        #expect(collector.paneStartCommand == "\"exec cat\"")
        #expect(collector.creationIdentifier == "create-1")
    }

    @Test("Pane PID collection rejects oversized output immediately")
    func rejectsOversizedOutput() {
        let collector = PaneProcessIDCollector()
        collector.feed(Data(repeating: 0x31, count: 1024 * 1024))

        #expect(collector.isComplete)
        #expect(collector.failed)
        #expect(collector.paneProcessID == nil)
    }

    @Test("Pane PID collection rejects non-decimal output immediately")
    func rejectsInvalidOutput() {
        let collector = PaneProcessIDCollector()
        collector.feed(Data("12x\n".utf8))

        #expect(collector.isComplete)
        #expect(collector.failed)
    }
}

@Suite("Pi RPC messages")
struct PiRPCMessageTests {
    @Test("A get_state request encodes the documented shape")
    func getStateEncoding() throws {
        let request = PiRPCRequest(identifier: "r1", kind: .getState)
        let frame = try request.encodedFrame()

        #expect(frame.last == 0x0A)
        let text = String(decoding: frame.dropLast(), as: UTF8.self)
        #expect(text.contains(#""id":"r1""#))
        #expect(text.contains(#""type":"get_state""#))
    }

    @Test("A prompt request encodes the message with escaped separators")
    func promptEncoding() throws {
        let request = PiRPCRequest(identifier: "r2", kind: .prompt("hello there"))
        let frame = try request.encodedFrame()

        let text = String(decoding: frame.dropLast(), as: UTF8.self)
        #expect(text.contains(#""type":"prompt""#))
        #expect(text.contains(#""message":"hello\u2028there""#))
    }

    @Test("Frames with Unicode separators inside strings survive their own decoder")
    func roundTripsSeparators() throws {
        let request = PiRPCRequest(identifier: "r3", kind: .prompt("sep ok"))
        let frame = try request.encodedFrame()

        var decoder = JSONLFrameDecoder()
        let frames = try decoder.feed(frame)
        #expect(frames.count == 1)
        let value = try JSONLFrameDecoder.decode(frames[0])
        #expect(value["message"]?.stringValue == "sep\u{2029}ok")
    }

    @Test("Responses decode with command, success, and data")
    func responseDecoding() throws {
        let payload = try JSONLFrameDecoder.decode(
            Data(#"{"id":"r1","type":"response","command":"get_state","success":true,"data":{"isStreaming":false}}"#
                .utf8)
        )

        let frame = try #require(PiRPCFrameDecoder.decode(payload))
        #expect(frame.identifier == "r1")
        #expect(frame.answers("r1"))
        #expect(frame.isSuccessResponse(command: "get_state"))
        guard case let .response(command, success, data) = frame.body else {
            Issue.record("Expected a response body")
            return
        }
        #expect(command == "get_state")
        #expect(success)
        #expect(data?["isStreaming"]?.boolValue == false)
    }

    @Test("A numeric success flag is rejected")
    func rejectsNumericSuccess() throws {
        let payload = try JSONLFrameDecoder.decode(
            Data(#"{"id":"r9","type":"response","command":"prompt","success":1}"#.utf8)
        )

        #expect(PiRPCFrameDecoder.decode(payload) == nil)
    }

    @Test("A failed response decodes with success false")
    func failedResponseDecoding() throws {
        let payload = try JSONLFrameDecoder.decode(
            Data(#"{"id":"r9","type":"response","command":"prompt","success":false}"#.utf8)
        )

        let frame = try #require(PiRPCFrameDecoder.decode(payload))
        #expect(frame.isSuccessResponse(command: "prompt") == false)
    }

    @Test("Events decode and never masquerade as responses")
    func eventDecoding() throws {
        let payload = try JSONLFrameDecoder.decode(
            Data(#"{"type":"message_update","data":{}}"#.utf8)
        )

        let frame = try #require(PiRPCFrameDecoder.decode(payload))
        #expect(frame.answers("anything") == false)
        guard case .event = frame.body else {
            Issue.record("Expected an event body")
            return
        }
    }
}
