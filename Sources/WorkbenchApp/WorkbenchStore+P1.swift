import Foundation

/// P1 items of PRD v0.6 (M9).
extension WorkbenchStore {
    // MARK: TL-09–11 CLI definitions

    /// Runs and chat turns in progress that use this CLI.
    func activeRunCount(toolID: UUID) -> Int {
        let active = Set(activeRuns.values).union(activeTurns.values)
        return snapshot.runs.filter { active.contains($0.id) && $0.tool.id == toolID }.count
    }

    @discardableResult func duplicateTool(_ id: UUID) -> UUID? {
        guard var copy = tool(id), copy.isCLI else { return nil }
        copy.id = UUID(); copy.name += " 副本"; copy.detectedVersion = nil; copy.versionChanged = nil
        guard addTool(copy) else { return nil }
        // Secret variables live in the Keychain under the CLI's ID; the copy gets its own items.
        for name in copy.secretEnvironmentNames ?? [] {
            if let value = try? CredentialVault.cliEnvironment.read(account: CredentialVault.account(toolID: id, name: name)) {
                try? CredentialVault.cliEnvironment.save(value, account: CredentialVault.account(toolID: copy.id, name: name))
            }
        }
        return copy.id
    }
    func exportedDefinition(_ id: UUID) throws -> Data {
        guard let tool = tool(id), tool.isCLI else { throw CocoaError(.fileNoSuchFile) }
        return try CLIDefinitionFile(tool: tool).encoded()
    }
    /// Adds an imported definition. Its executable path may not exist on this Mac; the card then offers "修正路径".
    @discardableResult func importDefinition(_ data: Data) -> UUID? {
        do {
            let tool = try CLIDefinitionFile.load(data)
            return addTool(tool) ? tool.id : nil
        } catch { errorMessage = "这个文件不是 Workbench 导出的 CLI 定义。"; return nil }
    }

    // MARK: TL-08 usage totals

    func usageTotal(_ include: (TaskRun) -> Bool) -> CLIUsage? {
        var total = CLIUsage(), any = false
        for run in snapshot.runs where include(run) {
            guard let usage = run.usage else { continue }
            any = true
            if let cost = usage.costUSD { total.costUSD = (total.costUSD ?? 0) + cost }
            if let input = usage.inputTokens { total.inputTokens = (total.inputTokens ?? 0) + input }
            if let output = usage.outputTokens { total.outputTokens = (total.outputTokens ?? 0) + output }
        }
        return any ? total : nil
    }
    static func describe(_ usage: CLIUsage) -> String {
        [usage.costUSD.map { String(format: "$%.4f", $0) }, usage.inputTokens.map { "输入 \($0)" }, usage.outputTokens.map { "输出 \($0) tokens" }].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: PJ-08 home counts

    func projectCount(moduleID: UUID) -> Int { activeProjects.filter { snapshot.modules(of: $0).contains(moduleID) }.count }

    // MARK: CH-11 changed files

    /// Git status of a folder, or nil when it is not a git work tree.
    func gitStatus(_ directory: String) async -> [String: String]? {
        let repository = GitRepository(directory: directory)
        guard await repository.isRepository() else { return nil }
        return await repository.status()
    }
    func diff(directory: String, files: [String]) async -> String {
        await GitRepository(directory: directory).diff(files: files)
    }

    /// The initial HEAD and working contents, taken before an Edit run (nil outside a git work tree).
    func changeBaseline(_ directory: String) async -> GitChangeBaseline? {
        await GitRepository(directory: directory).changeBaseline()
    }
    /// Files the run changed since the baseline, including further edits to files that were already modified.
    func changedFiles(since baseline: GitChangeBaseline, directory: String) async -> [String] {
        await GitRepository(directory: directory).changedFiles(since: baseline)
    }
    /// Saves the files an Edit step changed, with their diff, as `.workbench/changes.diff` in the run's outputs, apart from
    /// anything the agent writes there. Reviewers receive it as evidence (TM-07); without it they only see the step's reply
    /// and cannot check work done in the project.
    func writeChangeEvidence(files: [String], directory: String, outputDirectory: String, log: RunLog, baseline: GitChangeBaseline? = nil) async {
        guard !files.isEmpty else { return }
        let repository = GitRepository(directory: directory)
        var diff = if let baseline { await repository.diff(files: files, since: baseline) } else { await repository.diff(files: files) }
        let limit = 200_000
        if diff.utf8.count > limit { diff = String(decoding: Data(diff.utf8.prefix(limit)), as: UTF8.self) + "\n…（差异超过 200 KB，其余已省略）\n" }
        let body = "本次运行在项目中改动的文件（\(files.count) 个）：\n" + files.map { "- " + $0 }.joined(separator: "\n") + "\n\n" + diff
        do {
            let target = URL(fileURLWithPath: outputDirectory).appendingPathComponent(RunArchive.changeEvidencePath), folder = target.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // The agent can write to its output folder; never follow a link left in place of ours.
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw WorkbenchError.unsafeArtifact }
            try body.write(to: target, atomically: true, encoding: .utf8)
            log.append("[system] 本次改动了 \(files.count) 个文件，差异已保存为 changes.diff\n")
        } catch { log.append("[system] 改动记录保存失败：\(error.localizedDescription)\n") }
    }

    /// New turns show their saved run diff; older records retain the live-diff fallback.
    func changedDiff(for turn: ChatMessage, directory: String, files: [String]) async -> String {
        if let runID = turn.runID,
           let artifact = artifacts(for: runID).first(where: \.isChangeEvidence),
           let url = try? archive.url(for: artifact), let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return await diff(directory: directory, files: files)
    }

    // MARK: TM-08 worktrees

    func needsWorktree(_ task: WorkTask) -> Bool {
        guard task.worktree == nil, task.generation == nil, task.command == nil,
              let planID = task.planID, snapshot.plans.first(where: { $0.id == planID })?.useWorktrees == true,
              let employee = employee(task.employeeID), let tool = tool(employee.toolID), tool.isCLI else { return false }
        return (try? accessLevel(for: task, employee: employee, tool: tool)) == .edit
    }

    /// Creates the step's own worktree on a new branch, then queues it again to run there.
    func prepareWorktree(_ id: UUID) {
        guard let task = snapshot.tasks.first(where: { $0.id == id }), !isArchived(projectID: task.projectID) else { return }
        preparingWorktrees.insert(id)
        let repositoryPath = task.workingDirectory
        let path = archive.root.appendingPathComponent("worktrees/\(id.uuidString)").path
        let branch = "workbench/\(String((task.planID ?? id).uuidString.prefix(8)).lowercased())-\(String(id.uuidString.prefix(8)).lowercased())"
        Task {
            let repository = GitRepository(directory: repositoryPath)
            var info: WorktreeInfo
            if await repository.isRepository() {
                try? FileManager.default.createDirectory(at: archive.root.appendingPathComponent("worktrees"), withIntermediateDirectories: true)
                let base = await repository.head()
                let result = await repository.addWorktree(path: path, branch: branch)
                info = WorktreeInfo(path: path, branch: branch, repository: repositoryPath, state: result.status == 0 ? .active : .unavailable)
                info.baseCommit = base
                if result.status != 0 { info.note = "创建 worktree 失败，改在项目文件夹中运行：" + result.output.suffix(300) }
            } else {
                info = WorktreeInfo(path: "", branch: "", repository: repositoryPath, state: .unavailable)
                info.note = "项目文件夹不是 git 仓库，改在项目文件夹中运行（同一时间只有一个可编辑步骤）。"
            }
            // Clear the flag before scheduling, or the scheduler would still see the step as being prepared.
            preparingWorktrees.remove(id)
            guard let index = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return }
            change { snapshot in
                snapshot.tasks[index].worktree = info
                if info.state == .active { snapshot.tasks[index].workingDirectory = info.path }
                if let note = info.note { snapshot.tasks[index].log += "[system] \(note)\n" }
            }
            schedulePending()
        }
    }

    func worktreeDiff(_ taskID: UUID) async -> String {
        guard let worktree = snapshot.tasks.first(where: { $0.id == taskID })?.worktree, worktree.state == .active else { return "" }
        return await GitRepository(directory: worktree.path).diffAll(against: worktree.baseCommit ?? "HEAD")
    }

    /// Commits the step's changes on its branch and merges them into the project's current branch.
    func mergeWorktree(_ taskID: UUID) async {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }), let worktree = snapshot.tasks[index].worktree, worktree.state == .active else { return }
        let title = snapshot.tasks[index].title
        let commit = await GitRepository(directory: worktree.path).commitAll(message: "Workbench：\(title)")
        guard commit.status == 0 else { setWorktree(taskID, state: .conflict, note: "提交改动失败：" + commit.output.suffix(400)); return }
        let merge = await GitRepository(directory: worktree.repository).merge(branch: worktree.branch, message: "合并 Workbench 步骤：\(title)")
        if merge.status == 0 {
            _ = await GitRepository(directory: worktree.repository).removeWorktree(path: worktree.path)
            _ = await GitRepository(directory: worktree.repository).deleteBranch(worktree.branch)
            setWorktree(taskID, state: .merged, note: "已合并到项目当前分支。")
        } else {
            setWorktree(taskID, state: .conflict, note: "合并时有冲突，冲突留在项目文件夹中。请在终端里解决冲突并提交。\n" + merge.output.suffix(600))
        }
    }

    func discardWorktree(_ taskID: UUID) async {
        guard let worktree = snapshot.tasks.first(where: { $0.id == taskID })?.worktree, worktree.state == .active || worktree.state == .conflict else { return }
        _ = await GitRepository(directory: worktree.repository).removeWorktree(path: worktree.path)
        _ = await GitRepository(directory: worktree.repository).deleteBranch(worktree.branch)
        setWorktree(taskID, state: .discarded, note: "已放弃这个步骤的改动。")
    }

    private func setWorktree(_ taskID: UUID, state: WorktreeInfo.State, note: String) {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        change { snapshot in snapshot.tasks[index].worktree?.state = state; snapshot.tasks[index].worktree?.note = note; snapshot.tasks[index].log += "\n[system] \(note)\n" }
    }

    // MARK: MD-13 variants, MD-15 export

    /// Picks which variant results go on to later steps; only while the step waits for acceptance.
    func selectVariant(_ artifactID: UUID, selected: Bool) {
        guard let index = snapshot.artifacts.firstIndex(where: { $0.id == artifactID }),
              let task = snapshot.tasks.first(where: { $0.id == snapshot.artifacts[index].taskID }), task.status == .review, (task.generation?.variants ?? 1) > 1 else { return }
        change { $0.artifacts[index].accepted = selected }
    }

    /// Copies a finished step's accepted files into "<project>/Workbench 导出/<step>". Never overwrites.
    @discardableResult func exportOutputs(_ taskID: UUID) -> URL? {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID }), let project = project(task.projectID),
              let run = runs(for: taskID).first(where: { $0.status == .completed }) else { errorMessage = "只能导出已验收的结果。"; return nil }
        let files = artifacts(for: run.id).filter(\.accepted).compactMap { try? archive.url(for: $0) }
        guard !files.isEmpty else { errorMessage = "这一步没有已验收的文件。"; return nil }
        let safeTitle = task.title.replacingOccurrences(of: "[/:\\\\]", with: "_", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let folder = URL(fileURLWithPath: project.directory).appendingPathComponent("Workbench 导出").appendingPathComponent(safeTitle.isEmpty ? taskID.uuidString : safeTitle)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files {
                var target = folder.appendingPathComponent(file.lastPathComponent), counter = 1
                while FileManager.default.fileExists(atPath: target.path) {
                    target = folder.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(counter)").appendingPathExtension(file.pathExtension); counter += 1
                }
                try FileManager.default.copyItem(at: file, to: target)
            }
            return folder
        } catch { errorMessage = "导出失败：\(error.localizedDescription)"; return nil }
    }
}
