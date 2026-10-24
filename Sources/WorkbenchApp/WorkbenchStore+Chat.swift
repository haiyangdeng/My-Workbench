import Foundation

/// What a running turn or step has said so far.
/// The templates and servers a director may use (MD-16).
struct DirectorScope: Equatable {
    var templateIDs: Set<UUID>
    var serverIDs: Set<UUID>
    /// Current, enabled entries in a stable order.
    @MainActor func resolved(in store: WorkbenchStore) -> (templates: [WorkflowTemplate], servers: [ComfyServer]) {
        (store.snapshot.templates.current.filter { templateIDs.contains($0.id) }, store.enabledServers.filter { serverIDs.contains($0.id) })
    }
}

struct LiveTurn: Equatable {
    var text = ""
    var activities: [CLIActivity] = []
}

/// Collects CLI events off the main thread; the main actor polls it a few times a second.
final class LiveTurnBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas = ""
    private var messages: [String] = []
    private var activities: [CLIActivity] = []
    private var changed = false
    func handle(_ event: CLIEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .textDelta(let text):
            deltas += text
            if deltas.utf8.count > 512 * 1024 { deltas = "…" + String(deltas.suffix(256 * 1024)) }
        case .message(let text):
            messages.append(text); if messages.count > 200 { messages.removeFirst() }
        case .activity(let activity):
            activities.append(activity); if activities.count > 300 { activities.removeFirst() }
        case .session: return
        }
        changed = true
    }
    func take() -> LiveTurn? {
        lock.lock(); defer { lock.unlock() }
        guard changed else { return nil }
        changed = false
        return LiveTurn(text: deltas.isEmpty ? messages.joined(separator: "\n\n") : deltas, activities: activities)
    }
}

final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); value = String((value + text).suffix(6000)); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

extension WorkbenchStore {
    static let chatTurnLimit = 4

    func conversations(in projectID: UUID?) -> [Conversation] {
        snapshot.conversations.current.filter { $0.projectID == projectID }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func conversation(_ id: UUID?) -> Conversation? { id.flatMap { id in snapshot.conversations.first { $0.id == id } } }
    func message(_ id: UUID?) -> ChatMessage? { id.flatMap { id in snapshot.messages.first { $0.id == id } } }
    func session(for turn: ChatMessage) -> AgentSession? {
        guard let agentID = turn.agentID, let agent = employee(agentID) else { return nil }
        return snapshot.usableSession(conversationID: turn.conversationID, agentID: agentID, toolID: agent.toolID)
    }

    /// The access a turn runs with: the request capped by the agent's maximum. Parallel, planning and wrap-up turns only read.
    func turnAccess(requested: AccessLevel?, agent: Employee, mode: ChatMode, kind: TurnKind) -> AccessLevel {
        var level = min(requested ?? .readOnly, agent.maxAccess ?? .readOnly)
        if mode == .parallel || kind != .reply { level = .readOnly }
        return level
    }

    // MARK: Folder write lock (TM-06)

    static func folderKey(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    /// True while an Edit-level run (task step or chat turn) works in this folder, a parent of it, or a subfolder.
    func editLocked(_ directory: String) -> Bool {
        let key = Self.folderKey(directory)
        let active = Set(activeRuns.values).union(activeTurns.values)
        return snapshot.runs.contains { run in
            guard active.contains(run.id), run.accessLevel == .edit else { return false }
            let other = Self.folderKey(run.workingDirectory)
            return other == key || other.hasPrefix(key + "/") || key.hasPrefix(other + "/")
        }
    }

    // MARK: Sending

    /// Adds the user's message and one queued turn per agent (or a planning turn for the lead in team mode).
    /// Returns the conversation ID, or nil with errorMessage set. Nothing is sent if any agent cannot run.
    @discardableResult
    func sendMessage(_ text: String, attachments: [String] = [], projectID: UUID, conversationID: UUID?, agentIDs: [UUID], mode: ChatMode, access: AccessLevel, directorScope: DirectorScope? = nil) -> UUID? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storageAvailable, !body.isEmpty || !attachments.isEmpty else { return nil }
        guard let project = project(projectID) else { errorMessage = "请先选择一个项目。"; return nil }
        guard !project.isArchived else { errorMessage = Self.archivedProjectMessage; return nil }
        var agents: [Employee] = []
        for id in agentIDs where !agents.contains(where: { $0.id == id }) {
            guard let agent = employee(id), agent.enabled ?? true else { errorMessage = "所选员工已停用或不存在。"; return nil }
            agents.append(agent)
        }
        guard !agents.isEmpty else { errorMessage = "请先选择至少一位 AI 员工。"; return nil }
        let effectiveMode: ChatMode = mode == .director ? .director : (agents.count == 1 ? .single : (mode == .single ? .parallel : mode))
        if effectiveMode == .director {
            guard agents.count == 1 else { errorMessage = "导演模式只选一位员工担任导演。"; return nil }
            guard !snapshot.templates.current.isEmpty, !enabledServers.isEmpty else { errorMessage = "导演模式需要至少一个工作流模板和一台可用的服务器。请先在“工具连接”中添加。"; return nil }
            let scope = (directorScope ?? defaultDirectorScope(projectID: projectID)).resolved(in: self)
            guard !scope.templates.isEmpty, !scope.servers.isEmpty else { errorMessage = "导演可用的范围里至少要有一个模板和一台已启用的服务器。"; return nil }
        }
        for agent in agents {
            guard let tool = tool(agent.toolID), tool.isEnabled, tool.isCLI else { errorMessage = "「\(agent.name)」没有绑定可用的 CLI。"; return nil }
            guard tool.executableAvailable else { missingCLIToolID = tool.id; return nil }
            let kind: TurnKind = effectiveMode == .director ? .production : (effectiveMode == .team && agent.id == agents[0].id ? .planning : .reply)
            let level = turnAccess(requested: access, agent: agent, mode: effectiveMode, kind: kind)
            guard tool.supports(level) else { errorMessage = "「\(agent.name)」：" + (CLIError.accessUnsupported(level).errorDescription ?? ""); return nil }
        }
        if (effectiveMode == .team || effectiveMode == .director) && !canPlanOrReview(agents[0]) { errorMessage = "「\(agents[0].name)」的 CLI 需要能以只读方式运行，才能拆解计划。"; return nil }
        if let conversationID, (conversation(conversationID)?.projectID != projectID || conversation(conversationID)?.isDeleted == true) { errorMessage = "这个对话不属于所选项目。"; return nil }
        let now = Date()
        let conversation = conversation(conversationID) ?? Conversation(projectID: projectID, title: Conversation.title(from: body.isEmpty ? attachments[0] : body), createdAt: now)
        var user = ChatMessage(conversationID: conversation.id, role: .user, text: body, createdAt: now)
        user.attachments = attachments.isEmpty ? nil : attachments
        user.targetIDs = agents.map(\.id); user.mode = effectiveMode; user.access = access
        user.leadID = effectiveMode == .team || effectiveMode == .director ? agents[0].id : nil
        if effectiveMode == .director {
            // The scope used is recorded on the message, so a later look at the plan shows what the director could choose from.
            let scope = (directorScope ?? defaultDirectorScope(projectID: projectID)).resolved(in: self)
            user.directorTemplateIDs = scope.templates.map(\.id); user.directorServerIDs = scope.servers.map(\.id)
        }
        let turnAgents = effectiveMode == .team ? [agents[0]] : agents
        let turns = turnAgents.enumerated().map { index, agent -> ChatMessage in
            var turn = ChatMessage(conversationID: conversation.id, role: .agent, text: "", createdAt: now.addingTimeInterval(Double(index + 1) / 1000))
            turn.agentID = agent.id; turn.replyToID = user.id; turn.state = .queued
            turn.kind = effectiveMode == .team ? .planning : (effectiveMode == .director ? .production : .reply)
            return turn
        }
        let isNew = !snapshot.conversations.contains { $0.id == conversation.id }
        guard change({ snapshot in
            if isNew { snapshot.conversations.append(conversation) }
            if let index = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) { snapshot.conversations[index].updatedAt = now }
            snapshot.messages.append(user); snapshot.messages += turns
        }) else { return nil }
        scheduleTurns()
        return conversation.id
    }

    func renameConversation(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = snapshot.conversations.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { return }
        change { $0.conversations[index].title = String(trimmed.prefix(80)) }
    }

    // MARK: Scheduling

    /// Starts queued turns in order. One turn per agent per conversation at a time (its session is in use),
    /// at most `chatTurnLimit` turns overall, and Edit turns wait for the folder's write lock.
    func scheduleTurns() {
        guard storageAvailable else { return }
        var busy = Set(snapshot.messages.filter { $0.state == .running }.compactMap { turn in turn.agentID.map { "\(turn.conversationID)/\($0)" } })
        let queued = snapshot.messages.filter { $0.role == .agent && $0.state == .queued }.sorted { $0.createdAt < $1.createdAt }
        for turn in queued where activeTurns.count < Self.chatTurnLimit {
            guard let agentID = turn.agentID else { continue }
            let key = "\(turn.conversationID)/\(agentID)"
            guard !busy.contains(key) else { continue }
            busy.insert(key)
            guard let user = message(turn.replyToID), let agent = employee(agentID), let project = conversation(turn.conversationID).flatMap({ project($0.projectID) }) else {
                failTurn(turn.id, "原消息、员工或项目已不存在。"); continue
            }
            let level = turnAccess(requested: user.access, agent: agent, mode: user.mode ?? .single, kind: turn.turnKind)
            if level == .edit && editLocked(project.directory) { continue }
            if let tool = tool(agent.toolID), let limit = tool.concurrencyLimit, activeRunCount(toolID: tool.id) >= limit { continue }
            startTurn(turn.id)
        }
    }

    private func failTurn(_ id: UUID, _ reason: String) {
        guard let index = snapshot.messages.firstIndex(where: { $0.id == id }) else { return }
        change { snapshot in
            snapshot.messages[index].state = .failed; snapshot.messages[index].detail = reason; snapshot.messages[index].endedAt = Date()
        }
    }

    private func composePrompt(user: ChatMessage, turn: ChatMessage, agent: Employee, freshSession: Bool) -> String {
        var parts: [String] = []
        if freshSession {
            let context = snapshot.transcriptContext(conversationID: turn.conversationID, before: user.createdAt)
            if !context.isEmpty { parts.append("以下是这个对话之前的内容，供你参考：\n\n" + context + "\n\n——") }
        }
        if turn.turnKind == .planning, let conversation = conversation(turn.conversationID), let project = project(conversation.projectID) {
            let roster = (user.targetIDs ?? []).compactMap(employee).map { member in
                let area = workspaces.first { $0.id == member.workspaceID }?.name ?? member.department
                return "id=\(member.id.uuidString)；姓名=\(member.name)；职位=\(member.role)；工作区=\(area)；职责=\(member.instructions)；最高权限=\((member.maxAccess ?? .readOnly).rawValue)"
            }.joined(separator: "\n")
            parts.append("""
            你是这次协作的负责人。把下面的用户请求拆解为1至20个可验收的步骤，分配给员工表中的员工（你自己也可以承担步骤）。只做规划：不要执行步骤、不要修改文件。
            每个步骤给出独立字符串 id、title、input、acceptance、dependencies，以及 access（readOnly 或 edit，不能超过该员工的最高权限）。依赖必须来自本计划且不能形成环。前序步骤验收后的产物会自动提供给依赖它的步骤。只返回符合 JSON Schema 的计划。

            项目：\(project.name)
            项目目标：\(project.goal)
            用户请求：\(user.text)

            员工表：
            \(roster)
            """)
        } else if turn.turnKind == .production, let conversation = conversation(turn.conversationID), let project = project(conversation.projectID) {
            parts.append(directorPrompt(user: user, director: agent, project: project))
        } else {
            parts.append(user.text)
        }
        if turn.turnKind != .production, let attachments = user.attachments, !attachments.isEmpty { parts.append("参考文件：\n" + attachments.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    private func startTurn(_ id: UUID) {
        guard let index = snapshot.messages.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        let turn = snapshot.messages[index]
        guard let agentID = turn.agentID, let agent = employee(agentID), agent.enabled ?? true, let tool = tool(agent.toolID), tool.isEnabled, tool.isCLI,
              let user = message(turn.replyToID), let conversation = conversation(turn.conversationID), !conversation.isDeleted, let project = project(conversation.projectID), !project.isArchived else {
            failTurn(id, "员工、CLI 或项目已不可用。"); return
        }
        guard tool.executableAvailable else { failTurn(id, "CLI「\(tool.name)」的可执行文件不存在：\(tool.executable)"); missingCLIToolID = tool.id; return }
        let level = turnAccess(requested: user.access, agent: agent, mode: user.mode ?? .single, kind: turn.turnKind)
        guard tool.supports(level) else { failTurn(id, CLIError.accessUnsupported(level).errorDescription ?? ""); return }
        let session = snapshot.usableSession(conversationID: conversation.id, agentID: agent.id, toolID: tool.id)
        let resume = session != nil && tool.supportsResume
        let sessionID = resume ? session?.nativeID : (tool.assignsSessionID ? UUID().uuidString.lowercased() : nil)
        let prompt = turn.prompt ?? composePrompt(user: user, turn: turn, agent: agent, freshSession: !resume)
        let instructions = resume && !tool.usesInstructionsPlaceholder ? "" : agent.instructions
        let runID = UUID()
        do {
            let directory = try archive.prepare(runID: runID, projectID: project.id)
            var shadow = WorkTask(id: turn.id, title: conversation.title, employeeID: agent.id, input: prompt, workingDirectory: project.directory, acceptance: "")
            shadow.projectID = project.id
            var run = TaskRun(id: runID, task: shadow, employee: agent, tool: tool, directory: directory)
            let model = agent.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            run.conversationID = conversation.id; run.accessLevel = level; run.sessionID = sessionID
            run.model = (model?.isEmpty ?? true) ? nil : model
            var schemaText: String?, schemaURL: URL?
            if turn.turnKind == .planning || turn.turnKind == .production {
                let schema = try turn.turnKind == .planning ? CollaborationSchema.plan(employeeIDs: user.targetIDs ?? []) : productionSchema(director: agent, user: user)
                schemaURL = directory.appendingPathComponent("response-schema.json")
                try schema.write(to: schemaURL!, options: .atomic)
                schemaText = String(decoding: schema, as: UTF8.self)
            }
            run.arguments = try tool.invocation(CLIInvocation(prompt: prompt, instructions: instructions, outputDirectory: run.outputDirectory, workingDirectory: run.workingDirectory, model: run.model, access: level, schema: schemaText, schemaFile: schemaURL?.path, sessionID: sessionID, resume: resume))
            let log = try RunLog(url: URL(fileURLWithPath: run.logPath))
            log.append("[system] 对话「\(conversation.title)」· \(agent.name)\n[system] run \(runID)\n[system] 权限 \(tool.managesAccess ? level.title : "未由工作台管理") · \(resume ? "续接会话 " : "新会话 ")\(sessionID ?? "（由 CLI 生成）")\n")
            let previous = snapshot
            snapshot.messages[index].state = .running; snapshot.messages[index].runID = runID
            snapshot.messages[index].startedAt = Date(); snapshot.messages[index].resumed = resume
            snapshot.runs.append(run)
            guard save() else { snapshot = previous; try? log.close(); return }
            activeTurns[id] = runID
            liveTurns[id] = LiveTurn()
            let buffer = LiveTurnBuffer(), tail = OutputTail()
            let structured = schemaText != nil
            Task {
                let refresher = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { break }
                        if let live = buffer.take() { self?.liveTurns[id] = live }
                    }
                }
                var status: WorkStatus = .failed, exit: Int32?
                var summary = CLIOutputSummary()
                // CH-11: for Edit turns in a git project, compare git status before and after.
                let baseline = level == .edit ? await changeBaseline(run.workingDirectory) : nil
                if await confirmLogin(tool) == .loggedOut {
                    // TurnDiagnosis turns this into the "log in first" message.
                    summary.errorMessage = "Not logged in"; log.append("\n[system] CLI 没有登录，没有启动。\n")
                } else { do {
                    let collector = CLIOutputCollector(format: tool.format) { buffer.handle($0) }
                    var environment = await environmentAfterLookup(for: tool)
                    if let note = Self.environmentNote(environment) { log.append(note) }
                    environment["MYWORKBENCH_OUTPUT_DIR"] = run.outputDirectory; environment["MYWORKBENCH_RUN_ID"] = runID.uuidString
                    let result = try await runner.run(id: runID, tool: tool, input: prompt, directory: run.workingDirectory, arguments: run.arguments, environment: environment, onOutput: { chunk in
                        log.append(chunk); tail.append(chunk.text)
                        if chunk.stream == .stdout { collector.consume(chunk.text) }
                    })
                    status = result.status; exit = result.exitCode
                    summary = collector.finish()
                    recordOutput(summary, runID: runID, outputDirectory: run.outputDirectory, format: tool.format, structured: structured, log: log)
                    log.append("\n[system] 退出码 \(result.exitCode) · \(result.status.title)\n")
                } catch { log.append("\n[system] \(error.localizedDescription)\n"); tail.append(error.localizedDescription) } }
                refresher.cancel()
                var changed: [String]?
                if let baseline { changed = await changedFiles(since: baseline, directory: run.workingDirectory) }
                let live = buffer.take() ?? liveTurns[id]
                try? log.close()
                finishTurn(id, runID: runID, status: status, exit: exit, summary: summary, tail: tail.text, live: live, tool: tool, sessionID: sessionID, changedFiles: changed)
            }
        } catch { failTurn(id, error.localizedDescription) }
    }

    private func finishTurn(_ id: UUID, runID: UUID, status: WorkStatus, exit: Int32?, summary: CLIOutputSummary, tail: String, live: LiveTurn?, tool: ToolConfig, sessionID: String?, changedFiles: [String]? = nil) {
        liveTurns.removeValue(forKey: id); activeTurns.removeValue(forKey: id)
        guard let index = snapshot.messages.firstIndex(where: { $0.id == id }) else { return }
        let turn = snapshot.messages[index]
        let reply = summary.replyText.isEmpty ? (live?.text ?? "") : summary.replyText
        snapshot.messages[index].state = TurnState(status)
        snapshot.messages[index].text = String(reply.prefix(200_000))
        let activities = summary.activities.isEmpty ? (live?.activities ?? []) : summary.activities
        snapshot.messages[index].activities = activities.isEmpty ? nil : Array(activities.suffix(300))
        snapshot.messages[index].usage = summary.usage.isEmpty ? nil : summary.usage
        snapshot.messages[index].detail = TurnDiagnosis.explain(status: status, exitCode: exit, summary: summary, tool: tool, outputTail: tail)
        snapshot.messages[index].endedAt = Date()
        snapshot.messages[index].changedFiles = changedFiles.flatMap { $0.isEmpty ? nil : Array($0.prefix(500)) }
        if let r = snapshot.runs.firstIndex(where: { $0.id == runID }) {
            snapshot.runs[r].status = status; snapshot.runs[r].exitCode = exit; snapshot.runs[r].endedAt = Date()
            snapshot.runs[r].replyText = String(reply.prefix(16_000))
            do { try refreshArtifacts(runID: runID) } catch { errorMessage = "产物归档失败：\(error.localizedDescription)" }
        }
        // A session counts once the CLI reports it, or once a turn on a workbench-chosen ID succeeded.
        if let agentID = turn.agentID, let native = summary.sessionID ?? (status == .review ? sessionID : nil) {
            snapshot.recordSession(conversationID: turn.conversationID, agentID: agentID, toolID: tool.id, nativeID: native)
        }
        if let c = snapshot.conversations.firstIndex(where: { $0.id == turn.conversationID }) { snapshot.conversations[c].updatedAt = Date() }
        if turn.turnKind == .planning && status == .review { handlePlanningResult(index, summary: summary) }
        if turn.turnKind == .production && status == .review { handleProductionResult(index, summary: summary) }
        save()
        scheduleTurns(); schedulePending()
    }

    // MARK: Turn actions

    func stopTurn(_ id: UUID) {
        if let runID = activeTurns[id] { runner.cancel(id: runID); return }
        guard let index = snapshot.messages.firstIndex(where: { $0.id == id && $0.state == .queued }) else { return }
        change { snapshot in snapshot.messages[index].state = .cancelled; snapshot.messages[index].endedAt = Date() }
        scheduleTurns()
    }

    /// Sends the same request to the same agent again; with `newSession`, the old CLI session is set aside first.
    @discardableResult func retryTurn(_ id: UUID, newSession: Bool) -> Bool {
        guard let turn = message(id), turn.role == .agent, turn.state?.isActive == false, let agentID = turn.agentID, let agent = employee(agentID), !agent.isDeleted,
              conversation(turn.conversationID)?.isDeleted == false else { return false }
        if let project = conversation(turn.conversationID).flatMap({ project($0.projectID) }), project.isArchived { errorMessage = Self.archivedProjectMessage; return false }
        if let tool = tool(agent.toolID), !tool.executableAvailable { missingCLIToolID = tool.id; return false }
        var next = ChatMessage(conversationID: turn.conversationID, role: .agent, text: "")
        next.agentID = agentID; next.replyToID = turn.replyToID; next.kind = turn.kind; next.prompt = turn.prompt; next.state = .queued
        let saved = change { snapshot in
            if newSession { for i in snapshot.sessions.indices where snapshot.sessions[i].conversationID == turn.conversationID && snapshot.sessions[i].agentID == agentID { snapshot.sessions[i].invalid = true } }
            snapshot.messages.append(next)
        }
        if saved { scheduleTurns() }
        return saved
    }

    /// Turns a reply into a tracked task that needs acceptance (CH-09).
    @discardableResult func promoteToTask(_ id: UUID) -> UUID? {
        guard let turn = message(id), turn.promotedTaskID == nil, let agentID = turn.agentID, let user = message(turn.replyToID),
              let conversation = conversation(turn.conversationID), !conversation.isDeleted, let project = project(conversation.projectID) else { return nil }
        var input = user.text
        if let attachments = user.attachments, !attachments.isEmpty { input += "\n\n参考文件：\n" + attachments.joined(separator: "\n") }
        if !turn.text.isEmpty { input += "\n\n对话中的回复（供参考）：\n" + String(turn.text.prefix(4000)) }
        var task = WorkTask(title: Conversation.title(from: user.text), employeeID: agentID, input: input, workingDirectory: project.directory, acceptance: "检查回复与改动是否达到要求。")
        task.projectID = project.id; task.accessLevel = user.access
        guard addTask(task), let index = snapshot.messages.firstIndex(where: { $0.id == id }) else { return nil }
        change { $0.messages[index].promotedTaskID = task.id }
        return task.id
    }

    // MARK: Team mode (M7)

    private func handlePlanningResult(_ index: Int, summary: CLIOutputSummary) {
        let turn = snapshot.messages[index]
        guard let user = message(turn.replyToID) else { return }
        do {
            guard let data = summary.structuredJSON ?? CLIOutputCollector.extractJSONObject(from: summary.replyText) else { throw CollaborationError.missingStructuredOutput }
            var draft = try JSONDecoder().decode(PlanDraft.self, from: data)
            try draft.validate(workspace: snapshot)
            let allowed = Set(user.targetIDs ?? [])
            guard draft.steps.allSatisfy({ allowed.contains($0.employeeID) }) else { throw TeamPlanError.outsideTeam }
            for step in draft.steps.indices {
                guard let agent = employee(draft.steps[step].employeeID), let tool = tool(agent.toolID) else { continue }
                var level = min(draft.steps[step].access ?? .readOnly, agent.maxAccess ?? .readOnly)
                if !tool.supports(level) { level = .readOnly }
                draft.steps[step].access = level
            }
            snapshot.messages[index].planDraft = draft
            snapshot.messages[index].text = "我把这件事拆成了 \(draft.steps.count) 个步骤，请审阅后再启动。"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            snapshot.messages[index].text = "返回的计划无法使用（原始输出保存在日志中）。"
            if turn.repairOfID == nil {
                var repair = ChatMessage(conversationID: turn.conversationID, role: .agent, text: "")
                repair.agentID = turn.agentID; repair.replyToID = turn.replyToID; repair.kind = .planning; repair.state = .queued; repair.repairOfID = turn.id
                repair.prompt = "你上一次返回的计划不能使用：\(reason)\n请修正后只返回一个符合 JSON Schema 的计划 JSON，只使用员工表中的员工，不要输出其他文字。"
                snapshot.messages.append(repair)
                snapshot.messages[index].detail = "计划无效，已请负责人修正一次：\(reason)"
            } else {
                snapshot.messages[index].state = .failed
                snapshot.messages[index].detail = "负责人两次都没有返回可用的计划：\(reason)"
            }
        }
    }

    /// Starts an approved team plan; nothing ran before this call (TM-04).
    @discardableResult func approveTeamPlan(messageID: UUID, draft: PlanDraft, reviewerID: UUID?, maximumReworks: Int, useWorktrees: Bool = false) -> UUID? {
        guard let turn = message(messageID), turn.turnKind == .planning, turn.planID == nil, let user = message(turn.replyToID),
              let conversation = conversation(turn.conversationID), !conversation.isDeleted else { return nil }
        let allowed = Set(user.targetIDs ?? [])
        guard draft.steps.allSatisfy({ allowed.contains($0.employeeID) }) else { errorMessage = TeamPlanError.outsideTeam.errorDescription; return nil }
        guard let planID = approvePlan(draft, planningTaskID: nil, projectID: conversation.projectID, reviewerID: reviewerID, maximumReworks: maximumReworks, useWorktrees: useWorktrees) else { return nil }
        change { snapshot in
            if let p = snapshot.plans.firstIndex(where: { $0.id == planID }) { snapshot.plans[p].conversationID = conversation.id; snapshot.plans[p].leadID = turn.agentID }
            if let m = snapshot.messages.firstIndex(where: { $0.id == messageID }) { snapshot.messages[m].planID = planID; snapshot.messages[m].planDraft = draft }
            if let c = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) { snapshot.conversations[c].updatedAt = Date() }
        }
        return planID
    }

    /// When every step of a conversation's plan is accepted, the lead posts a summary (TM-09).
    func requestWrapUpIfDone(planID: UUID) {
        guard let plan = snapshot.plans.current.first(where: { $0.id == planID }), let conversationID = plan.conversationID, let leadID = plan.leadID,
              plan.wrapUpMessageID == nil, employee(leadID) != nil,
              plan.taskIDs.allSatisfy({ id in snapshot.tasks.contains { $0.id == id && $0.status == .completed } }),
              let planning = snapshot.messages.first(where: { $0.planID == planID }) else { return }
        let lines = plan.taskIDs.compactMap { id -> String? in
            guard let task = snapshot.tasks.first(where: { $0.id == id }) else { return nil }
            let run = runs(for: id).first
            let files = run.map { artifacts(for: $0.id).compactMap { try? archive.url(for: $0).path } } ?? []
            return "· \(task.title)（\(employee(task.employeeID)?.name ?? "员工")）：\(String((run?.replyText ?? "").prefix(1200)))" + (files.isEmpty ? "" : "\n  文件：" + files.joined(separator: "、"))
        }
        var turn = ChatMessage(conversationID: conversationID, role: .agent, text: "")
        turn.agentID = leadID; turn.replyToID = planning.replyToID; turn.kind = .wrapUp; turn.state = .queued
        turn.prompt = "计划「\(plan.title)」的所有步骤都已验收。请用简短的中文向用户总结完成了什么、产出了哪些文件、还有什么需要注意。不要修改文件。\n\n" + lines.joined(separator: "\n")
        let saved = change { snapshot in
            snapshot.messages.append(turn)
            if let p = snapshot.plans.firstIndex(where: { $0.id == planID }) { snapshot.plans[p].wrapUpMessageID = turn.id }
            if let c = snapshot.conversations.firstIndex(where: { $0.id == conversationID }) { snapshot.conversations[c].updatedAt = Date() }
        }
        if saved { scheduleTurns() }
    }
}

enum TeamPlanError: LocalizedError {
    case outsideTeam
    var errorDescription: String? { "计划只能使用这次选中的员工。" }
}

// MARK: Director mode (M8)

extension WorkbenchStore {
    /// Agents a director may hand writing or analysis steps to: every enabled agent whose CLI can run.
    private var directorRoster: [Employee] { snapshot.employees.current.filter { ($0.enabled ?? true) && (tool($0.toolID)?.isCLI ?? false) && (tool($0.toolID)?.isEnabled ?? false) } }

    /// MD-16 default: the templates of the project's modules (all templates when none match), and the enabled servers whose
    /// last check did not fail. An on-demand server that has not been checked yet still counts; it is started before jobs run.
    func defaultDirectorScope(projectID: UUID?) -> DirectorScope {
        let modules = Set(project(projectID)?.moduleIDs ?? [])
        let matching = snapshot.templates.current.filter { !modules.isDisjoint(with: $0.moduleIDs) }
        let templates = matching.isEmpty ? snapshot.templates.current : matching
        let servers = enabledServers.filter { serverHealth[$0.id]?.usable != false }
        return DirectorScope(templateIDs: Set(templates.map(\.id)), serverIDs: Set((servers.isEmpty ? enabledServers : servers).map(\.id)))
    }
    /// The scope recorded on a director message; older messages without one use everything, as before.
    func directorScope(for user: ChatMessage) -> (templates: [WorkflowTemplate], servers: [ComfyServer]) {
        let scope = DirectorScope(templateIDs: Set(user.directorTemplateIDs ?? snapshot.templates.current.map(\.id)), serverIDs: Set(user.directorServerIDs ?? enabledServers.map(\.id)))
        return scope.resolved(in: self)
    }

    func productionSchema(director: Employee, user: ChatMessage) throws -> Data {
        var roster = directorRoster.map(\.id); if !roster.contains(director.id) { roster.insert(director.id, at: 0) }
        let scope = directorScope(for: user)
        return try CollaborationSchema.production(employeeIDs: roster, templateIDs: scope.templates.map(\.id), serverIDs: scope.servers.map(\.id), toolIDs: commandTools.map(\.id))
    }

    func directorPrompt(user: ChatMessage, director: Employee, project: WorkProject) -> String {
        let scope = directorScope(for: user)
        let catalog = scope.templates.map { template -> String in
            let modules = template.moduleIDs.compactMap { id in workspaces.first { $0.id == id }?.name }.joined(separator: "、")
            let parameters = template.parameters.map { parameter -> String in
                var limits: [String] = []
                if let minimum = parameter.minimum { limits.append("最小 \(minimum)") }
                if let maximum = parameter.maximum { limits.append("最大 \(maximum)") }
                if let choices = parameter.choices { limits.append("可选 " + choices.joined(separator: "/")) }
                return "  - \(parameter.name)：\(parameter.type.title)\(parameter.type.isFile ? "（放在 inputs，来源写 attachment:序号 或 step:步骤编号）" : "")\(limits.isEmpty ? "" : "，" + limits.joined(separator: "，"))\(parameter.description.isEmpty ? "" : "。" + parameter.description)"
            }.joined(separator: "\n")
            let outputs = template.outputs.map(\.kind.title).joined(separator: "、")
            return "· 模板 id=\(template.id.uuidString)：\(template.name)（工作区：\(modules.isEmpty ? "未指定" : modules)；输出：\(outputs.isEmpty ? "未声明" : outputs)）\(template.description.isEmpty ? "" : "\n  说明：" + template.description)\n\(parameters)"
        }.joined(separator: "\n")
        let servers = scope.servers.map { server -> String in
            let health = serverHealth[server.id]
            return "· 服务器 id=\(server.id.uuidString)：\(server.name)\(server.hourlyPrice.map { "，约 \($0) \(server.currency ?? "") / 小时" } ?? "，价格未知")\(health?.gpu.map { "，GPU \($0)" } ?? "")"
        }.joined(separator: "\n")
        let roster = directorRoster.map { "· 员工 id=\($0.id.uuidString)：\($0.name)（\($0.role)）" }.joined(separator: "\n")
        let commands = commandTools.map { "· 命令工具 id=\($0.id.uuidString)：\($0.name)（\($0.executable)）" }.joined(separator: "\n")
        let attachments = (user.attachments ?? []).enumerated().map { "· attachment:\($0.offset) = \($0.element)" }.joined(separator: "\n")
        return """
        你是这个项目的导演。把用户的需求变成一份制作计划，由工作台在用户确认后执行。只做规划：不要执行步骤、不要修改文件。
        步骤有三种：
        - generate：在服务器上运行一个工作流模板。填 templateID、serverID；parameters 用 name/value 填非文件参数（数字也写成字符串，种子可写 random）；inputs 填文件参数和来源。
        - agent：交给员工写脚本、分镜或分析，填 employeeID、input、access（readOnly 或 edit）。
        - command：用命令工具处理文件（例如合成视频），填 toolID 和 arguments；用 {input:步骤编号} 引用前序步骤的文件，用 {output} 表示本步骤的输出目录。参数不经过 shell。
        不用的字段写空字符串或空数组。每个步骤都要写 id、title、acceptance、dependencies；用到前序步骤产物时必须把它写进 dependencies。最多 20 步，控制生成次数以节省 GPU 预算。只返回符合 JSON Schema 的计划。

        项目：\(project.name)
        项目目标：\(project.goal)
        用户需求：\(user.text)
        \(attachments.isEmpty ? "" : "用户附件：\n" + attachments)

        可用模板：
        \(catalog)

        可用服务器：
        \(servers)

        可用员工：
        \(roster)
        \(commands.isEmpty ? "没有可用的命令工具，不要使用 command 步骤。" : "可用命令工具：\n" + commands)
        """
    }

    func handleProductionResult(_ index: Int, summary: CLIOutputSummary) {
        let turn = snapshot.messages[index]
        guard let user = message(turn.replyToID), let directorID = turn.agentID else { return }
        do {
            guard let data = summary.structuredJSON ?? CLIOutputCollector.extractJSONObject(from: summary.replyText) else { throw CollaborationError.missingStructuredOutput }
            let draft = try JSONDecoder().decode(ProductionPlanDTO.self, from: data).toDraft(directorID: directorID)
            try draft.validate(workspace: snapshot)
            try snapshot.validateProduction(draft, attachments: user.attachments ?? [])
            snapshot.messages[index].planDraft = draft
            let generates = draft.steps.filter { $0.stepKind == .generate }.count
            snapshot.messages[index].text = "制作计划共 \(draft.steps.count) 步，其中 \(generates) 个生成任务。请审阅参数和预算后再启动。"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            snapshot.messages[index].text = "返回的制作计划无法使用（原始输出保存在日志中）。"
            if turn.repairOfID == nil {
                var repair = ChatMessage(conversationID: turn.conversationID, role: .agent, text: "")
                repair.agentID = turn.agentID; repair.replyToID = turn.replyToID; repair.kind = .production; repair.state = .queued; repair.repairOfID = turn.id
                repair.prompt = "你上一次返回的制作计划不能使用：\(reason)\n请修正后只返回一个符合 JSON Schema 的制作计划 JSON，只使用前面列出的模板、服务器、员工和命令工具，不要输出其他文字。"
                snapshot.messages.append(repair)
                snapshot.messages[index].detail = "计划无效，已请导演修正一次：\(reason)"
            } else {
                snapshot.messages[index].state = .failed
                snapshot.messages[index].detail = "导演两次都没有返回可用的制作计划：\(reason)"
            }
        }
    }

    /// Estimated GPU seconds and cost of every generate step in a draft; nil when any estimate is unknown.
    func productionEstimate(_ draft: PlanDraft) -> (seconds: Double?, cost: Double?, unknown: Int) {
        var seconds = 0.0, cost = 0.0, unknown = 0, costUnknown = false
        for step in draft.steps where step.stepKind == .generate {
            let estimate = estimate(templateID: step.templateID, serverID: step.serverID)
            let times = Double(min(8, max(1, step.variants ?? 1)))
            if let s = estimate.seconds { seconds += s * times } else { unknown += 1 }
            if let c = estimate.cost { cost += c * times } else { costUnknown = true }
        }
        return (unknown == 0 ? seconds : nil, costUnknown ? nil : cost, unknown)
    }

    /// Starts an approved production plan. Nothing is submitted to a server before this call (MD-17).
    @discardableResult func approveProductionPlan(messageID: UUID, draft: PlanDraft, budgetMinutes: Double?, budgetCost: Double?, directorReview: Bool, maximumReworks: Int) -> UUID? {
        guard let turn = message(messageID), turn.turnKind == .production, turn.planID == nil, let directorID = turn.agentID, let user = message(turn.replyToID),
              let conversation = conversation(turn.conversationID), !conversation.isDeleted, let project = project(conversation.projectID) else { return nil }
        guard !project.isArchived else { errorMessage = Self.archivedProjectMessage; return nil }
        let attachments = user.attachments ?? []
        do {
            try BudgetCap.validate(minutes: budgetMinutes, cost: budgetCost, hasGenerateSteps: draft.steps.contains { $0.stepKind == .generate })
            try draft.validate(workspace: snapshot)
            try snapshot.validateProduction(draft, attachments: attachments)
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return nil }
        let planID = UUID(), mapping = Dictionary(uniqueKeysWithValues: draft.steps.map { ($0.id, UUID()) })
        var tasks: [WorkTask] = []
        for step in draft.steps {
            var task = WorkTask(id: mapping[step.id]!, title: step.title, employeeID: step.stepKind == .agent ? step.employeeID : directorID, input: step.input, workingDirectory: project.directory, acceptance: step.acceptance)
            task.projectID = project.id; task.planID = planID; task.status = .queued
            task.dependencyIDs = step.dependencies.compactMap { mapping[$0] }
            switch step.stepKind {
            case .agent: task.accessLevel = step.access
            case .generate:
                guard let template = snapshot.template(step.templateID), let serverID = step.serverID else { return nil }
                var values: [String: JSONValue] = [:]
                for item in step.parameters ?? [] { if let parameter = template.parameter(item.name) { values[item.name] = try? parameter.parse(item.value) } }
                var inputs: [String: String] = [:]
                for item in step.inputs ?? [] {
                    if item.value.hasPrefix("attachment:"), let n = Int(item.value.dropFirst(11)), attachments.indices.contains(n) { inputs[item.name] = attachments[n] }
                    else if item.value.hasPrefix("step:"), let source = mapping[String(item.value.dropFirst(5))] { inputs[item.name] = "task:" + source.uuidString }
                }
                task.generation = GenerationSpec(templateID: template.id, serverID: serverID, values: values, inputs: inputs, versionHash: template.versionHash)
                task.generation?.variantCount = step.variants.flatMap { $0 > 1 ? min(8, $0) : nil }
            case .command:
                guard let toolID = step.toolID else { return nil }
                let arguments = (step.arguments ?? []).map { argument -> String in
                    var text = argument
                    for (stepID, taskID) in mapping { text = text.replacingOccurrences(of: "{input:\(stepID)}", with: "{input:\(taskID.uuidString)}") }
                    return text
                }
                task.command = CommandSpec(toolID: toolID, arguments: arguments)
            }
            tasks.append(task)
        }
        var plan = CollaborationPlan(id: planID, projectID: project.id, title: draft.title, goal: draft.goal, taskIDs: tasks.map(\.id), reviewerID: nil, maximumReworks: maximumReworks)
        plan.kind = .production; plan.conversationID = conversation.id; plan.leadID = directorID
        plan.budgetMinutes = budgetMinutes; plan.budgetCost = budgetCost
        plan.directorReview = directorReview; plan.spentSeconds = 0; plan.spentCost = 0
        guard change({ snapshot in
            snapshot.plans.append(plan); snapshot.tasks.insert(contentsOf: tasks, at: 0)
            if let m = snapshot.messages.firstIndex(where: { $0.id == messageID }) { snapshot.messages[m].planID = planID; snapshot.messages[m].planDraft = draft }
            if let c = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) { snapshot.conversations[c].updatedAt = Date() }
        }) else { return nil }
        schedulePending()
        return planID
    }
}
