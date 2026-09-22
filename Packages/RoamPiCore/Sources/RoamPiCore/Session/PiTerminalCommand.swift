import Foundation

/// Runs a command through the remote account's configured absolute login shell
/// so shell-managed installations resolve as they do for an interactive login.
enum LoginShellCommand {
    static func run(_ command: String) -> String {
        #"case "$SHELL" in /*) exec "$SHELL" -lc "#
            + ShellQuoting.quote(command)
            + ";; *) exit 127;; esac"
    }
}

/// Starts Pi through the account login environment.
enum PiTerminalCommand {
    static let start = LoginShellCommand.run("exec pi")
}
