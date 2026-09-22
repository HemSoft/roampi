import Foundation

/// Builds the remote commands used for tmux sessions. Every user-derived value
/// is validated by `TmuxSessionName` or `RemoteWorkingDirectory` and then
/// single-quoted, so command-injection forms never reach the remote shell.
enum TmuxCommand {
    /// Creates one new session after a negative identity preflight.
    ///
    /// Deliberately omits `-A`: a concurrent name collision must fail creation
    /// rather than attaching to an unverified pane. `exec` replaces the login
    /// shell so the PTY lifetime maps onto the tmux client lifetime.
    static func attachOrCreate(
        session: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory,
        paneCommand: String = "exec pi"
    ) -> String {
        "cd \(ShellQuoting.quote(workingDirectory.absolutePath)) "
            + "&& exec tmux new-session -s \(ShellQuoting.quote(session.rawValue)) "
            + ShellQuoting.quote(paneCommand)
    }

    /// Reconnects attach only; they must never create a replacement session
    /// before the recorded pane identity has been verified.
    static func attachExisting(
        session: TmuxSessionName,
        workingDirectory: RemoteWorkingDirectory
    ) -> String {
        "cd \(ShellQuoting.quote(workingDirectory.absolutePath)) "
            + "&& exec tmux attach-session -t \(ShellQuoting.quote(session.rawValue))"
    }

    /// Detach-proof identity query: the tmux pane process ID for one session.
    /// Reconnect logic compares this value against the identity recorded before
    /// the interruption to prove the same Pi process is still in use.
    static func paneProcessID(session: TmuxSessionName) -> String {
        "tmux display-message -p -t \(ShellQuoting.quote(session.rawValue)) '#{pane_pid}|#{pane_current_command}|#{pane_start_command}'"
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
    /// A login shell resolves the same Pi installation used interactively, but
    /// its profile output is discarded until the fixed command restores the SSH
    /// stdout/stderr descriptors. `--no-session` keeps the exchange out of Pi
    /// session history.
    static func start(workingDirectory: RemoteWorkingDirectory) -> String {
        "cd \(ShellQuoting.quote(workingDirectory.absolutePath)) "
            + "&& case \"$SHELL\" in /*) exec \"$SHELL\" -lc "
            + "'exec 1>&3 2>&4; exec pi --mode rpc --no-session' "
            + "3>&1 4>&2 1>/dev/null 2>/dev/null ;; *) exit 126 ;; esac"
    }
}
