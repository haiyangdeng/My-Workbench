import Foundation

/// Apps opened from Finder get a minimal PATH. This asks the user's own login shell, once, where a command lives
/// and what PATH it uses. The command name travels as a positional argument, never inside the script text.
public enum LoginShell {
    public struct Lookup: Equatable, Sendable {
        public var executable: String?
        public var searchPath: String?
    }

    static let script = #"printf '__WB_CMD__%s\n' "$(command -v -- "$1" 2>/dev/null)"; printf '__WB_PATH__%s\n' "$PATH""#

    public static var defaultShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/zsh", "/opt/homebrew/bin/bash", "/usr/local/bin/zsh", "/usr/local/bin/bash"].contains(shell) && FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    public static func lookup(_ command: String, shell: String = defaultShell, interactive: Bool = true) async -> Lookup {
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.contains("\0") else { return Lookup() }
        var tool = ToolConfig(name: "login shell", executable: shell, arguments: [interactive ? "-ilc" : "-lc", script, "workbench", name.isEmpty ? "true" : name])
        tool.timeoutSeconds = 8
        let output = OutputBuffer()
        let directory = FileManager.default.homeDirectoryForCurrentUser.path
        guard let result = try? await ProcessRunner().run(id: UUID(), tool: tool, input: "", directory: directory, arguments: tool.arguments, onOutput: { chunk in if chunk.stream == .stdout { output.append(chunk.text) } }),
              !result.timedOut else { return Lookup() }
        return parse(output.text, requireExecutable: !name.isEmpty)
    }

    static func parse(_ text: String, requireExecutable: Bool = true) -> Lookup {
        var lookup = Lookup()
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("__WB_CMD__") {
                let path = String(line.dropFirst("__WB_CMD__".count))
                if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { lookup.executable = path }
            } else if line.hasPrefix("__WB_PATH__") {
                let path = String(line.dropFirst("__WB_PATH__".count))
                if !path.isEmpty, !path.contains("\0") { lookup.searchPath = path }
            }
        }
        return lookup
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); if value.utf8.count < 256 * 1024 { value += text }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}
