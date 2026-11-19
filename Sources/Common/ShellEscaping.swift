import Foundation

public enum ShellEscaping {
    /// Wraps a string in POSIX single quotes, escaping any embedded single quotes as `'\''`.
    /// Safe for passing arbitrary paths or arguments to `/bin/sh` or `bash`.
    public static func posixSingleQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Escapes a string for safe inclusion inside an AppleScript double-quoted string literal (`"..."`).
    public static func escapeForAppleScriptString(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "\"", with: "\\\"")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        return result
    }

    /// Builds a complete AppleScript `do shell script` statement with safe string escaping.
    public static func appleScriptDoShellScript(_ shellCommand: String, administratorPrivileges: Bool = true) -> String {
        let escapedCommand = escapeForAppleScriptString(shellCommand)
        if administratorPrivileges {
            return "do shell script \"\(escapedCommand)\" with administrator privileges"
        } else {
            return "do shell script \"\(escapedCommand)\""
        }
    }
}
