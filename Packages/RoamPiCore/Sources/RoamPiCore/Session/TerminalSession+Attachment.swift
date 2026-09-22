import Foundation

extension TerminalSession {
    /// Runs one attach attempt: connect, allocate the PTY, attach or create the
    /// tmux session, and verify the remote process identity after a reconnect.
    func attach() async {
        let transport = makeTransport()
        configureCallbacks(on: transport)

        do {
            try lock.withLock {
                guard stateMachine.phase == .connecting || stateMachine.phase == .reconnecting else {
                    throw SessionFailure(diagnostic: .cancelled, phase: stateMachine.phase)
                }
                self.transport = transport
            }
            try await openAndInstall(transport)
        } catch {
            try? await transport.close()
            lock.withLock {
                if self.transport === transport {
                    self.transport = nil
                    channel = nil
                }
            }
            markFailure(Self.diagnostic(for: error))
        }
    }

    func configureCallbacks(on transport: TerminalTransportBox) {
        transport.onOutput = { [weak self] data in
            guard let handler = self?.lock.withLock({ self?.outputHandler }) else {
                return
            }
            handler(data)
        }
        transport.onClosed = { [weak self] exitStatus in
            self?.handleChannelClosed(exitStatus: exitStatus)
        }
    }

    func openAndInstall(_ transport: TerminalTransportBox) async throws {
        let (initialColumns, initialRows) = lock.withLock {
            (latestColumns, latestRows)
        }
        let opened = try await transport.open(columns: initialColumns, rows: initialRows)

        do {
            try await verifyProcessIdentity(for: transport)
            let latestSize: ResizeCoalescer.Size = try lock.withLock {
                try stateMachine.markAttached()
                self.transport = transport
                channel = opened
                coalescer.clearLastSent()
                return coalescer.normalized(columns: latestColumns, rows: latestRows)
            }
            try opened.requestResize(columns: latestSize.columns, rows: latestSize.rows)
            publishPhase()
        } catch {
            await opened.close()
            throw error
        }
    }

    func makeTransport() -> TerminalTransportBox {
        if let scripted = configuration.scriptedTransport {
            return scripted
        }
        let attachExisting = lock.withLock { recordedPaneProcessID != nil }
        return TerminalTransportBox(
            SSHPTYTransport(
                endpoint: configuration.endpoint,
                authentication: configuration.authentication,
                sessionName: configuration.sessionName,
                workingDirectory: configuration.workingDirectory,
                attachExisting: attachExisting,
                credentials: configuration.credentials ?? SecureTransportStore.shared
            )
        )
    }

    func verifyProcessIdentity(for transport: TerminalTransportBox) async throws {
        guard let sshTransport = transport.sshTransport else {
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

    func handleChannelClosed(exitStatus: Int32?) {
        lock.withLock {
            guard stateMachine.phase.isConnectedOrRecovering else {
                return
            }
            if let exitStatus, exitStatus != 0 {
                try? stateMachine.fail(.commandFailed)
            } else {
                try? stateMachine.markDisconnected()
            }
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

    static func diagnostic(for error: any Error) -> SessionDiagnostic {
        if error is CancellationError {
            return .cancelled
        }
        if let failure = error as? SessionFailure {
            return failure.diagnostic
        }
        if let diagnostic = error as? SessionDiagnostic {
            return diagnostic
        }
        if let transportError = error as? TransportError {
            return diagnostic(for: transportError)
        }
        return .connectionFailed
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
