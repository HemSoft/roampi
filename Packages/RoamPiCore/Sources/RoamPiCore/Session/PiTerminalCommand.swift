import Foundation

/// Runs a command through the remote account's configured absolute login shell
/// so shell-managed installations resolve as they do for an interactive login.
enum LoginShellCommand {
    static func run(_ command: String, suppressProfileOutput: Bool = false) -> String {
        let loginCommand = suppressProfileOutput
            ? "exec 1>&3 2>&4; \(command)"
            : command
        let redirections = suppressProfileOutput
            ? " 3>&1 4>&2 1>/dev/null 2>/dev/null"
            : ""
        return #"case "$SHELL" in /*) exec "$SHELL" -lc "#
            + ShellQuoting.quote(loginCommand)
            + redirections
            + ";; *) exit 127;; esac"
    }
}

/// Starts Pi through the account login environment.
enum PiTerminalCommand {
    static let start = LoginShellCommand.run("exec pi")
}
