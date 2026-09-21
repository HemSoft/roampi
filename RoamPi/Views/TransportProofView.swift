import SwiftUI
import UIKit

struct TransportProofView: View {
    @StateObject private var model: TransportProofModel
    @State private var showsAdvanced = false
    @State private var showsPublicKey = false

    init(demoMode: Bool = false) {
        let transport: any SSHProbeTransporting = demoMode ? DemoProbeTransport() : NIOSSHProbeTransport()
        _model = StateObject(
            wrappedValue: TransportProofModel(
                coordinator: ProbeCoordinator(transport: transport),
                demoMode: demoMode
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("user@host", text: $model.connectionString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connection-string")

                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        TextField("Port (default 22)", text: $model.advancedPort)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("advanced-port")
                    }

                    Picker("Authentication", selection: $model.authenticationMode) {
                        ForEach(SSHAuthenticationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } header: {
                    Text("Test host")
                } footer: {
                    Text(
                        "Use a MagicDNS name, full .ts.net name, or Tailscale IP. RoamPi never asks for Tailscale account credentials."
                    )
                }

                Section("Host identity") {
                    Label("First use requires fingerprint approval", systemImage: "checkmark.shield")
                    Label("A changed key blocks before authentication", systemImage: "exclamationmark.lock")
                }

                Section("Device key") {
                    DisclosureGroup("Ed25519 public key", isExpanded: $showsPublicKey) {
                        if model.publicKey.isEmpty {
                            ProgressView()
                        } else {
                            Text(model.publicKey)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .accessibilityIdentifier("device-public-key")
                            Button("Copy public key") {
                                UIPasteboard.general.string = model.publicKey
                            }
                        }
                    }
                }

                statusSection

                Section {
                    if case .running = model.state {
                        Button("Cancel probe", role: .cancel) {
                            model.cancel()
                        }
                    } else {
                        Button("Inspect host key and run probe") {
                            model.runProbe()
                        }
                        .disabled(model.connectionString.isEmpty)
                        .accessibilityIdentifier("run-transport-probe")
                    }
                } footer: {
                    Text(
                        "The probe opens one SSH connection, executes a fixed non-mutating command once, verifies its private response, and discards the output."
                    )
                }
            }
            .navigationTitle("SSH transport proof")
            .onAppear { model.loadPublicKey() }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.state {
        case .idle:
            Section("Ready") {
                Label("No connection attempted", systemImage: "network")
            }
        case .running:
            Section("Testing") {
                HStack {
                    ProgressView()
                    Text("Connecting through the active network route")
                }
            }
        case let .awaitingConfirmation(fingerprint):
            Section("Confirm server fingerprint") {
                Text(fingerprint)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("host-fingerprint")
                Text("Compare this value with a trusted source before continuing.")
                    .foregroundStyle(.secondary)
                Button("Trust fingerprint and reconnect") {
                    model.confirmHostKeyAndReconnect()
                }
                .accessibilityIdentifier("trust-host-key")
            }
        case let .succeeded(result):
            Section("Probe passed") {
                Label("Verified SSH command completed once", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Authentication", value: authenticationLabel(result.authentication))
                LabeledContent("Elapsed", value: "\(result.elapsedMilliseconds) ms")
            }
        case let .failed(message):
            Section("Probe stopped") {
                Label(message, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
    }

    private func authenticationLabel(_ offer: SSHAuthenticationOffer) -> String {
        switch offer {
        case .none:
            "Tailscale SSH none"
        case .publicKey:
            "Ed25519 key"
        }
    }
}
