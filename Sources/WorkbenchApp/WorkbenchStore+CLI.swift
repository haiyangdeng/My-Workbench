import Foundation

struct TestPromptResult: Equatable {
    var running = true
    var succeeded = false
    var reply = ""
    var sessionID: String?
    var detail = ""
    var finishedAt: Date?
}

extension WorkbenchStore {
    static let archivedProjectMessage = "这个项目已归档，只能查看。请先在项目页取消归档。"

    /// The level a run uses: the task's request, capped by the agent's maximum. Planning and review are always read-only.
    func accessLevel(for task: WorkTask, employee: Employee, tool: ToolConfig) throws -> AccessLevel {
        let ceiling = employee.maxAccess ?? .readOnly
        var level = min(task.accessLevel ?? ceiling, ceiling)
        if task.purpose == .planning || task.purpose == .review { level = .readOnly }
        guard tool.supports(level) else { throw CLIError.accessUnsupported(level) }
        return level
    }

    /// Planner and reviewer agents only need a CLI that can run read-only.
    func canPlanOrReview(_ employee: Employee) -> Bool {
        guard !employee.isDeleted, employee.enabled ?? true, let tool = tool(employee.toolID) else { return false }
        return tool.isEnabled && tool.isCLI && tool.supports(.readOnly)
    }
    var planningCandidates: [Employee] { snapshot.employees.current.filter(canPlanOrReview) }

    /// Extra environment for a CLI. With "use my login shell's PATH", the PATH found at launch replaces Finder's minimal one.
    func environment(for tool: ToolConfig) -> [String: String] {
        guard tool.useLoginShellPath == true, let path = shellSearchPath else { return [:] }
        return ["PATH": path]
    }
    func environmentAfterLookup(for tool: ToolConfig) async -> [String: String] {
        if tool.useLoginShellPath == true && shellSearchPath == nil { shellSearchPath = await LoginShell.lookup("true").searchPath }
        return environment(for: tool)
    }

    /// Resolves what the user typed in the Executable field: an absolute path stays as is, a name goes through the login shell.
    func resolveExecutable(_ text: String) async -> LoginShell.Lookup {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("/") { return LoginShell.Lookup(executable: FileManager.default.isExecutableFile(atPath: value) ? value : nil, searchPath: shellSearchPath) }
        guard !value.isEmpty, !value.contains("/") else { return LoginShell.Lookup() }
        let lookup = await LoginShell.lookup(value)
        if let path = lookup.searchPath { shellSearchPath = path }
        return lookup
    }

    /// Writes what the CLI said into the run: result.md for event formats, result.json when a schema was requested.
    func recordOutput(_ summary: CLIOutputSummary, runID: UUID, outputDirectory: String, format: CLIOutputFormat, structured: Bool, log: RunLog) {
        let output = URL(fileURLWithPath: outputDirectory)
        let markdown = output.appendingPathComponent("result.md")
        if format != .plainText, !summary.replyText.isEmpty, !FileManager.default.fileExists(atPath: markdown.path) {
            do { try Data(summary.replyText.utf8).write(to: markdown, options: .withoutOverwriting) }
            catch { log.append("[system] 回复保存失败：\(error.localizedDescription)\n") }
        }
        if structured {
            let json = output.appendingPathComponent("result.json")
            if let data = summary.structuredJSON ?? CLIOutputCollector.extractJSONObject(from: summary.replyText), !FileManager.default.fileExists(atPath: json.path) {
                do { try data.write(to: json, options: .withoutOverwriting) }
                catch { log.append("[system] 结构化结果保存失败：\(error.localizedDescription)\n") }
            }
        }
        if let message = summary.errorMessage { log.append("\n[system] CLI 报告：\(message)\n") }
        guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else { return }
        if snapshot.runs[index].sessionID == nil { snapshot.runs[index].sessionID = summary.sessionID }
        if !summary.replyText.isEmpty { snapshot.runs[index].replyText = String(summary.replyText.prefix(16_000)) }
        if !summary.usage.isEmpty { snapshot.runs[index].usage = summary.usage }
    }

    /// Explicit, user-started check that the CLI answers. Uses the account's quota; creates no task or run.
    func sendTestPrompt(_ toolID: UUID) {
        guard let tool = tool(toolID), !tool.isDeleted, tool.isCLI, testPrompts[toolID]?.running != true else { return }
        guard tool.executableAvailable else { missingCLIToolID = toolID; return }
        let scratch = archive.root.deletingLastPathComponent().appendingPathComponent("Scratch", isDirectory: true)
        let level: AccessLevel = tool.supports(.readOnly) ? .readOnly : .edit
        let session = tool.assignsSessionID ? UUID().uuidString.lowercased() : nil
        let arguments: [String]
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            arguments = try tool.invocation(CLIInvocation(prompt: "这是 Workbench 的连接测试。只回复：ok", outputDirectory: scratch.path, workingDirectory: scratch.path, access: level, sessionID: session))
        } catch { testPrompts[toolID] = TestPromptResult(running: false, detail: error.localizedDescription, finishedAt: Date()); return }
        testPrompts[toolID] = TestPromptResult()
        var probe = tool; probe.timeoutSeconds = min(tool.timeout, 180)
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-test-\(UUID()).log")
        Task {
            defer { try? FileManager.default.removeItem(at: logURL) }
            var result = TestPromptResult(running: false, finishedAt: Date())
            do {
                let log = try RunLog(url: logURL)
                let collector = CLIOutputCollector(format: tool.format)
                let environment = await environmentAfterLookup(for: tool)
                let process = try await runner.run(id: UUID(), tool: probe, input: "", directory: scratch.path, arguments: arguments, environment: environment, onOutput: { chunk in
                    log.append(chunk); if chunk.stream == .stdout { collector.consume(chunk.text) }
                })
                let summary = collector.finish(); let tail = log.drain(); try? log.close()
                result.succeeded = process.status == .review && summary.errorMessage == nil && !summary.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                result.reply = String(summary.replyText.prefix(2000)); result.sessionID = summary.sessionID ?? session
                result.detail = result.succeeded ? "退出码 0" : "\(process.status.title) · 退出码 \(process.exitCode)\n\(summary.errorMessage ?? String(tail.suffix(1500)))"
            } catch { result.detail = error.localizedDescription }
            result.finishedAt = Date()
            guard self.tool(toolID) == tool else { return }
            testPrompts[toolID] = result
        }
    }
}
