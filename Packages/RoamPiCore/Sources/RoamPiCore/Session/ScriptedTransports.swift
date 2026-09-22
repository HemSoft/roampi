import Foundation

/// Deterministic scripted transport for terminal demo and simulator UI tests.
///
/// The script feeds a fixed banner, echoes printable input, records resize and
/// detach requests, and can stop once. It performs no network or file access.
public final class ScriptedTerminalTransport: @unchecked Sendable, TerminalTransport {
    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private(set) var resizeRequests: [ResizeCoalescer.Size] = []
    private(set) var wrote: [Data] = []
    private(set) var detachRequested = false
    private var currentChannel: ScriptedTerminalChannel?

    public var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    public var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    public init() {}

    public func open(columns _: Int, rows _: Int) async throws -> any TerminalChannel {
        let channel = ScriptedTerminalChannel(transport: self)
        lock.withLock {
            currentChannel = channel
        }
        feed("RoamPi scripted terminal\r\n")
        return channel
    }

    public func close() async throws {
        lock.withLock {
            detachRequested = true
        }
    }

    func feed(_ text: String) {
        lock.withLock { outputHandler }?(Data(text.utf8))
    }

    func recordWrite(_ data: Data) {
        lock.withLock {
            wrote.append(data)
        }
        // Echo printable input back so typing is visible in the demo view.
        let printable = data.filter { (0x20 ... 0x7E).contains($0) }
        if !printable.isEmpty {
            lock.withLock { outputHandler }?(Data(printable))
        }
    }

    func recordResize(columns: Int, rows: Int) {
        lock.withLock {
            resizeRequests.append(ResizeCoalescer.Size(columns: columns, rows: rows))
        }
    }

    func closeChannel() {
        lock.withLock { closedHandler }?(0)
    }

    var currentChannelRef: ScriptedTerminalChannel? {
        lock.withLock { currentChannel }
    }
}

final class ScriptedTerminalChannel: @unchecked Sendable, TerminalChannel {
    private weak var transport: ScriptedTerminalTransport?

    init(transport: ScriptedTerminalTransport) {
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        transport?.recordWrite(data)
    }

    func requestResize(columns: Int, rows: Int) throws {
        transport?.recordResize(columns: columns, rows: rows)
    }

    func close() async {
        try? await transport?.close()
    }
}

/// Deterministic scripted RPC transport: answers `get_state` with a fixed
/// response and records prompts, performing no network access.
public final class ScriptedRPCTransport: @unchecked Sendable, RPCTransport {
    public init() {}

    private let lock = NSLock()
    private var outputHandler: (@Sendable (Data) -> Void)?
    private var closedHandler: (@Sendable (Int32?) -> Void)?
    private(set) var requestFrames: [Data] = []
    private(set) var stopped = false

    public var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.withLock { outputHandler } }
        set { lock.withLock { outputHandler = newValue } }
    }

    public var onClosed: (@Sendable (Int32?) -> Void)? {
        get { lock.withLock { closedHandler } }
        set { lock.withLock { closedHandler = newValue } }
    }

    public func open() async throws -> any RPCChannel {
        let channel = ScriptedRPCChannel(transport: self)
        // An initial event frame, matching how Pi streams alongside responses.
        feed(#"{"type":"banner","version":"0.86.1"}"#)
        return channel
    }

    public func close() async throws {
        lock.withLock {
            stopped = true
        }
    }

    func feed(_ line: String) {
        lock.withLock { outputHandler }?(Data((line + "\n").utf8))
    }

    func handleRequest(_ frame: Data) {
        lock.withLock {
            requestFrames.append(frame)
        }

        guard let text = String(data: frame, encoding: .utf8),
              let request = try? JSONLFrameDecoder.decode(Data(text.dropLast().utf8)),
              let identifier = request["id"]?.stringValue
        else {
            return
        }

        if request["type"]?.stringValue == "get_state" {
            feed(
                "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"get_state\","
                    + "\"success\":true,\"data\":{\"isStreaming\":false,\"messageCount\":0}}"
            )
        } else {
            feed(
                "{\"id\":\"\(identifier)\",\"type\":\"response\",\"command\":\"\(request["type"]?.stringValue ?? "")\","
                    + "\"success\":true}"
            )
        }
    }

    func stopProcess() {
        lock.withLock { closedHandler }?(0)
    }
}

final class ScriptedRPCChannel: @unchecked Sendable, RPCChannel {
    private weak var transport: ScriptedRPCTransport?

    init(transport: ScriptedRPCTransport) {
        self.transport = transport
    }

    func write(_ data: Data) async throws {
        transport?.handleRequest(data)
    }

    func close() async {
        try? await transport?.close()
    }
}
