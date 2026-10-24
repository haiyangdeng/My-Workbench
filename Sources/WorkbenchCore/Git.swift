import CryptoKit
import Foundation

/// Minimal git operations for changed-file lists (CH-11) and worktree isolation (TM-08).
/// Every call passes paths and names as separate argv elements; nothing goes through a shell.
public struct GitRepository: Sendable {
    public static let executable = "/usr/bin/git"
    public let directory: String
    public init(directory: String) { self.directory = directory }

    public struct Result: Sendable { public var status: Int32; public var output: String }

    public func run(_ arguments: [String], timeout: Double = 60) async -> Result {
        var tool = ToolConfig(name: "git", executable: Self.executable, arguments: [])
        tool.timeoutSeconds = timeout
        let buffer = GitOutput()
        let environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        guard let result = try? await ProcessRunner().run(id: UUID(), tool: tool, input: "", directory: directory, arguments: ["-C", directory] + arguments, environment: environment, onOutput: { buffer.append($0.text) }) else {
            return Result(status: -1, output: "无法运行 git")
        }
        return Result(status: result.timedOut ? -2 : result.exitCode, output: buffer.text)
    }

    public func isRepository() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else { return false }
        let result = await run(["rev-parse", "--is-inside-work-tree"], timeout: 10)
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Path → two-letter porcelain status, untracked files included.
    public func status() async -> [String: String]? {
        let result = await run(["status", "--porcelain=v1", "--untracked-files=all"], timeout: 30)
        guard result.status == 0 else { return nil }
        return Self.parseStatus(result.output)
    }

    public static func parseStatus(_ text: String) -> [String: String] {
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.count > 3 {
            let code = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            entries[path] = code
        }
        return entries
    }

    /// Files whose status changed between two snapshots, or whose content changed while their status stayed the same
    /// (a file the user had already modified keeps " M" when an agent edits it further). Sorted.
    public static func changedFiles(before: [String: String], after: [String: String], beforeContent: [String: String] = [:], afterContent: [String: String] = [:]) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] || (beforeContent[$0] != nil && beforeContent[$0] != afterContent[$0]) }.sorted()
    }

    /// Content fingerprints of the given files (relative to `directory`): a SHA-256 of the bytes, or size and date for
    /// files over 64 MB. Missing files and folders are left out.
    public static func fingerprints(directory: String, files: some Collection<String>) -> [String: String] {
        var result: [String: String] = [:]
        let base = URL(fileURLWithPath: directory)
        for file in files {
            let url = base.appendingPathComponent(file)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
            if (values.fileSize ?? 0) > 64 * 1024 * 1024 {
                result[file] = "size:\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            } else if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                result[file] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    /// Unified diff for the given files, including untracked ones (shown as new files).
    public func diff(files: [String], against base: String = "HEAD") async -> String {
        guard !files.isEmpty else { return "" }
        var output = await run(["diff", base, "--"] + files, timeout: 60).output
        let untracked = await run(["ls-files", "--others", "--exclude-standard", "--"] + files, timeout: 30).output
        for file in untracked.split(separator: "\n") {
            output += await run(["diff", "--no-index", "--", "/dev/null", String(file)], timeout: 30).output
        }
        return output.count > 400_000 ? String(output.prefix(400_000)) + "\n…（差异过长，已截断）" : output
    }

    public func head() async -> String? {
        let result = await run(["rev-parse", "HEAD"], timeout: 10)
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !value.isEmpty ? value : nil
    }
    /// Everything that differs from `base`: committed and uncommitted tracked changes, plus new untracked files.
    public func diffAll(against base: String) async -> String {
        var output = await run(["diff", base], timeout: 60).output
        let untracked = await run(["ls-files", "--others", "--exclude-standard"], timeout: 30).output
        for file in untracked.split(separator: "\n") { output += await run(["diff", "--no-index", "--", "/dev/null", String(file)], timeout: 30).output }
        return output.count > 400_000 ? String(output.prefix(400_000)) + "\n…（差异过长，已截断）" : output
    }

    // MARK: Worktrees

    public func addWorktree(path: String, branch: String) async -> Result {
        await run(["worktree", "add", "-b", branch, path, "HEAD"], timeout: 120)
    }
    /// Commits everything in a worktree on its own branch. "Nothing to commit" counts as success.
    public func commitAll(message: String) async -> Result {
        _ = await run(["add", "-A"], timeout: 60)
        let result = await run(["-c", "user.name=Workbench", "-c", "user.email=workbench@localhost", "commit", "-m", message], timeout: 60)
        if result.status != 0 && result.output.contains("nothing to commit") { return Result(status: 0, output: result.output) }
        return result
    }
    public func merge(branch: String, message: String) async -> Result {
        await run(["-c", "user.name=Workbench", "-c", "user.email=workbench@localhost", "merge", "--no-ff", "-m", message, branch], timeout: 120)
    }
    public func removeWorktree(path: String) async -> Result { await run(["worktree", "remove", "--force", path], timeout: 60) }
    public func deleteBranch(_ branch: String) async -> Result { await run(["branch", "-D", branch], timeout: 30) }
}

/// One git worktree created for a team step (TM-08).
public struct WorktreeInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, merged, discarded, conflict, unavailable }
    public var path: String
    public var branch: String
    public var repository: String
    public var state: State
    public var baseCommit: String?
    public var note: String?
    public init(path: String, branch: String, repository: String, state: State = .active) {
        self.path = path; self.branch = branch; self.repository = repository; self.state = state
    }
}

/// A CLI definition as a shareable file (TL-09). Carries no credentials; ID, version and enabled state are not exported.
public struct CLIDefinitionFile: Codable, Equatable, Sendable {
    public var format = "myworkbench.cli"
    public var version = 1
    public var tool: ToolConfig
    public init(tool: ToolConfig) {
        var copy = tool
        copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        copy.detectedVersion = nil; copy.enabled = nil; copy.versionChanged = nil
        self.tool = copy
    }
    /// Reads a file and returns a new, unsaved definition with its own ID.
    public static func load(_ data: Data) throws -> ToolConfig {
        let file = try JSONDecoder().decode(CLIDefinitionFile.self, from: data)
        guard file.format == "myworkbench.cli", file.version == 1, file.tool.isCLI else { throw CocoaError(.fileReadCorruptFile) }
        var tool = file.tool; tool.id = UUID()
        return tool
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

private final class GitOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); if value.utf8.count < 2_000_000 { value += text }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}
