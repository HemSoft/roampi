import Foundation

extension TerminalSession {
    /// Runs one attach attempt: connect, allocate the PTY, attach or create the
    /// tmux session, and verify the remote process identity after a reconnect.
    func attach() async {
        var candidateTransport: (any TerminalTransport)?
        do {
            let transport = makeTransport()

            transport.onOutput = { [weak self] data in
                guard let handler = self?.lock.withLock({ self?.outputHandler }) else {
                    return
                }
                handler(data)
            }
            transport.onClosed = { [weak self] exitStatus in
                self?.handleChannelClosed(exitStatus: exitStatus)
            }

            candidateTransport = transport
            let (initialColumns, initialRows) = lock.withLock {
                (latestColumns, latestRows)
            }
            let opened = try await transport.open(columns: initialColumns, rows: initialRows)

            do {
                try await verifyProcessIdentity(for: transport)

                try lock.withLock {
                    try stateMachine.markAttached()
                    self.transport = transport
                    self.channel = opened
                    coalescer.clearLastSent()
                }
                publishPhase()
            } catch {
                await opened.close()
                try? await transport.close()
                throw error
            }
        } catch is CancellationError {
            try? await candidateTransport?.close()
            markFailure(.cancelled)
        } catch let failure as SessionFailure {
            try? await candidateTransport?.close()
            markFailure(failure.diagnostic)
        } catch let diagnostic as SessionDiagnostic {
            try? await candidateTransport?.close()
            markFailure(diagnostic)
        } catch let transportError as TransportError {
            try? await candidateTransport?.close()
            markFailure(Self.diagnostic(for: transportError))
        } catch {
            try? await candidateTransport?.close()
            markFailure(.connectionFailed)
        }
    }

    func makeTransport() -> any TerminalTransport {
        if let scripted = configuration.scriptedTransport {
            return scripted
        }
        return SSHPTYTransport(
            endpoint: configuration.endpoint,
            authentication: configuration.authentication,
            sessionName: configuration.sessionName,
            workingDirectory: configuration.workingDirectory,
            credentials: configuration.credentials ?? SecureTransportStore.shared
        )
    }

    func verifyProcessIdentity(for transport: any TerminalTransport) async throws {
        guard let sshTransport = transport as? SSHPTYTransport else {
            return
        }

        let previous = lock.withLock { recordedPaneProcessID }
        let observed = try await observePaneProcessID(transport: sshTransport)
        guard previous == nil || previous == observed else {
            lock.withLock { processIdentityUnchanged = false }
            throw SessionFailure(
                diagnostic: .processIdentityChanged,
                phase: .failed(.processIdentityChanged)
            )
        }
        lock.withLock {
            recordedPaneProcessID = observed
            if previous != nil {
                processIdentityUnchanged = true
            }
        }
    }

    /// Waits briefly for tmux to expose the attached pane identity. Every SSH
    /// attach records it; reconnects compare against that first observation.
    func observePaneProcessID(transport: SSHPTYTransport) async throws -> Int32 {
        var attempts = 0
        while attempts < 40 {
            if let paneProcessID = try await transport.paneProcessID() {
                return paneProcessID
            }
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        throw SessionFailure(diagnostic: .commandFailed, phase: .connecting)
    }

    func handleChannelClosed(exitStatus _: Int32?) {
        lock.withLock {
            guard stateMachine.phase.isConnectedOrRecovering else {
                return
            }
            try? stateMachine.markDisconnected()
            channel = nil
        }
        publishPhase()
    }

    func markFailure(_ diagnostic: SessionDiagnostic) {
        lock.withLock {
            try? stateMachine.fail(diagnostic)
        }
        publishPhase()
    }

    func publishPhase() {
        lock.withLock { phaseChangeHandler }?(lock.withLock { stateMachine.phase })
    }

    static func diagnostic(for transportError: TransportError) -> SessionDiagnostic {
        switch transportError {
        case let .diagnostic(diagnostic):
            sessionDiagnostic(diagnostic)
        case .hostKeyConfirmationRequired:
            .hostKeyChanged
        }
    }

    static func sessionDiagnostic(_ diagnostic: TransportDiagnostic) -> SessionDiagnostic {
        switch diagnostic {
        case .authenticationFailed:
            .authenticationFailed
        case .cancelled:
            .cancelled
        case .commandFailed:
            .commandFailed
        case .connectionFailed:
            .connectionFailed
        case .duplicateProbe:
            .invalidState
        case .hostKeyChanged:
            .hostKeyChanged
        case .invalidEndpoint:
            .invalidEndpoint
        case .keyUnavailable:
            .keyUnavailable
        case .timedOut:
            .timedOut
        }
    }
}
