import Foundation

/// Builds the remote commands used for tmux sessions. Every user-derived value
/// is validated by `TmuxSessionName` or `RemoteWorkingDirectory` and then
/// single-quoted, so command-injection forms never reach the remote shell.
enum TmuxCommand {
    /// The approved attach-or-create command, run inside the approved directory.
    ///
    /// Equivalent of `tmux new-session -A -s <name>`: attach when the session
    /// exists, create it when it does not. `exec` replaces the login shell so the
    /// PTY lifetime maps onto the tmux client lifetime.
    static func attachOrCreate(
        session: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory
    ) -> String {
        "cd \(ShellQuoting.quote(workingDirectory.absolutePath)) "
            + "&& exec tmux new-session -A -s \(ShellQuoting.quote(session.rawValue))"
    }

    /// Detach-proof identity query: the tmux pane process ID for one session.
    /// Reconnect logic compares this value against the identity recorded before
    /// the interruption to prove the same Pi process is still in use.
    static func paneProcessID(session: TmuxSessionName) -> String {
        "tmux display-message -p -t \(ShellQuoting.quote(session.rawValue)) '#{pane_pid}'"
    }

    /// True when the named session exists on the remote host.
    static func hasSession(session: TmuxSessionName) -> String {
        "tmux has-session -t \(ShellQuoting.quote(session.rawValue)) 2>/dev/null"
    }

    /// Kill one named session during cleanup of a disposable test session.
    static func killSession(session: TmuxSessionName) -> String {
        "tmux kill-session -t \(ShellQuoting.quote(session.rawValue)) 2>/dev/null"
    }
}

/// Builds the remote command that starts a native RPC Pi session.
enum PiRPCCommand {
    /// Starts `pi --mode rpc` inside the approved directory.
    ///
    /// `sh -lc` resolves `pi` from the login environment, which is where the
    /// bootstrap installs it. `--no-session` keeps disposable RPC exchanges out
    /// of the user's Pi session history.
    static func start(workingDirectory: RemoteWorkingDirectory) -> String {
        "cd \(ShellQuoting.quote(workingDirectory.absolutePath)) "
            + "&& exec sh -lc 'exec pi --mode rpc --no-session'"
    }
}
