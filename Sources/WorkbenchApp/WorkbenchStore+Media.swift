import AVFoundation
import Foundation
import ImageIO

extension WorkbenchStore {
    /// Owner of generation jobs the user starts by hand from a template.
    static let manualOwnerID = UUID(uuidString: "00000000-0000-4000-8000-00000000AA01")!

    func ownerName(_ task: WorkTask) -> String {
        if task.employeeID == Self.manualOwnerID { return "手动生成" }
        let name = employee(task.employeeID)?.name ?? "未知员工"
        return task.generation != nil || task.command != nil ? name + " 指挥" : name
    }
    var commandTools: [ToolConfig] { snapshot.tools.current.filter { $0.isCLI && $0.commandStep == true && $0.isEnabled } }
    var enabledServers: [ComfyServer] { snapshot.servers.current.filter(\.enabled) }

    // MARK: Servers and templates

    @discardableResult func saveServer(_ server: ComfyServer, token: String?) -> Bool {
        let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isDeleted, snapshot.servers.first(where: { $0.id == server.id })?.isDeleted != true, !name.isEmpty else { errorMessage = "服务器已删除，或名称为空。"; return false }
        do {
            _ = try ComfyClient(connection: server.connection())
            if let ssh = server.ssh { _ = try ssh.arguments() }
            guard server.jobLimit >= 1, server.jobLimit <= 8, server.maximumUploadBytes > 0, (server.hourlyPrice ?? 0) >= 0 else { throw RemoteError.invalidConfiguration }
            if let token, !token.isEmpty { try CredentialVault().save(token, toolID: server.id) }
            if server.requiresToken, (try CredentialVault().read(toolID: server.id))?.isEmpty ?? true { errorMessage = "这台服务器需要 API 凭证，请填写。"; return false }
        } catch { errorMessage = error.localizedDescription; return false }
        var saved = server; saved.name = name
        let changed = change { snapshot in
            if let index = snapshot.servers.firstIndex(where: { $0.id == saved.id }) { snapshot.servers[index] = saved } else { snapshot.servers.append(saved) }
        }
        if changed { serverHealth.removeValue(forKey: server.id) }
        return changed
    }

    @discardableResult func saveTemplate(_ template: WorkflowTemplate) -> Bool {
        var saved = template
        saved.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.versionHash = WorkflowTemplate.hash(template.workflow)
        guard !saved.isDeleted, snapshot.templates.first(where: { $0.id == saved.id })?.isDeleted != true, !saved.name.isEmpty else { errorMessage = "模板已删除，或名称为空。"; return false }
        do { try saved.validateMapping() } catch { errorMessage = error.localizedDescription; return false }
        return change { snapshot in
            if let index = snapshot.templates.firstIndex(where: { $0.id == saved.id }) { snapshot.templates[index] = saved } else { snapshot.templates.append(saved) }
        }
    }

    func serverClient(_ server: ComfyServer, workflow: Data = Data("{}".utf8), name: String = "") throws -> ComfyClient {
        let token = server.requiresToken ? try CredentialVault().read(toolID: server.id) : nil
        if server.requiresToken && (token?.isEmpty ?? true) { throw MediaError.serverUnavailable("缺少 API 凭证") }
        return try ComfyClient(connection: server.connection(workflow: workflow, name: name), token: token)
    }

    /// MD-02: version, GPU, VRAM, queue and single-job cancel support. Runs on demand.
    func checkServer(_ id: UUID) {
        guard let server = snapshot.server(id), !server.isDeleted, !probingTools.contains(id) else { return }
        probingTools.insert(id)
        Task {
            defer { probingTools.remove(id) }
            do { serverHealth[id] = try await serverClient(server).health() }
            catch { serverHealth[id] = ServerHealth(error: error.localizedDescription) }
        }
    }

    /// Typical seconds and cost for one job, or nil when unknown (MD-17).
    func estimate(templateID: UUID?, serverID: UUID?) -> (seconds: Double?, cost: Double?) {
        guard let template = snapshot.template(templateID), !template.isDeleted, let server = snapshot.server(serverID) else { return (nil, nil) }
        let seconds = template.estimate(on: server.id, history: snapshot.runs)
        return (seconds, seconds.flatMap { server.estimatedCost(seconds: $0) })
    }

    // MARK: Manual runs (MD-09)

    /// Queues a generation job the user filled in by hand. Seeds that say "random" become numbers at submission.
    @discardableResult func submitGeneration(templateID: UUID, serverID: UUID, projectID: UUID?, title: String, values: [String: String], files: [String: String], variants: Int = 1) -> UUID? {
        guard let template = snapshot.template(templateID), !template.isDeleted, let server = snapshot.server(serverID), server.enabled else { errorMessage = "请选择可用的模板和服务器。"; return nil }
        guard !isArchived(projectID: projectID) else { errorMessage = Self.archivedProjectMessage; return nil }
        var parsed: [String: JSONValue] = [:]
        do {
            for (name, text) in values {
                guard let parameter = template.parameter(name), !parameter.type.isFile else { throw MediaError.unknownParameter(name) }
                parsed[name] = try parameter.parse(text)
            }
            for (name, path) in files {
                guard template.parameter(name)?.type.isFile == true, FileManager.default.isReadableFile(atPath: path) else { throw MediaError.missingInput(name) }
            }
            var check = parsed; for (name, _) in files { check[name] = .string("upload") }
            _ = try template.normalize(check) { 0 }
        } catch { errorMessage = error.localizedDescription; return nil }
        let directory = project(projectID)?.directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        var task = WorkTask(title: title.isEmpty ? template.name : title, employeeID: Self.manualOwnerID, input: "手动运行模板「\(template.name)」@ \(server.name)", workingDirectory: directory, acceptance: "检查生成结果")
        task.projectID = projectID
        task.generation = GenerationSpec(templateID: template.id, serverID: server.id, values: parsed, inputs: files, versionHash: template.versionHash)
        task.generation?.variantCount = variants > 1 ? min(8, variants) : nil
        task.status = .queued
        guard change({ $0.tasks.insert(task, at: 0) }) else { return nil }
        schedulePending()
        return task.id
    }

    /// Runs a finished generation again with the values it was sent, so a recorded seed is reused (A50).
    @discardableResult func rerunGeneration(_ taskID: UUID) -> UUID? {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID && !$0.isDeleted }), let spec = task.generation,
              let template = snapshot.template(spec.templateID), !template.isDeleted, snapshot.server(spec.serverID)?.enabled == true else { return nil }
        var values = spec.submittedValues ?? spec.values
        for parameter in template.parameters where parameter.type.isFile { values.removeValue(forKey: parameter.name) }
        var copy = WorkTask(title: task.title + "（相同参数）", employeeID: task.employeeID, input: task.input, workingDirectory: task.workingDirectory, acceptance: task.acceptance)
        copy.projectID = task.projectID; copy.status = .queued
        copy.generation = GenerationSpec(templateID: template.id, serverID: spec.serverID, values: values, inputs: spec.inputs, versionHash: template.versionHash)
        guard !isArchived(projectID: copy.projectID), change({ $0.tasks.insert(copy, at: 0) }) else { return nil }
        schedulePending()
        return copy.id
    }

    func queueMediaTask(_ index: Int, feedback: String) {
        let task = snapshot.tasks[index]
        guard ![.running, .queued].contains(task.status) else { return }
        guard !isArchived(projectID: task.projectID) else { errorMessage = Self.archivedProjectMessage; return }
        if let spec = task.generation {
            guard snapshot.template(spec.templateID)?.isDeleted == false, snapshot.server(spec.serverID)?.enabled == true else { errorMessage = "模板或服务器已不可用。"; return }
            if runs(for: task.id).contains(where: { $0.status == .interrupted && $0.remotePromptID != nil }) { errorMessage = "远程执行状态尚未确认，请先查询已有执行，避免重复提交。"; return }
        }
        if let command = task.command {
            guard let tool = tool(command.toolID), tool.isCLI, tool.commandStep == true else { errorMessage = "命令步骤使用的 CLI 已不可用。"; return }
            if !tool.executableAvailable { missingCLIToolID = tool.id; return }
        }
        if change({ $0.tasks[index].status = .queued; $0.tasks[index].pendingFeedback = feedback }) { schedulePending() }
    }

    /// Job limit per server, and the plan's budget cap (MD-18): before a job would go over, stop submitting and pause the plan.
    func canStartGeneration(_ task: WorkTask) -> Bool {
        guard let spec = task.generation, let server = snapshot.server(spec.serverID) else { return false }
        let onServer = activeRuns.values.filter { runID in snapshot.runs.first { $0.id == runID }?.generation?.serverID == server.id }.count
        guard onServer < server.jobLimit else { return false }
        guard let planID = task.planID, let plan = snapshot.plans.first(where: { $0.id == planID }) else { return true }
        let single = estimate(templateID: spec.templateID, serverID: spec.serverID)
        let seconds = single.seconds.map { $0 * Double(spec.variants) }, cost = single.cost.map { $0 * Double(spec.variants) }
        // Jobs of this plan that are still running count with their estimates.
        let running = plan.taskIDs.filter { activeRuns[$0] != nil }.compactMap { id in snapshot.tasks.first { $0.id == id }?.generation }.map { estimate(templateID: $0.templateID, serverID: $0.serverID) }
        let spentSeconds = (plan.spentSeconds ?? 0) + running.compactMap(\.seconds).reduce(0, +)
        let spentCost = (plan.spentCost ?? 0) + running.compactMap(\.cost).reduce(0, +)
        var reason: String?
        if let minutes = plan.budgetMinutes, (spentSeconds + (seconds ?? 0)) / 60 > minutes || spentSeconds / 60 >= minutes {
            reason = String(format: "GPU 时间预算 %.0f 分钟：已用和运行中约 %.1f 分钟，下一个任务预计 %@。", minutes, spentSeconds / 60, seconds.map { String(format: "%.1f 分钟", $0 / 60) } ?? "未知")
        } else if let budget = plan.budgetCost, spentCost + (cost ?? 0) > budget || spentCost >= budget {
            reason = String(format: "费用预算 %.2f：已用约 %.2f，下一个任务预计 %@。", budget, spentCost, cost.map { String(format: "%.2f", $0) } ?? "未知")
        }
        guard let reason else { return true }
        change { snapshot in
            if let p = snapshot.plans.firstIndex(where: { $0.id == planID }) { snapshot.plans[p].paused = true; snapshot.plans[p].pauseReason = "已暂停：" + reason + "不再提交新任务，正在运行的任务不受影响。调整预算后可以继续。" }
        }
        return false
    }

    func updateBudget(_ planID: UUID, minutes: Double?, cost: Double?) {
        guard let index = snapshot.plans.firstIndex(where: { $0.id == planID }) else { return }
        change { snapshot in
            snapshot.plans[index].budgetMinutes = minutes.flatMap { $0 > 0 ? $0 : nil }; snapshot.plans[index].budgetCost = cost.flatMap { $0 > 0 ? $0 : nil }
            snapshot.plans[index].pauseReason = nil
        }
    }

    /// Accepted output files of a task's latest completed run, optionally only of one media kind.
    func acceptedFiles(of taskID: UUID, kind: MediaKind? = nil) -> [URL] {
        guard let run = runs(for: taskID).first(where: { $0.status == .completed }) else { return [] }
        return artifacts(for: run.id).filter { $0.accepted && (kind == nil || MediaKind.of(fileExtension: $0.fileType) == kind) }.compactMap { try? archive.url(for: $0) }
    }

    func expandCommand(_ command: CommandSpec, outputDirectory: String) throws -> [String] {
        var result: [String] = []
        for argument in command.arguments {
            if argument.hasPrefix("{input:"), argument.hasSuffix("}"), let id = UUID(uuidString: String(argument.dropFirst(7).dropLast())) {
                let files = acceptedFiles(of: id)
                guard !files.isEmpty else { throw MediaError.missingInput(argument) }
                result += files.map(\.path); continue
            }
            var text = argument.replacingOccurrences(of: "{output}", with: outputDirectory)
            while let range = text.range(of: "{input:"), let close = text[range.upperBound...].firstIndex(of: "}") {
                guard let id = UUID(uuidString: String(text[range.upperBound..<close])), let first = acceptedFiles(of: id).first else { throw MediaError.missingInput(String(text[range.lowerBound...close])) }
                text.replaceSubrange(range.lowerBound...close, with: first.path)
            }
            result.append(text)
        }
        return result
    }

    // MARK: Running a generation job (MD-08, MD-10)

    func startGeneration(_ id: UUID) {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == id && $0.status == .queued }), let spec = snapshot.tasks[index].generation,
              let template = snapshot.template(spec.templateID), !template.isDeleted, let server = snapshot.server(spec.serverID), server.enabled else { return }
        let task = snapshot.tasks[index]
        let owner = employee(task.employeeID) ?? Employee(id: Self.manualOwnerID, name: "手动生成", role: "", department: "", instructions: "", toolID: server.id)
        var tool = ToolConfig(name: "\(server.name) · \(template.name)", executable: "/usr/bin/true", arguments: [])
        tool.id = server.id; tool.adapter = .comfyUI; tool.timeoutSeconds = server.timeout
        tool.remote = server.connection(workflow: template.workflow, name: template.name)
        let runID = UUID()
        do {
            let directory = try archive.prepare(runID: runID, projectID: task.projectID)
            var run = TaskRun(id: runID, task: task, employee: owner, tool: tool, directory: directory, feedback: task.pendingFeedback ?? "")
            run.generation = spec; run.arguments = []
            let log = try RunLog(url: URL(fileURLWithPath: run.logPath))
            log.append("[system] 模板「\(template.name)」(\(template.versionHash)) @ \(server.name)\n[system] run \(runID)\n")
            let previous = snapshot
            snapshot.tasks[index].status = .running; snapshot.tasks[index].pendingFeedback = nil; snapshot.tasks[index].toolSnapshot = tool
            snapshot.tasks[index].log = log.drain(); snapshot.runs.append(run)
            guard save() else { snapshot = previous; try? log.close(); return }
            activeRuns[id] = runID
            Task {
                let refresher = Task { [weak self] in
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000); guard !Task.isCancelled else { break }; self?.appendTaskLog(log.drain(), to: id) }
                }
                var status: WorkStatus = .failed
                do {
                    let client = try serverClient(server)
                    var values = spec.values
                    for (name, source) in spec.inputs.sorted(by: { $0.key < $1.key }) {
                        let kind = template.parameter(name)?.type.mediaKind
                        let file: URL
                        if source.hasPrefix("task:"), let source = UUID(uuidString: String(source.dropFirst(5))) {
                            guard let found = acceptedFiles(of: source, kind: kind).first ?? acceptedFiles(of: source).first else { throw MediaError.missingInput(name) }
                            file = found
                        } else { file = URL(fileURLWithPath: source) }
                        log.append("[system] 上传 \(name)：\(file.lastPathComponent)\n")
                        values[name] = .string(try await client.upload(file, maximumBytes: server.maximumUploadBytes))
                    }
                    // MD-03: refuse before submitting when the server lacks a node the workflow uses.
                    if serverHealth[server.id]?.nodeClasses == nil, let health = try? await client.health() { serverHealth[server.id] = health }
                    let missing = template.missingNodes(on: serverHealth[server.id])
                    if !missing.isEmpty { throw MediaError.invalidTemplate("服务器「\(server.name)」缺少节点：\(missing.joined(separator: "、"))") }
                    // MD-13: each variant is its own server job; a fixed seed counts up, a random one is drawn per variant.
                    let count = spec.variants, seedName = template.parameters.first { $0.type == .seed }?.name
                    var collected: [RemoteArtifact] = []
                    status = .review
                    for variant in 0..<count {
                        var variantValues = values
                        if count > 1, let seedName {
                            if case .number(let base)? = values[seedName] { variantValues[seedName] = .number(base + Double(variant)) } else { variantValues[seedName] = .string("random") }
                        }
                        let normalized = try template.normalize(variantValues)
                        var submitted = run
                        if variant > 0 { submitted.id = UUID(); remoteAliases[submitted.id] = runID }
                        defer { if variant > 0 { remoteAliases.removeValue(forKey: submitted.id) } }
                        submitted.tool.remote = server.connection(workflow: try template.resolve(normalized), name: template.name)
                        submitted.generation?.submittedValues = normalized
                        if variant == 0 {
                            if let r = snapshot.runs.firstIndex(where: { $0.id == runID }) { snapshot.runs[r].tool = submitted.tool; snapshot.runs[r].generation?.submittedValues = normalized }
                            if let t = snapshot.tasks.firstIndex(where: { $0.id == id }) { snapshot.tasks[t].generation?.submittedValues = normalized; snapshot.tasks[t].toolSnapshot = submitted.tool }
                        }
                        log.append("[system] \(count > 1 ? "变体 \(variant + 1)/\(count) " : "")参数 " + normalized.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.display($0.value))" }.joined(separator: "，") + "\n")
                        // Each variant's files are tracked on their own, so equal file names are not mistaken for earlier downloads.
                        if variant > 0, let r = snapshot.runs.firstIndex(where: { $0.id == runID }) { snapshot.runs[r].remoteArtifacts = nil }
                        let result = try await executeRemote(run: submitted, log: log, submit: true)
                        log.append("[system] 远程执行 \(result.title)\n")
                        guard result == .review else { status = result; break }
                        try await downloadAll(runID: runID, log: log, prefix: count > 1 ? "v\(variant + 1)-" : "")
                        collected += snapshot.runs.first { $0.id == runID }?.remoteArtifacts ?? []
                    }
                    if count > 1, let r = snapshot.runs.firstIndex(where: { $0.id == runID }) { snapshot.runs[r].remoteArtifacts = collected }
                } catch {
                    if snapshot.runs.first(where: { $0.id == runID })?.remotePromptID != nil, !(error is MediaError) { status = .interrupted }
                    if case RemoteError.http(let code) = error, [400, 401, 403, 404, 405, 413, 422, 429].contains(code) { status = .failed }
                    log.append("[system] \(error.localizedDescription)\n")
                }
                refresher.cancel(); appendTaskLog(log.drain(), to: id); try? log.close()
                finishGeneration(id, runID: runID, status: status, server: server)
            }
        } catch {
            change { snapshot in snapshot.tasks[index].status = .failed; snapshot.tasks[index].log = "[system] \(error.localizedDescription)" }
        }
    }

    private static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return String(text.prefix(60))
        case .number(let number): return number.rounded() == number ? String(Int64(number)) : String(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: return "…"
        }
    }

    private func appendTaskLog(_ text: String, to id: UUID) {
        guard !text.isEmpty, let i = snapshot.tasks.firstIndex(where: { $0.id == id }) else { return }
        snapshot.tasks[i].log = RunLog.boundedTail(snapshot.tasks[i].log + text)
    }

    /// Generation results are downloaded straight into the run's archive, each size-checked first.
    func downloadAll(runID: UUID, log: RunLog, prefix: String = "") async throws {
        guard let run = snapshot.runs.first(where: { $0.id == runID }) else { return }
        let client = try remoteClient(run.tool)
        for file in run.remoteArtifacts ?? [] where file.localArtifactID == nil {
            let url = try await client.download(file)
            defer { try? FileManager.default.removeItem(at: url) }
            let before = Set(snapshot.artifacts.map(\.id))
            guard let current = snapshot.runs.first(where: { $0.id == runID }) else { return }
            try archive.importFile(url, into: current, named: prefix + file.filename); try refreshArtifacts(runID: runID)
            if let artifact = snapshot.artifacts.first(where: { !before.contains($0.id) }), let r = snapshot.runs.firstIndex(where: { $0.id == runID }),
               let f = snapshot.runs[r].remoteArtifacts?.firstIndex(where: { $0.id == file.id }) { snapshot.runs[r].remoteArtifacts?[f].localArtifactID = artifact.id }
            log.append("[system] 已下载 \(file.filename)\n")
        }
    }

    private func finishGeneration(_ id: UUID, runID: UUID, status: WorkStatus, server: ComfyServer) {
        activeRuns.removeValue(forKey: id)
        var duration = 0.0
        if let r = snapshot.runs.firstIndex(where: { $0.id == runID }) {
            snapshot.runs[r].status = status; snapshot.runs[r].endedAt = Date(); snapshot.runs[r].exitCode = status == .review ? 0 : nil
            duration = Date().timeIntervalSince(snapshot.runs[r].startedAt)
            try? refreshArtifacts(runID: runID)
        }
        if let t = snapshot.tasks.firstIndex(where: { $0.id == id }) {
            snapshot.tasks[t].status = status; snapshot.tasks[t].exitCode = status == .review ? 0 : nil
            if let planID = snapshot.tasks[t].planID, let p = snapshot.plans.firstIndex(where: { $0.id == planID }) {
                snapshot.plans[p].spentSeconds = (snapshot.plans[p].spentSeconds ?? 0) + duration
                snapshot.plans[p].spentCost = (snapshot.plans[p].spentCost ?? 0) + (server.estimatedCost(seconds: duration) ?? 0)
                if [.failed, .cancelled, .timedOut, .interrupted].contains(status) { snapshot.plans[p].paused = true }
            }
        }
        remoteSessionsCleanup(runID)
        if save() { coordinateFinishedTask(id); schedulePending(); scheduleTurns() }
    }

    // MARK: Director review (MD-19)

    /// Gives the director only what it can actually check: images as files, video as keyframes plus metadata,
    /// audio as metadata only. The review runs read-only inside an evidence folder.
    func enqueueMediaReview(task: WorkTask, run: TaskRun, plan: CollaborationPlan) {
        guard let directorID = plan.leadID, let director = employee(directorID), canPlanOrReview(director), let spec = task.generation, let template = snapshot.template(spec.templateID) else {
            pausePlan(plan.id, paused: true); return
        }
        let files = artifacts(for: run.id).compactMap { try? archive.url(for: $0) }
        let folder = archive.root.appendingPathComponent("evidence/\(run.id.uuidString)", isDirectory: true)
        Task {
            let evidence = await MediaEvidence.prepare(files: files, in: folder)
            guard !snapshot.tasks.contains(where: { $0.reviewSourceRunID == run.id }) else { return }
            let tunable = template.parameters.filter { !$0.type.isFile }.map { "\($0.name)（\($0.type.title)\($0.description.isEmpty ? "" : "，" + $0.description)）" }.joined(separator: "；")
            let sent = (spec.submittedValues ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.display($0.value))" }.joined(separator: "，")
            let prompt = """
            你是这次制作的导演，现在审核一个生成步骤的结果。只根据当前文件夹里的文件和下面的说明判断，不要修改文件、不要运行命令。
            步骤：\(task.title)
            要求：\(task.input)
            验收标准：\(task.acceptance)
            使用的模板：\(template.name)；这次的参数：\(sent)

            可以检查的证据：
            \(evidence.description)

            返回 JSON：decision 为 pass、rework 或 blocked；notes 写明你实际看到了哪些证据、依据是什么；如果 rework，在 parameters 中给出要修改的参数（name/value，只能用这些参数：\(tunable)），没有要改的参数就返回空数组。证据不足以判断时返回 blocked，不要声称看过或听过证据之外的内容。
            """
            var review = WorkTask(title: "导演审核：" + task.title, employeeID: directorID, input: prompt, workingDirectory: folder.path, acceptance: "有证据的结构化审核结论")
            review.projectID = task.projectID; review.planID = plan.id; review.purpose = .review
            review.reviewSourceTaskID = task.id; review.reviewSourceRunID = run.id
            if addTask(review) { self.run(review.id) }
        }
    }

    /// A director's rework may change parameters (for example a new seed); unknown or invalid values are ignored and noted.
    func applyReworkParameters(_ taskID: UUID, _ parameters: [NamedValue]) {
        guard !parameters.isEmpty, let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }), let spec = snapshot.tasks[index].generation,
              let template = snapshot.template(spec.templateID) else { return }
        var values = spec.values, ignored: [String] = []
        for item in parameters {
            guard let parameter = template.parameter(item.name), !parameter.type.isFile, let value = try? parameter.normalize(parameter.parse(item.value), seed: { 0 }) else { ignored.append(item.name); continue }
            values[item.name] = (try? parameter.parse(item.value)) ?? value
        }
        change { snapshot in
            snapshot.tasks[index].generation?.values = values
            if !ignored.isEmpty { snapshot.tasks[index].log += "\n[system] 审核建议中这些参数无效，已忽略：\(ignored.joined(separator: "、"))\n" }
        }
    }
}

/// Builds the evidence folder for a media review.
enum MediaEvidence {
    struct Result { var description: String }

    static func prepare(files: [URL], in folder: URL) async -> Result {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines: [String] = []
        for (index, file) in files.enumerated() {
            let kind = MediaKind.of(fileExtension: file.pathExtension)
            switch kind {
            case .image:
                let name = "image-\(index + 1).\(file.pathExtension.lowercased())"
                try? FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(name))
                lines.append("· 图片 \(name)（原文件 \(file.lastPathComponent)），可以直接打开查看。")
            case .video:
                let asset = AVURLAsset(url: file)
                let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                var size = CGSize.zero, fps: Float = 0
                if let track = try? await asset.loadTracks(withMediaType: .video).first {
                    size = (try? await track.load(.naturalSize)) ?? .zero; fps = (try? await track.load(.nominalFrameRate)) ?? 0
                }
                let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                var frames: [String] = []
                for (n, fraction) in [0.1, 0.35, 0.6, 0.85].enumerated() where seconds > 0 {
                    let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
                    guard let image = try? await generator.image(at: time).image else { continue }
                    let name = "video-\(index + 1)-keyframe-\(n + 1).png"
                    if let data = NSBitmapImageRepPNG.data(image) { try? data.write(to: folder.appendingPathComponent(name)); frames.append(name) }
                }
                lines.append(String(format: "· 视频 %@：时长 %.1f 秒，%d×%d，%.0f fps。没有直接给你视频本身；关键帧：%@。只能据此判断画面，动作连贯性需注明无法确认。", file.lastPathComponent, seconds, Int(size.width), Int(size.height), fps, frames.isEmpty ? "无法提取" : frames.joined(separator: "、")))
            case .audio:
                let asset = AVURLAsset(url: file)
                let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
                var details = ""
                if let track = try? await asset.loadTracks(withMediaType: .audio).first, let descriptions = try? await track.load(.formatDescriptions), let first = descriptions.first,
                   let basic = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
                    details = String(format: "，%.0f Hz，%d 声道", basic.mSampleRate, basic.mChannelsPerFrame)
                }
                lines.append(String(format: "· 音频 %@：时长 %.1f 秒%@。只有元数据，你无法听到声音，不要声称听过。", file.lastPathComponent, seconds, details))
            case .other:
                lines.append("· 文件 \(file.lastPathComponent)：类型无法检查。")
            }
        }
        if lines.isEmpty { lines.append("· 没有下载到任何结果文件。") }
        let text = lines.joined(separator: "\n")
        try? Data(text.utf8).write(to: folder.appendingPathComponent("evidence.txt"))
        return Result(description: text)
    }
}

enum NSBitmapImageRepPNG {
    static func data(_ image: CGImage) -> Data? {
        guard let destinationData = CFDataCreateMutable(nil, 0), let destination = CGImageDestinationCreateWithData(destinationData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? destinationData as Data : nil
    }
}
