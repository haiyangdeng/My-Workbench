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
        let result = await run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], timeout: 30)
        guard result.status == 0 else { return nil }
        return Self.parseStatus(result.output)
    }

    public static func parseStatus(_ text: String) -> [String: String] {
        var entries: [String: String] = [:]
        let records = text.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let line = records[index]; index += 1
            guard line.count > 3 else { continue }
            let code = String(line.prefix(2))
            entries[String(line.dropFirst(3))] = code
            // With -z the destination comes first; the original name is the next NUL record.
            if code.contains("R") || code.contains("C") { index += 1 }
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
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            if values.isSymbolicLink == true {
                result[file] = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)).map { "link:" + $0 }
                continue
            }
            guard values.isRegularFile == true else { continue }
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
        var output = await run(["--literal-pathspecs", "diff", base, "--"] + files, timeout: 60).output
        let untracked = await run(["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--"] + files, timeout: 30).output
        for file in untracked.split(separator: "\0") {
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
        let untracked = await run(["ls-files", "-z", "--others", "--exclude-standard"], timeout: 30).output
        for file in untracked.split(separator: "\0") { output += await run(["diff", "--no-index", "--", "/dev/null", String(file)], timeout: 30).output }
        return output.count > 400_000 ? String(output.prefix(400_000)) + "\n…（差异过长，已截断）" : output
    }

    /// Starting copies are capped per file and in total, so a project with large or un-ignored generated files doesn't
    /// duplicate them on every Edit run. Files over the caps keep only their fingerprint.
    public static let baselineFileLimit = 8 * 1024 * 1024
    public static let baselineCopyBudget = 256 * 1024 * 1024

    /// Initial HEAD plus copies of already-dirty files. No staging, commits or refs are changed. A file that can't be
    /// copied (over the caps, or changed or removed meanwhile) keeps its fingerprint, and its diff falls back to HEAD.
    public func changeBaseline() async -> GitChangeBaseline? {
        guard var status = await status() else { return nil }
        let head = await head(), directory = directory
        if let head {
            let paths = await run(["diff", "--no-renames", "--name-only", "-z", head, "--"], timeout: 30)
            if paths.status == 0 { for file in paths.output.split(separator: "\0").map(String.init) where status[file] == nil { status[file] = " D" } }
        }
        let initialStatus = status
        return await Task.detached {
            let copies = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-baseline-\(UUID())")
            let content = Self.fingerprints(directory: directory, files: Array(initialStatus.keys))
            var saved: Set<String> = [], budget = Self.baselineCopyBudget
            for file in content.keys.sorted() {
                let source = URL(fileURLWithPath: directory).appendingPathComponent(file), target = copies.appendingPathComponent(file)
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard size <= Self.baselineFileLimit, size <= budget else { continue }
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                    saved.insert(file); budget -= size
                } catch { continue }
            }
            return GitChangeBaseline(head: head, status: initialStatus, content: content, saved: saved, copies: copies)
        }.value
    }

    public func changedFiles(since baseline: GitChangeBaseline) async -> [String] {
        guard let after = await status() else { return [] }
        var candidates = Set(baseline.status.keys).union(after.keys)
        if let head = baseline.head {
            let result = await run(["diff", "--no-renames", "--name-only", "-z", head, "--"], timeout: 30)
            if result.status == 0 { candidates.formUnion(result.output.split(separator: "\0").map(String.init)) }
        }
        let files = Array(candidates), directory = directory
        let content = await Task.detached { Self.fingerprints(directory: directory, files: files) }.value
        return candidates.filter { file in
            if baseline.status[file] != nil { return baseline.content[file] != content[file] }
            return true
        }.sorted()
    }

    /// Compare to the actual starting contents, including edits committed by the CLI and pre-existing user edits.
    public func diff(files: [String], since baseline: GitChangeBaseline) async -> String {
        let clean = files.filter { baseline.status[$0] == nil }
        // Dirty at the start but not copied: the best available comparison is HEAD, which includes the earlier edits.
        let unsaved = files.filter { baseline.status[$0] != nil && baseline.content[$0] != nil && !baseline.saved.contains($0) }
        var output = ""
        if !unsaved.isEmpty {
            output = "# 这些文件的起始内容没有保存（文件过大或无法复制），" + (baseline.head == nil ? "无法显示差异" : "差异相对于 HEAD，含运行前已有的改动") + "：" + unsaved.joined(separator: "、") + "\n"
        }
        if let head = baseline.head { output += await diff(files: clean + unsaved, against: head) }
        for file in files where (baseline.status[file] != nil || baseline.head == nil) && !unsaved.contains(file) {
            let old = baseline.content[file] == nil ? "/dev/null" : baseline.copies.appendingPathComponent(file).path
            let newURL = URL(fileURLWithPath: directory).appendingPathComponent(file)
            let new = Self.fingerprints(directory: directory, files: [file])[file] == nil ? "/dev/null" : newURL.path
            guard old != new else { continue }
            let result = await run(["-c", "core.quotePath=false", "diff", "--no-index", "--no-prefix", "--", old, new], timeout: 30)
            // Every metadata line before the first hunk (diff, index, ---/+++, "Binary files … differ") names the two
            // absolute paths, which git prints without their leading "/"; hunk lines are file content and stay as written.
            var header = false
            output += result.output.components(separatedBy: "\n").map { line in
                if line.hasPrefix("diff --git ") { header = true } else if line.hasPrefix("@@") { header = false }
                guard header else { return line }
                return [(baseline.copies.path + "/", "a/"), (URL(fileURLWithPath: directory).path + "/", "b/")].reduce(line) { line, prefix in
                    line.replacingOccurrences(of: prefix.0, with: prefix.1).replacingOccurrences(of: String(prefix.0.dropFirst()), with: prefix.1)
                }
            }.joined(separator: "\n")
        }
        return output
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

public final class GitChangeBaseline: @unchecked Sendable {
    public let head: String?
    public let status: [String: String]
    public let content: [String: String]
    /// Files whose starting contents were copied; the rest of `content` is fingerprint-only.
    public let saved: Set<String>
    fileprivate let copies: URL
    fileprivate init(head: String?, status: [String: String], content: [String: String], saved: Set<String>, copies: URL) {
        self.head = head; self.status = status; self.content = content; self.saved = saved; self.copies = copies
    }
    deinit { try? FileManager.default.removeItem(at: copies) }
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
