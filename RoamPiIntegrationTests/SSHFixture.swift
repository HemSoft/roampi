import Crypto
import Darwin
import Foundation
import NIOSSH
@testable import RoamPiCore

/// Disposable SSH integration fixture: temporary directories, generated host
/// keys, a user-level sshd on a private high port, and a protocol-faithful
/// `pi` RPC stub. Nothing here touches the live tailnet, provider
/// credentials, or the developer's sessions.
@MainActor
final class SSHFixture: @unchecked Sendable {
    enum FixtureError: Error {
        case prerequisitesMissing(String)
        case startupFailed(String)
    }

    let root: URL
    let workDirectory: URL
    let endpoint: RemoteEndpoint
    let credentials: FixtureCredentials
    let clientPublicKeyForAuthorizedKeys: String
    let tmuxSessionPrefix: String

    private let sshdProcess: Process
    private let tmuxDirectory: URL
    private let tmuxSocketPath: String

    var port: Int {
        endpoint.port
    }

    init() throws {
        guard FileManager.default.fileExists(atPath: "/usr/sbin/sshd") else {
            throw FixtureError.prerequisitesMissing("sshd is unavailable on this host")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("roampi-itest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        self.root = root

        workDirectory = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let tmuxSuffix = UUID().uuidString.prefix(8).lowercased()
        tmuxDirectory = URL(fileURLWithPath: "/tmp/roampi-tmux-\(tmuxSuffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmuxDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmuxDirectory.path)
        tmuxSocketPath = tmuxDirectory
            .appendingPathComponent("tmux-\(getuid())/default")
            .path
        tmuxSessionPrefix = "roampi-\(tmuxSuffix)"

        // Host key via ssh-keygen; it never leaves the temporary directory.
        let hostKeyPath = root.appendingPathComponent("hostkey").path
        try Self.runProcess(
            "/usr/bin/ssh-keygen",
            arguments: ["-q", "-t", "ed25519", "-N", "", "-f", hostKeyPath]
        )

        // Client key generated in-process; the private key never touches disk.
        let clientKey = Curve25519.Signing.PrivateKey()
        let clientPublic = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: clientKey).publicKey)
        let hostPublicLine = try String(contentsOfFile: hostKeyPath + ".pub", encoding: .utf8)
        let hostFingerprint = try Self.fingerprint(openSSHLine: hostPublicLine)
        credentials = FixtureCredentials(privateKey: clientKey, fingerprint: hostFingerprint)
        clientPublicKeyForAuthorizedKeys = clientPublic

        let authorizedKeys = root.appendingPathComponent("authorized_keys")
        try Data((clientPublic + "\n").utf8).write(to: authorizedKeys)

        let port = Self.reserveFreePort()
        endpoint = try RemoteEndpoint(connectionString: "\(NSUserName())@127.0.0.1:\(port)")

        let configPath = root.appendingPathComponent("sshd_config")
        let logPath = root.appendingPathComponent("sshd.log")
        let shellSearchPath = Self.remoteSearchPath(for: root)
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKeyPath)
        PidFile \(root.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(authorizedKeys.path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AllowTcpForwarding no
        X11Forwarding no
        PrintMotd no
        SetEnv PATH=\(shellSearchPath) TMUX_TMPDIR=\(tmuxDirectory.path)

        """
        try Data(config.utf8).write(to: configPath)

        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-e", "-f", configPath.path, "-E", logPath.path]
        try sshd.run()
        sshdProcess = sshd

        var reachable = false
        for _ in 0 ..< 100 {
            if sshdProcess.isRunning, Self.canConnect(host: "127.0.0.1", port: port) {
                reachable = true
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard reachable else {
            let log = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
            stop()
            throw FixtureError.startupFailed("sshd did not listen within five seconds: \(log)")
        }
    }

    func sessionName(_ suffix: String) -> String {
        "\(tmuxSessionPrefix)-\(suffix)"
    }

    /// A terminal transport bound to the fixture endpoint and credentials.
    func makeTransport(sessionName: String) -> SSHPTYTransport {
        SSHPTYTransport(
            endpoint: endpoint,
            authentication: .standardKey,
            sessionName: TmuxSessionName(sessionName)!,
            workingDirectory: RemoteWorkingDirectory(workDirectory.path)!,
            credentials: credentials
        )
    }

    /// An RPC transport whose remote command runs the fixture stub directly,
    /// so the framing test does not depend on the remote login PATH.
    func makeRPCTransport(
        crOnlyMode: Bool = false,
        partialTrailerMode: Bool = false,
        oversizedMode: Bool = false
    ) throws -> SSHRPCTransport {
        let stubPath = try Self.writeRPCStub(
            in: root,
            crOnlyMode: crOnlyMode,
            partialTrailerMode: partialTrailerMode,
            oversizedMode: oversizedMode
        )
        return SSHRPCTransport(
            endpoint: endpoint,
            authentication: .standardKey,
            workingDirectory: RemoteWorkingDirectory(workDirectory.path)!,
            credentials: credentials,
            remoteCommand: "exec '\(stubPath)'"
        )
    }

    /// Runs one command over a fresh exec channel and returns stdout.
    func exec(_ command: String) async throws -> String {
        let transport = SSHSessionTransport(credentials: credentials)
        let connection = try await transport.connect(endpoint: endpoint, mode: .standardKey)
        defer { Task { await connection.close() } }

        let channel = try await connection.openExecSession(command: command)
        defer { Task { await channel.close() } }

        let collector = FixtureOutputCollector()
        channel.onOutput = { data, isStdErr in
            guard !isStdErr else { return }
            collector.feed(data)
        }
        channel.onClosed = {
            collector.complete()
        }

        for _ in 0 ..< 200 {
            if collector.isComplete {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return collector.text
    }

    func paneProcessID(sessionName: String) async throws -> Int32? {
        guard let session = TmuxSessionName(sessionName) else { return nil }
        let text = try await exec(TmuxCommand.paneProcessID(session: session))
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func tmuxSessionCount(name: String) async throws -> Int {
        guard let session = TmuxSessionName(name) else { return -1 }
        let output = try await exec(
            "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -cxF '\(session.rawValue)'"
        )
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    func killSession(name: String) async throws {
        guard let session = TmuxSessionName(name) else { return }
        _ = try await exec(TmuxCommand.killSession(session: session))
    }

    func stop() {
        if let tmuxPath = Self.locateExecutable("tmux") {
            try? Self.runProcess(tmuxPath, arguments: ["-S", tmuxSocketPath, "kill-server"])
        }
        if sshdProcess.isRunning {
            sshdProcess.terminate()
            sshdProcess.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: tmuxDirectory)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private static func fingerprint(openSSHLine: String) throws -> String {
        let fields = openSSHLine.split(separator: " ", maxSplits: 2)
        guard fields.count >= 2, let keyData = Data(base64Encoded: String(fields[1])) else {
            throw FixtureError.startupFailed("generated host public key was invalid")
        }
        let digest = SHA256.hash(data: keyData)
        return "SHA256:\(Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }

    private static func remoteSearchPath(for root: URL) -> String {
        var directories = [root.appendingPathComponent("stubbin").path]
        if let tmuxPath = locateExecutable("tmux") {
            directories.append((tmuxPath as NSString).deletingLastPathComponent)
        }
        directories.append("/usr/bin")
        directories.append("/bin")
        return directories.joined(separator: ":")
    }

    private static func locateExecutable(_ name: String) -> String? {
        let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func runProcess(_ path: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.startupFailed("\(path) exited \(process.terminationStatus)")
        }
    }

    private static func reserveFreePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_port = 0

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            return 0
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        var resolved = sockaddr_in()
        withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        _ = listen(socketFD, 1)
        return Int(UInt16(bigEndian: resolved.sin_port))
    }

    private static func canConnect(host _: String, port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_port = in_port_t(port).bigEndian

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }

        var pending = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
        poll(&pending, 1, 200)
        var errorValue: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &errorValue, &optionLength)
        return errorValue == 0
    }

    private static func writeRPCStub(
        in root: URL,
        crOnlyMode: Bool,
        partialTrailerMode: Bool,
        oversizedMode: Bool
    ) throws -> String {
        let bin = root.appendingPathComponent("stubbin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let postResponse = switch (crOnlyMode, partialTrailerMode, oversizedMode) {
        case (true, false, false):
            "printf '{\"poison\":true}\\r{\"after\":1}\\n'; exit 0"
        case (false, true, false):
            "printf '{\"partial\":true}'; exit 0"
        case (false, false, true):
            "printf '{\"bulk\":\"%s\"}' \"$(head -c 1100000 /dev/zero | tr '\\0' 'a')\"; exit 0"
        default:
            ":"
        }

        let script = """
        #!/bin/sh
        # Protocol-faithful pi RPC stub for integration tests.
        emit_banner() {
            printf '{"type":"banner","version":"stub"}\\n'
        }
        respond() {
            printf '{"id":"%s","type":"response","command":"get_state","success":true,"data":{"isStreaming":false,"messageCount":0}}\\n' "$1"
        }
        emit_banner
        while IFS= read -r line; do
            case "$line" in
                *'"type":"get_state"'*)
                    identifier=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
                    respond "$identifier"
                    POST_RESPONSE_PLACEHOLDER
                    ;;
                *)
                    printf '{"type":"response","command":"unknown","success":true}\\n'
                    ;;
            esac
        done
        """
        let body = script.replacingOccurrences(
            of: "POST_RESPONSE_PLACEHOLDER",
            with: postResponse
        )

        let stubPath = bin.appendingPathComponent("pi").path
        try Data(body.utf8).write(to: URL(fileURLWithPath: stubPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubPath)
        return stubPath
    }
}

/// In-memory credentials for fixture connections.
struct FixtureCredentials: SSHSessionCredentials {
    private let key: Curve25519.Signing.PrivateKey
    private let hostFingerprint: String

    init(privateKey: Curve25519.Signing.PrivateKey, fingerprint: String) {
        key = privateKey
        hostFingerprint = fingerprint
    }

    func privateKey() async throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func fingerprint(for _: RemoteEndpoint) async throws -> String? {
        hostFingerprint
    }

    func save(fingerprint _: String, for _: RemoteEndpoint) async throws {}
}

/// Collects exec output until the channel closes.
final class FixtureOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var done = false

    func feed(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
        }
    }

    func complete() {
        lock.withLock {
            done = true
        }
    }

    var isComplete: Bool {
        lock.withLock { done }
    }

    var text: String {
        lock.withLock {
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
