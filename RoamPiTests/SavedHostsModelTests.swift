import Foundation
@testable import RoamPi
import RoamPiCore
import Testing

private actor FixtureHostProbe: SSHProbeTransporting {
    enum Behavior { case firstUse, changedKey, rejectedKey, unreachable }
    let behavior: Behavior
    private var trusted = false
    private(set) var probeCount = 0
    private(set) var trustCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func publicKey() -> String {
        "ssh-ed25519 fixture-key"
    }

    func runProbe(endpoint _: RemoteEndpoint, mode _: SSHAuthenticationMode) throws -> ProbeResult {
        probeCount += 1
        switch behavior {
        case .firstUse where !trusted:
            throw TransportError.hostKeyConfirmationRequired(fingerprint: "SHA256:fixture")
        case .changedKey:
            throw TransportError.diagnostic(.hostKeyChanged)
        case .rejectedKey:
            throw TransportError.diagnostic(.authenticationFailed)
        case .unreachable:
            throw TransportError.diagnostic(.connectionFailed)
        default:
            return ProbeResult(elapsedMilliseconds: 1, authentication: .publicKey)
        }
    }

    func trust(fingerprint _: String, endpoint _: RemoteEndpoint) {
        trusted = true
        trustCount += 1
    }
}

@Suite("Saved host launch gate")
@MainActor
struct SavedHostsModelTests {
    private func fixture() throws -> (ConnectionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("roampi-host-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return (ConnectionStore(directoryURL: directory), directory)
    }

    private func awaitState(_ model: SavedHostsModel, check: (SavedHostsModel.ConnectionState) -> Bool) async {
        for _ in 0 ..< 100 {
            if check(model.state) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("First-use trust is separate from saving and required before terminal launch")
    func approval() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = FixtureHostProbe(.firstUse)
        let model = SavedHostsModel(store: store, probe: probe)
        #expect(await model.save(
            existing: nil,
            name: "Home",
            connection: "me@host.example",
            port: "22",
            directory: "/home/me/work",
            session: "pi-home"
        ) == nil)
        let profile = try #require(model.profiles.first)
        #expect(try await store.list() == [profile])
        #expect(await probe.probeCount == 0)
        model.openTerminal()
        #expect(model.activeProfile == nil)
        model.check(profile)
        await awaitState(model) {
            if case .fingerprint = $0 {
                true
            } else {
                false
            }
        }
        #expect(model.state == .fingerprint("SHA256:fixture"))
        model.trust(typedFingerprint: "wrong")
        #expect(await probe.trustCount == 0)
        model.openTerminal()
        #expect(model.activeProfile == nil)
        model.trust(typedFingerprint: "SHA256:fixture")
        await awaitState(model) { $0 == .ready }
        #expect(model.state == .ready)
        #expect(await probe.trustCount == 1)
        model.openTerminal()
        #expect(model.activeProfile == profile)
        model.closeTerminal()
        #expect(model.activeProfile == nil)
    }

    @Test("Host-key change, rejected key, and offline host never launch or overwrite trust")
    func failureStates() async throws {
        for behavior in [FixtureHostProbe.Behavior.changedKey, .rejectedKey, .unreachable] {
            let (store, directory) = try fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let probe = FixtureHostProbe(behavior)
            let model = SavedHostsModel(store: store, probe: probe)
            #expect(await model.save(
                existing: nil,
                name: "Host",
                connection: "me@host.example",
                port: "",
                directory: "/home/me/work",
                session: "pi"
            ) == nil)
            let profile = try #require(model.profiles.first)
            model.check(profile)
            await awaitState(model) {
                if case .failed = $0 {
                    true
                } else {
                    false
                }
            }
            #expect(model.state != .ready)
            model.openTerminal()
            #expect(model.activeProfile == nil)
            #expect(await probe.trustCount == 0)
        }
    }

    @Test("Editing retains the ID but requires a new check before opening")
    func editInvalidatesCheck() async throws {
        let (store, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = SavedHostsModel(store: store, probe: FixtureHostProbe(.firstUse))
        #expect(await model.save(
            existing: nil,
            name: "Home",
            connection: "me@host.example",
            port: "",
            directory: "/one",
            session: "pi"
        ) == nil)
        let before = try #require(model.profiles.first)
        #expect(await model.save(
            existing: before,
            name: "Edited",
            connection: "me@[2001:db8::1]",
            port: "2222",
            directory: "/two",
            session: "pi-new"
        ) == nil)
        let after = try #require(model.profiles.first)
        #expect(after.id == before.id)
        #expect(after.endpoint.host == "2001:db8::1")
        #expect(after.endpoint.port == 2222)
        #expect(after.projectDirectory.absolutePath == "/two")
        #expect(model.state == .idle)
        model.openTerminal()
        #expect(model.activeProfile == nil)
    }
}
