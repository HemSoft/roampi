import RoamPiCore
import SwiftUI
import UIKit

@MainActor
final class SavedHostsModel: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case checking
        case fingerprint(String)
        case ready
        case failed(String)
    }

    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var publicKey = ""
    @Published private(set) var message: String?
    @Published private(set) var activeProfile: ConnectionProfile?

    let isDemo: Bool
    private let store: ConnectionStore
    private let host: RemoteHost
    private var request: Task<Void, Never>?
    private var generation = 0
    private var candidate: ConnectionProfile?
    private var loaded = false

    init(demo: Bool = false) {
        isDemo = demo
        store = demo
            ? ConnectionStore(directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("roampi-saved-host-demo-\(UUID().uuidString)"))
            : (try? ConnectionStore.applicationStore()) ?? ConnectionStore(
                directoryURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("RoamPi")
            )
        host = demo ? RemoteHost(probe: DemoProbeTransport()) : RemoteHost()
    }

    init(store: ConnectionStore, host: RemoteHost) {
        isDemo = false
        self.store = store
        self.host = host
    }

    deinit { request?.cancel() }

    func load() {
        guard !loaded else { return }
        loaded = true
        Task {
            await refresh()
            do {
                publicKey = try await host.devicePublicKey()
            } catch {
                message = TransportDiagnostic.keyUnavailable.userMessage
            }
        }
    }

    func refresh() async {
        do {
            profiles = try await store.list()
            message = nil
        } catch let error as ConnectionStoreError {
            message = error.userMessage
        } catch {
            message = ConnectionStoreError.storageUnavailable.userMessage
        }
    }

    func save(
        existing: ConnectionProfile?, name: String, connection: String, port: String,
        directory: String, session: String
    ) async -> String? {
        do {
            let profile = try ConnectionProfile(
                id: existing?.id ?? UUID(), displayName: name,
                connectionString: connection, advancedPort: port,
                projectDirectory: directory, sessionChoice: .terminal, tmuxSessionName: session
            )
            if existing == nil {
                try await store.add(profile)
            } else {
                try await store.update(profile)
            }
            cancelCheck()
            await refresh()
            return nil
        } catch let error as ConnectionProfileError {
            return error.userMessage
        } catch let error as ConnectionStoreError {
            return error.userMessage
        } catch {
            return ConnectionStoreError.storageUnavailable.userMessage
        }
    }

    func check(_ profile: ConnectionProfile) {
        cancelCheck()
        guard profile.sessionChoice == .terminal else {
            state = .failed("Edit this native RPC profile to choose a tmux terminal.")
            return
        }
        candidate = profile
        state = .checking
        let attempt = generation
        request = Task {
            do {
                _ = try await host.verify(profile)
                guard !Task.isCancelled, generation == attempt else { return }
                state = .ready
            } catch let TransportError.hostKeyConfirmationRequired(fingerprint) {
                guard !Task.isCancelled, generation == attempt else { return }
                state = .fingerprint(fingerprint)
            } catch let TransportError.diagnostic(diagnostic) {
                guard !Task.isCancelled, generation == attempt else { return }
                state = .failed(diagnostic.userMessage)
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                state = .failed(TransportDiagnostic.connectionFailed.userMessage)
            }
        }
    }

    func trust(typedFingerprint: String) {
        guard case let .fingerprint(fingerprint) = state,
              typedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines) == fingerprint,
              let profile = candidate else { return }
        state = .checking
        let attempt = generation
        request = Task {
            do {
                try await host.trust(fingerprint, for: profile)
                guard !Task.isCancelled, generation == attempt else { return }
                _ = try await host.verify(profile)
                guard !Task.isCancelled, generation == attempt else { return }
                state = .ready
            } catch let TransportError.diagnostic(diagnostic) {
                guard !Task.isCancelled, generation == attempt else { return }
                state = .failed(diagnostic.userMessage)
            } catch {
                guard !Task.isCancelled, generation == attempt else { return }
                state = .failed(TransportDiagnostic.connectionFailed.userMessage)
            }
        }
    }

    func openTerminal() {
        guard state == .ready, let candidate,
              profiles.contains(candidate), candidate.tmuxSessionName != nil else { return }
        activeProfile = candidate
    }

    func makeTerminalSession(for profile: ConnectionProfile) -> TerminalSession? {
        host.terminalSession(for: profile, transport: isDemo ? ScriptedTerminalTransport() : nil)
    }

    func closeTerminal() {
        activeProfile = nil
        cancelCheck()
    }

    func cancelCheck() {
        generation += 1
        request?.cancel()
        request = nil
        candidate = nil
        state = .idle
    }
}

struct SavedHostsView: View {
    @StateObject private var model: SavedHostsModel
    @State private var editor: HostEditorDraft?
    @State private var fingerprintInput = ""
    @State private var terminalModel: TerminalScreenModel?

    init(demo: Bool = false) {
        _model = StateObject(wrappedValue: SavedHostsModel(demo: demo))
    }

    var body: some View {
        NavigationStack {
            List {
                if let message = model.message {
                    Section { Label(message, systemImage: "exclamationmark.triangle") }
                }
                Section("Saved SSH hosts") {
                    if model.profiles.isEmpty {
                        Text("Add a reachable SSH host to open Pi in tmux.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(profile.displayName).font(.headline)
                            Text("Project and tmux session are saved on this device.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if profile.sessionChoice == .terminal {
                                    Button("Open \(profile.displayName)") {
                                        fingerprintInput = ""
                                        model.check(profile)
                                    }
                                    .accessibilityIdentifier("open-saved-host-\(profile.id)")
                                } else {
                                    Text("Native RPC profile. Edit to choose a tmux terminal.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button("Edit") {
                                    model.cancelCheck()
                                    editor = HostEditorDraft(profile: profile)
                                }
                                .accessibilityIdentifier("edit-saved-host-\(profile.id)")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                if !model.profiles.isEmpty {
                    connectionSection
                }
                Section("Device key") {
                    if model.publicKey.isEmpty {
                        Text("Device key unavailable or still loading.")
                    } else {
                        Text(model.publicKey)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("saved-device-public-key")
                        Button("Copy public key") { UIPasteboard.general.string = model.publicKey }
                            .accessibilityIdentifier("copy-saved-public-key")
                    }
                    Text("Install this key on the host yourself. RoamPi does not change the host during setup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SSH hosts")
            .toolbar {
                Button("Add host", systemImage: "plus") { editor = HostEditorDraft() }
                    .accessibilityIdentifier("add-saved-host")
            }
            .sheet(item: $editor) { draft in
                HostEditorView(draft: draft) { name, connection, port, directory, session in
                    await model.save(
                        existing: draft.profile,
                        name: name,
                        connection: connection,
                        port: port,
                        directory: directory,
                        session: session
                    )
                }
            }
            .fullScreenCover(item: $terminalModel) { terminal in
                SavedTerminalPresentation(model: terminal) {
                    terminalModel = nil
                    model.closeTerminal()
                }
            }
            .onChange(of: model.activeProfile) { _, profile in
                guard let profile, let session = model.makeTerminalSession(for: profile) else { return }
                terminalModel = TerminalScreenModel(session: session)
            }
            .task { model.load() }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .checking:
            Section("Connecting") { ProgressView("Checking host identity and SSH authorization") }
        case let .fingerprint(fingerprint):
            Section("Confirm host identity") {
                Text(fingerprint).font(.body.monospaced()).textSelection(.enabled)
                    .accessibilityIdentifier("saved-host-fingerprint")
                Text(
                    "Compare this fingerprint with an independent trusted source. Type it exactly to approve this host and port."
                )
                .font(.caption)
                TextField("Verified fingerprint", text: $fingerprintInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("verified-fingerprint-input")
                Button("Trust and check SSH") { model.trust(typedFingerprint: fingerprintInput) }
                    .disabled(fingerprintInput.trimmingCharacters(in: .whitespacesAndNewlines) != fingerprint)
                    .accessibilityIdentifier("trust-saved-host")
                Button("Reject", role: .cancel) { model.cancelCheck() }
                    .accessibilityIdentifier("reject-saved-host")
            }
        case .ready:
            Section("SSH ready") {
                Text("Host identity and device key verified. Open Pi only if this project and session are yours.")
                Button("Open Pi terminal") { model.openTerminal() }
                    .accessibilityIdentifier("launch-saved-terminal")
            }
        case let .failed(message):
            Section("Connection stopped") {
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                    .accessibilityIdentifier("saved-host-error")
                Button("Dismiss") { model.cancelCheck() }
            }
        }
    }
}

/// Waits for an attached PTY to detach before dismissing it. Back is disabled
/// during connection setup so an in-flight SSH command cannot outlive the view.
struct SavedTerminalPresentation: View {
    @ObservedObject var model: TerminalScreenModel
    let onLeave: () -> Void
    @State private var leaving = false

    static func canLeave(_ phase: PiSessionPhase) -> Bool {
        switch phase {
        case .attached, .interrupted, .detached, .disconnected, .closed, .failed:
            true
        case .idle, .connecting, .reconnecting, .closing:
            false
        }
    }

    var body: some View {
        NavigationStack {
            TerminalScreenView(model: model)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back to hosts") {
                            leaving = true
                            Task {
                                if model.phase != .closed {
                                    do {
                                        if model.canDetach {
                                            try await model.session.detach()
                                        } else {
                                            try await model.session.close()
                                        }
                                    } catch {
                                        // Stay on the terminal when teardown fails.
                                        leaving = false
                                        return
                                    }
                                }
                                onLeave()
                            }
                        }
                        .disabled(!Self.canLeave(model.phase) || leaving)
                        .accessibilityIdentifier("back-to-hosts")
                    }
                }
        }
        .interactiveDismissDisabled()
    }
}

struct HostEditorDraft: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile?

    init(profile: ConnectionProfile? = nil) {
        self.profile = profile
    }
}

struct HostEditorView: View {
    let draft: HostEditorDraft
    let save: (String, String, String, String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var connection: String
    @State private var port: String
    @State private var directory: String
    @State private var session: String
    @State private var error: String?
    @State private var saving = false

    init(draft: HostEditorDraft, save: @escaping (String, String, String, String, String) async -> String?) {
        self.draft = draft
        self.save = save
        let profile = draft.profile
        _name = State(initialValue: profile?.displayName ?? "")
        let endpoint = profile?.endpoint
        let host = endpoint?.host ?? ""
        _connection = State(initialValue: endpoint.map {
            "\($0.username)@\(host.contains(":") ? "[\(host)]" : host)"
        } ?? "")
        _port = State(initialValue: endpoint.map { String($0.port) } ?? "")
        _directory = State(initialValue: profile?.projectDirectory.absolutePath ?? "")
        _session = State(initialValue: profile?.tmuxSessionName?.rawValue ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Display name", text: $name)
                        .accessibilityIdentifier("host-display-name")
                    TextField("user@host", text: $connection)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("host-connection")
                    TextField("Port (default 22)", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("host-port")
                    Text("DNS, IPv4, and IPv6 work over any reachable SSH route. Tailscale is optional.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Pi terminal") {
                    TextField("Absolute project directory", text: $directory)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("host-project")
                    TextField("tmux session name", text: $session)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("host-session")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Text("Saving does not connect, trust a host key, install a key, or run a remote command.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(draft.profile == nil ? "Add SSH host" : "Edit SSH host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            error = await save(name, connection, port, directory, session)
                            saving = false
                            if error == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("save-host")
                }
            }
        }
    }
}
