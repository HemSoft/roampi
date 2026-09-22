import Foundation

/// Starts Pi through the remote account's configured absolute login shell so
/// shell-managed installations (for example nvm or asdf) resolve exactly as
/// they do for an interactive login.
enum PiTerminalCommand {
    static let start = #"case "$SHELL" in /*) exec "$SHELL" -lc 'exec pi';; *) exit 127;; esac"#
}
