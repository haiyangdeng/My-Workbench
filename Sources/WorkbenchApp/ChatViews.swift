import AppKit
import SwiftUI

enum ProjectTab: String, CaseIterable, Identifiable {
    case conversations, tasks, plans, assets
    var id: Self { self }
    var title: String {
        switch self {
        case .conversations: return "对话"
        case .tasks: return "任务"
        case .plans: return "计划"
        case .assets: return "素材"
        }
    }
}

/// The bottom input bar: pick agents, mode and access, then send to the open conversation or start a new one.
struct ChatComposerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.studioStyle) private var style
    private var pixel: Bool { colorScheme == .dark && style.isPixel }
    @ObservedObject var store: WorkbenchStore
    var accent: Color
    @Binding var text: String
    @Binding var agentIDs: [UUID]
    @Binding var mode: ChatMode
    @Binding var access: AccessLevel
    @Binding var attachments: [String]
    @Binding var projectID: UUID?
    /// Director mode: the templates and servers the director may use; nil means the default for the project.
    var lockedProjectID: UUID?
    var conversationTitle: String?
    var onSend: () -> Void
    var onAttach: () -> Void
    var onNewTask: () -> Void
    var onPlanner: () -> Void
    var onAddWorkspace: () -> Void
    var onTerminal: () -> Void
    var onNewProject: () -> Void
    var onNewConversation: () -> Void
    /// Director mode: the templates and servers the director may use; nil means the default for the project.
    var directorScope: Binding<DirectorScope?> = .constant(nil)
    @FocusState private var focused: Bool

    private var agents: [Employee] { agentIDs.compactMap { store.employee($0) } }
    private var canEdit: Bool { mode != .parallel && agents.contains { ($0.maxAccess ?? .readOnly) == .edit && (store.tool($0.toolID)?.supports(.edit) ?? false) } }
    private var targetProject: WorkProject? { store.project(lockedProjectID ?? projectID) }

    var body: some View {
        VStack(spacing: 7) {
            if !agents.isEmpty || !attachments.isEmpty || lockedProjectID == nil || conversationTitle != nil { contextRow }
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 17)).foregroundStyle(accent)
                TextField(agents.isEmpty ? "选择员工（或输入 @名字），告诉 TA 要做什么…" : "告诉 \(agents.map(\.name).joined(separator: "、")) 要做什么…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...5).focused($focused)
                    .onKeyPress(keys: [.return]) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { text.append("\n"); return .handled }
                        onSend(); return .handled
                    }
                    .accessibilityIdentifier("studio.idea")
                agentMenu
                Button(action: onAttach) { Image(systemName: "paperclip").font(.system(size: 16)) }.buttonStyle(.plainPointer).help("添加参考文件（只传路径，不上传）").accessibilityLabel("添加参考文件")
                Menu {
                    Button("把输入做成任务…", action: onNewTask).disabled(!store.snapshot.employees.current.contains { $0.enabled != false })
                    Button("让 AI 安排协作（任务）", action: onPlanner).disabled(store.currentProject?.isArchived != false || store.planningCandidates.isEmpty)
                    Button("新对话", action: onNewConversation)
                    Button("添加工作区", action: onAddWorkspace)
                    Button("打开终端", action: onTerminal)
                } label: { Image(systemName: "square.grid.2x2").frame(width: 32, height: 32).background(colorScheme == .dark ? Theme.raised : Theme.paper, in: StudioShape(16, pixel: pixel)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作")
                Button(action: onSend) {
                    Image(systemName: "paperplane").font(.system(size: 15, weight: colorScheme == .dark ? .semibold : .regular)).foregroundStyle(.white).frame(width: 38, height: 38)
                        .background { if pixel { PixelBlockBackground(fill: Theme.actionFill, radius: 19) } else { Circle().fill(Theme.adaptive("3B7B65", "2F8170")) } }
                        .studioShadow(pixel: pixel, color: colorScheme == .dark ? Color(hex: "2F8170").opacity(0.45) : .clear, radius: 8, y: 0)
                }
                    .buttonStyle(.plainPointer).disabled((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty) || !store.storageAvailable)
                    .help("发送（Return）；Shift+Return 换行").accessibilityLabel("发送").accessibilityIdentifier("studio.compose")
            }.padding(.leading, 18).padding(.trailing, 6).frame(minHeight: 50)
                .background(colorScheme == .dark ? Theme.input : Theme.surface, in: StudioShape(25, pixel: pixel)).overlay(StudioShape(25, pixel: pixel).stroke(colorScheme == .dark ? Theme.border : Theme.blue.opacity(0.06), lineWidth: pixel ? 2 : 1))
                .studioShadow(pixel: pixel, color: .black.opacity(colorScheme == .dark ? 0.35 : 0.055), radius: 15, y: 7)
        }.frame(maxWidth: 760).padding(.horizontal, 30).padding(.vertical, 12)
    }

    /// MD-16: which templates and servers the director may plan with. Defaults to the project's modules and healthy servers.
    private var directorScopeMenu: some View {
        let current = directorScope.wrappedValue ?? store.defaultDirectorScope(projectID: lockedProjectID ?? projectID)
        func toggle(_ id: UUID, templates: Bool) -> Binding<Bool> {
            Binding(get: { (templates ? current.templateIDs : current.serverIDs).contains(id) }, set: { on in
                var scope = current
                if templates { if on { scope.templateIDs.insert(id) } else { scope.templateIDs.remove(id) } }
                else { if on { scope.serverIDs.insert(id) } else { scope.serverIDs.remove(id) } }
                directorScope.wrappedValue = scope
            })
        }
        return Menu {
            Section("可用的模板") { ForEach(store.snapshot.templates.current) { template in Toggle(template.name, isOn: toggle(template.id, templates: true)) } }
            Section("可用的服务器") {
                ForEach(store.enabledServers) { server in
                    Toggle(server.name + (store.serverHealth[server.id]?.usable == false ? "（上次检测未通过）" : ""), isOn: toggle(server.id, templates: false))
                }
            }
            Divider()
            Button("恢复默认（本项目工作区的模板、可用的服务器）") { directorScope.wrappedValue = nil }
        } label: {
            Label("\(current.templateIDs.count) 个模板 · \(current.serverIDs.count) 台服务器", systemImage: "slider.horizontal.3").font(.system(size: 10))
        }.menuStyle(.borderlessButton).fixedSize().help("导演只能在这些模板和服务器里规划").accessibilityIdentifier("composer.director-scope")
    }

    private var contextRow: some View {
        HStack(spacing: 8) {
            if lockedProjectID == nil {
                Menu {
                    ForEach(store.activeProjects) { project in Button(project.name) { projectID = project.id } }
                    Divider(); Button("新建项目…", action: onNewProject)
                } label: { Label(targetProject?.name ?? "选择项目", systemImage: "folder") }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("目标项目：" + (targetProject?.name ?? "未选择"))
            } else if let conversationTitle {
                Label("继续：" + conversationTitle, systemImage: "bubble.left.and.bubble.right").lineLimit(1).foregroundStyle(.secondary)
            } else {
                Label("新对话", systemImage: "plus.bubble").foregroundStyle(.secondary)
            }
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                HStack(spacing: 4) {
                    if mode == .team && index == 0 { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.orange).help("负责人") }
                    Text(agent.name)
                    Button { agentIDs.removeAll { $0 == agent.id } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plainPointer).accessibilityLabel("移除 " + agent.name)
                }.padding(.horizontal, 8).padding(.vertical, 3).background(accent.opacity(0.1), in: Capsule())
                    .contextMenu { if mode == .team && index > 0 { Button("设为负责人") { agentIDs.removeAll { $0 == agent.id }; agentIDs.insert(agent.id, at: 0) } } }
            }
            if agents.count == 1 && !store.snapshot.templates.current.isEmpty && !store.enabledServers.isEmpty {
                Toggle("导演", isOn: Binding(get: { mode == .director }, set: { mode = $0 ? .director : .single })).toggleStyle(.switch).controlSize(.mini)
                    .help("让 TA 把需求变成制作计划：在服务器上运行工作流模板，你确认参数和预算后才提交").accessibilityIdentifier("composer.director")
                if mode == .director { directorScopeMenu }
            }
            if agents.count >= 2 {
                Picker("模式", selection: $mode) { Text("并行").tag(ChatMode.parallel); Text("团队").tag(ChatMode.team) }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
                    .help(mode == .team ? "负责人先拆解计划，你确认后再分工执行" : "同一条消息分别发给每位员工，并排比较回复（只读）")
            }
            if !agents.isEmpty && mode != .director {
                Menu {
                    Button("只读") { access = .readOnly }
                    Button("可编辑项目") { access = .edit }.disabled(!canEdit)
                } label: { Label(mode == .parallel ? "只读（并行）" : (canEdit ? access.title : "只读"), systemImage: access == .edit && canEdit ? "pencil" : "eye") }
                    .menuStyle(.borderlessButton).fixedSize().help("这一轮的权限，不会超过员工的最高权限")
            }
            ForEach(attachments, id: \.self) { path in
                HStack(spacing: 4) {
                    Image(systemName: "doc"); Text((path as NSString).lastPathComponent).lineLimit(1)
                    Button { attachments.removeAll { $0 == path } } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plainPointer)
                }.padding(.horizontal, 8).padding(.vertical, 3).background(Color.secondary.opacity(0.1), in: Capsule()).help(path)
            }
            Spacer(minLength: 0)
        }.font(.system(size: 10)).padding(.horizontal, 12)
    }

    private var agentMenu: some View {
        Menu {
            if store.snapshot.employees.current.isEmpty { Text("还没有 AI 员工") }
            ForEach(store.workspaces) { area in
                let members = store.employees(in: area).filter { $0.enabled != false && $0.workspaceID == area.id }
                if !members.isEmpty {
                    Section(area.name) {
                        ForEach(members) { agent in
                            let tool = store.tool(agent.toolID)
                            let state = tool.map { tool -> String in
                                if !tool.isCLI { return " · ComfyUI" }
                                if !tool.executableAvailable { return " · CLI 缺失" }
                                let login = store.loginCheck(for: tool).state
                                return login == .loggedIn ? "" : (login == .unknown || login == .unsupported ? "" : " · " + login.title)
                            } ?? ""
                            Button { toggle(agent.id) } label: {
                                if agentIDs.contains(agent.id) { Label(agent.name + state, systemImage: "checkmark") } else { Text(agent.name + state) }
                            }.disabled(tool?.isCLI != true)
                        }
                    }
                }
            }
        } label: { Image(systemName: "at").font(.system(size: 15)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("选择员工（可多选）").accessibilityLabel("选择员工，已选 \(agentIDs.count) 位").accessibilityIdentifier("composer.agents")
    }
    private func toggle(_ id: UUID) {
        if agentIDs.contains(id) { agentIDs.removeAll { $0 == id } } else { agentIDs.append(id) }
        if agentIDs.count < 2 { if mode != .director || agentIDs.isEmpty { mode = .single } } else if mode == .single || mode == .director { mode = .parallel }
    }
}

struct ConversationListView: View {
    @ObservedObject var store: WorkbenchStore
    var projectID: UUID
    @Binding var selection: UUID?
    var accent: Color
    @State private var renaming: Conversation?
    @State private var newTitle = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { selection = nil } label: { Label("新对话", systemImage: "plus.bubble").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.borderedPointer).accessibilityIdentifier("conversations.new")
            if let id = selection, let conversation = store.conversation(id), !conversation.isDeleted {
                HStack {
                    Button("重命名") { newTitle = conversation.title; renaming = conversation }
                    Spacer()
                    Button("删除对话", role: .destructive) { store.pendingDeletion = DeletionTarget(.conversation, id) }
                }.font(.system(size: 10)).buttonStyle(.linkPointer)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let items = store.conversations(in: projectID)
                    if items.isEmpty { Text("还没有对话。在下方输入栏选择员工并发送，就会开始一个对话。").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8) }
                    ForEach(items) { conversation in row(conversation) }
                }
            }
        }.frame(width: 240).padding(.trailing, 14)
            .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("标题", text: $newTitle)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { if let id = renaming?.id { store.renameConversation(id, to: newTitle) }; renaming = nil }
            }
    }
    private func row(_ conversation: Conversation) -> some View {
        let messages = store.snapshot.messages(in: conversation.id)
        let active = messages.contains { $0.state?.isActive == true }
        let last = messages.last { !$0.text.isEmpty }
        return Button { selection = conversation.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(conversation.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if active { ProgressView().controlSize(.mini) }
                }
                Text(last.map { String($0.text.prefix(80)) } ?? "等待回复…").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selection == conversation.id ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plainPointer)
            .contextMenu { Button("重命名…") { newTitle = conversation.title; renaming = conversation }; Button("删除对话", role: .destructive) { store.pendingDeletion = DeletionTarget(.conversation, conversation.id) } }
            .accessibilityLabel(conversation.title + (active ? "，正在回复" : ""))
    }
}

/// The transcript of one conversation. Replies stream in while their turn runs.
struct ConversationView: View {
    @ObservedObject var store: WorkbenchStore
    var conversationID: UUID
    var accent: Color
    var onContinueInTerminal: (ChatMessage) -> Void
    var onOpenTask: (UUID) -> Void
    var onReviewPlan: (ChatMessage) -> Void
    private var messages: [ChatMessage] { store.snapshot.messages(in: conversationID) }
    private var liveSize: Int { messages.filter { $0.state == .running }.reduce(0) { $0 + (store.liveTurns[$1.id]?.text.count ?? 0) } }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let usage = store.usageTotal({ $0.conversationID == conversationID }) { Text("本对话用量：" + WorkbenchStore.describe(usage)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    ForEach(messages) { message in
                        if message.role == .user { UserBubble(store: store, message: message, accent: accent) }
                        else { TurnCard(store: store, turn: message, accent: accent, onContinueInTerminal: onContinueInTerminal, onOpenTask: onOpenTask, onReviewPlan: onReviewPlan) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.vertical, 6).padding(.trailing, 10)
            }
            .onAppear { reader.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: messages.count) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: liveSize / 400) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
        }.accessibilityIdentifier("conversation." + conversationID.uuidString)
    }
}

private struct UserBubble: View {
    @ObservedObject var store: WorkbenchStore
    var message: ChatMessage
    var accent: Color
    var body: some View {
        HStack {
            Spacer(minLength: 120)
            VStack(alignment: .trailing, spacing: 6) {
                Text(message.text).font(.system(size: 13)).textSelection(.enabled).multilineTextAlignment(.leading)
                    .padding(.horizontal, 14).padding(.vertical, 10).background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                if let attachments = message.attachments {
                    ForEach(attachments, id: \.self) { Label(($0 as NSString).lastPathComponent, systemImage: "doc").font(.system(size: 10)).foregroundStyle(.secondary).help($0) }
                }
                let names = (message.targetIDs ?? []).compactMap { store.employee($0)?.name }
                Text([names.isEmpty ? nil : "给 " + names.joined(separator: "、"), message.mode.map { $0 == .single ? nil : $0.title } ?? nil, message.access?.title, message.createdAt.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

struct TurnStateBadge: View {
    var state: TurnState
    private var color: Color {
        switch state {
        case .running: return .blue
        case .replied: return .green
        case .failed, .timedOut: return .red
        case .queued: return .orange
        default: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 5, height: 5); Text(state.title) }
            .font(.system(size: 9)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.08), in: Capsule())
    }
}

private struct TurnCard: View {
    @ObservedObject var store: WorkbenchStore
    var turn: ChatMessage
    var accent: Color
    var onContinueInTerminal: (ChatMessage) -> Void
    var onOpenTask: (UUID) -> Void
    var onReviewPlan: (ChatMessage) -> Void
    private var agent: Employee? { turn.agentID.flatMap { store.employee($0) } }
    private var tool: ToolConfig? { agent.flatMap { store.tool($0.toolID) } }
    private var live: LiveTurn? { store.liveTurns[turn.id] }
    private var state: TurnState { turn.state ?? .queued }
    private var displayText: String { state == .running ? (live?.text ?? "") : turn.text }
    private var activities: [CLIActivity] { state == .running ? (live?.activities ?? []) : (turn.activities ?? []) }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            EmployeePortrait(symbol: agent?.avatarSymbol, imageData: agent?.avatarImageData, fallback: String((agent?.name ?? "?").prefix(1)), tint: accent).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(agent?.name ?? "已删除的员工").font(.system(size: 12, weight: .semibold))
                    if turn.turnKind == .planning { Text(turn.repairOfID == nil ? "拆解计划" : "修正计划").font(.system(size: 9)).foregroundStyle(.orange) }
                    if turn.turnKind == .production { Text(turn.repairOfID == nil ? "制作计划" : "修正制作计划").font(.system(size: 9)).foregroundStyle(.orange) }
                    if turn.turnKind == .wrapUp { Text("总结").font(.system(size: 9)).foregroundStyle(accent) }
                    TurnStateBadge(state: state)
                    if let resumed = turn.resumed { Text(resumed ? "续接会话" : "新会话").font(.system(size: 9)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    if let started = turn.startedAt { Text(duration(from: started)).font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                content
                if !activities.isEmpty { activityList }
                if let files = turn.changedFiles, !files.isEmpty { changedFiles(files) }
                if let detail = turn.detail, state != .running {
                    Label(detail, systemImage: state == .replied ? "info.circle" : "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(state == .replied ? Color.secondary : Color.orange)
                        .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(state == .replied ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 8)).textSelection(.enabled)
                }
                if turn.planDraft != nil {
                    if turn.turnKind == .production { ProductionPlanCard(store: store, turn: turn, accent: accent, onOpenTask: onOpenTask, onReview: onReviewPlan) }
                    else { PlanCard(store: store, turn: turn, accent: accent, onOpenTask: onOpenTask, onReviewPlan: onReviewPlan) }
                }
                actions
            }
        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.1)))
            .accessibilityElement(children: .contain).accessibilityLabel("\(agent?.name ?? "员工")，\(state.title)")
    }

    @ViewBuilder private var content: some View {
        if displayText.isEmpty {
            if state == .running { HStack(spacing: 7) { ProgressView().controlSize(.small); Text("正在等待回复…").font(.system(size: 11)).foregroundStyle(.secondary) } }
            else if state == .queued { Text(store.message(turn.replyToID)?.mode == .team ? "排队中，等待开始拆解。" : "排队中：这位员工在这个对话里还有一轮没有结束，或项目文件夹正被另一个可编辑任务使用。").font(.system(size: 11)).foregroundStyle(.secondary) }
        } else if displayText.utf8.count > 24_000 {
            ReadOnlyTextView(text: displayText, pointSize: 12, accessibilityName: "回复").frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Text(Self.markdown(displayText)).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var activityList: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(activities.suffix(60).enumerated()), id: \.offset) { _, activity in
                    Text(Self.describe(activity)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
            }.padding(.top, 4)
        } label: {
            Text(state == .running ? "正在：" + (activities.last.map(Self.describe) ?? "") : "\(activities.count) 个操作").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @State private var showDiff = false
    private func changedFiles(_ files: [String]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(files.prefix(80), id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                Button("查看差异") { showDiff = true }.buttonStyle(.linkPointer).font(.system(size: 10))
            }.padding(.top, 4)
        } label: { Text("改动了 \(files.count) 个文件").font(.system(size: 10)).foregroundStyle(.orange) }
            .sheet(isPresented: $showDiff) {
                let directory = store.conversation(turn.conversationID).flatMap { store.project($0.projectID)?.directory } ?? ""
                DiffSheet(title: "这一轮改动的文件") { await store.diff(directory: directory, files: files) }
            }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch state {
            case .running: Button("停止") { store.stopTurn(turn.id) }.tint(.red)
            case .queued: Button("取消") { store.stopTurn(turn.id) }
            default:
                if turn.turnKind == .reply, turn.state == .replied {
                    if let task = turn.promotedTaskID { Button("查看任务") { onOpenTask(task) } }
                    else { Button("转为任务") { if let id = store.promoteToTask(turn.id) { onOpenTask(id) } }.help("变成需要验收的任务") }
                }
                if turn.turnKind == .reply || turn.state != .replied { Button("重新发送") { store.retryTurn(turn.id, newSession: false) } }
                if turn.resumed == true && turn.state != .replied { Button("以新会话重试") { store.retryTurn(turn.id, newSession: true) }.help("放弃旧的 CLI 会话，用这次对话的记录开始新会话") }
            }
            if let tool, tool.supportsTerminalResume, store.session(for: turn) != nil, !state.isActive {
                Button("在终端继续") { onContinueInTerminal(turn) }.help("在内置终端里以交互方式续接同一个会话")
            }
            if let runID = turn.runID, let run = store.snapshot.runs.first(where: { $0.id == runID }) {
                Button("日志") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.logPath)]) }
            }
            Spacer(minLength: 0)
            if let usage = turn.usage { Text(Self.usage(usage)).font(.system(size: 9)).foregroundStyle(.secondary) }
        }.font(.system(size: 10)).buttonStyle(.linkPointer)
    }

    private func duration(from start: Date) -> String {
        let seconds = Int((turn.endedAt ?? Date()).timeIntervalSince(start))
        return seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
    static func describe(_ activity: CLIActivity) -> String {
        let names = ["Edit": "编辑", "Write": "写入", "MultiEdit": "编辑", "Read": "读取", "Bash": "运行", "command": "运行", "Grep": "搜索", "Glob": "查找文件", "file_change": "改动文件", "WebFetch": "读取网页", "WebSearch": "搜索网页", "web_search": "搜索网页", "mcp": "调用工具"]
        return (names[activity.kind] ?? activity.kind) + (activity.summary.isEmpty ? "" : " · " + activity.summary)
    }
    static func usage(_ usage: CLIUsage) -> String {
        [usage.costUSD.map { String(format: "$%.4f", $0) }, usage.inputTokens.map { "输入 \($0)" }, usage.outputTokens.map { "输出 \($0) tokens" }].compactMap { $0 }.joined(separator: " · ")
    }
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A team plan inside the transcript: the draft before approval, then each step's progress.
private struct PlanCard: View {
    @ObservedObject var store: WorkbenchStore
    var turn: ChatMessage
    var accent: Color
    var onOpenTask: (UUID) -> Void
    var onReviewPlan: (ChatMessage) -> Void
    private var plan: CollaborationPlan? { turn.planID.flatMap { id in store.snapshot.plans.current.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan { running(plan) } else if turn.planID != nil { Text("计划已删除，历史执行记录保留。").font(.system(size: 11)).foregroundStyle(.secondary) } else if let draft = turn.planDraft { pending(draft) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pending(_ draft: PlanDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.title).font(.system(size: 13, weight: .semibold))
            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(step.title)").font(.system(size: 12))
                    Text([store.employee(step.employeeID)?.name, (step.access ?? .readOnly).title, step.dependencies.isEmpty ? nil : "依赖 " + step.dependencies.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("审阅并启动…") { onReviewPlan(turn) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.isArchived(projectID: store.conversation(turn.conversationID)?.projectID))
                Text("确认之前不会执行任何步骤。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func running(_ plan: CollaborationPlan) -> some View {
        let tasks = plan.taskIDs.compactMap { id in store.snapshot.tasks.first { $0.id == id } }
        let done = tasks.filter { $0.status == .completed }.count
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(plan.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("完成 \(done)/\(tasks.count) · \(plan.paused ? "已暂停" : (done == tasks.count ? "已交付" : "进行中"))").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(done), total: Double(max(1, tasks.count)))
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(task.title).font(.system(size: 12)).lineLimit(1)
                        Text(store.ownerName(task)).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if store.editLocked(task.workingDirectory) && task.status == .queued && (task.accessLevel ?? .readOnly) == .edit { Text("等待文件夹").font(.system(size: 9)).foregroundStyle(.orange) }
                        StatusBadge(status: task.status, compact: true)
                    }
                    let text = task.status == .running ? (store.liveTurns[task.id]?.text ?? "") : (store.runs(for: task.id).first?.replyText ?? "")
                    if !text.isEmpty { Text(String(text.suffix(400))).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
                    HStack(spacing: 10) {
                        if task.status == .review && task.purpose != .planning { Button("验收") { store.accept(task.id) } }
                        Button("详情") { onOpenTask(task.id) }
                    }.font(.system(size: 10)).buttonStyle(.linkPointer)
                }.padding(.vertical, 3)
            }
            HStack(spacing: 12) {
                Button(plan.paused ? "继续后续步骤" : "暂停后续步骤") { store.pausePlan(plan.id, paused: !plan.paused) }
                Button("停止整个计划") { store.stopPlan(plan.id) }.tint(.red)
                Spacer()
                Text(plan.reviewerID.flatMap { store.employee($0)?.name }.map { "AI 审核：\($0) · 返工上限 \(plan.maximumReworks) 次" } ?? "人工验收").font(.system(size: 9)).foregroundStyle(.secondary)
            }.font(.system(size: 10)).buttonStyle(.linkPointer).disabled(done == tasks.count)
        }
    }
}

/// A unified diff loaded on demand.
struct DiffSheet: View {
    var title: String
    var load: () async -> String
    @Environment(\.dismiss) private var dismiss
    @State private var text = "正在读取差异…"
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 18, weight: .semibold))
            ReadOnlyTextView(text: text, pointSize: 11, accessibilityName: "差异").clipShape(RoundedRectangle(cornerRadius: 8))
            HStack { Text("只读显示，不会改动任何文件。").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 860, minHeight: 600)
            .task { let result = await load(); text = result.isEmpty ? "没有差异。" : result }
    }
}

/// A team step's own git worktree: see the diff, then merge into the project or discard (TM-08).
struct WorktreePanel: View {
    @ObservedObject var store: WorkbenchStore
    var task: WorkTask
    var worktree: WorktreeInfo
    @State private var showDiff = false
    @State private var working = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("独立 worktree").font(.system(size: 12, weight: .medium))
            if worktree.state == .unavailable { Text(worktree.note ?? "没有使用 worktree。").font(.system(size: 10)).foregroundStyle(.secondary) }
            else {
                Text("分支 \(worktree.branch) · \(stateTitle)").font(.system(size: 10)).foregroundStyle(worktree.state == .conflict ? .orange : .secondary)
                Text(worktree.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if let note = worktree.note, worktree.state != .active { Text(note).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                if worktree.state == .active {
                    HStack {
                        Button("查看差异") { showDiff = true }
                        Button("合并到项目") { working = true; Task { await store.mergeWorktree(task.id); working = false } }.disabled(working || ![.review, .completed].contains(task.status))
                        Button("放弃改动", role: .destructive) { working = true; Task { await store.discardWorktree(task.id); working = false } }.disabled(working || task.status == .running)
                        if working { ProgressView().controlSize(.small) }
                    }.buttonStyle(.borderedPointer).font(.system(size: 10))
                    Text("合并会在 worktree 分支上提交改动，再合并到项目当前分支；有冲突时留给你在终端处理。").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .sheet(isPresented: $showDiff) { DiffSheet(title: "「\(task.title)」的改动") { await store.worktreeDiff(task.id) } }
    }
    private var stateTitle: String {
        switch worktree.state { case .active: return "未合并"; case .merged: return "已合并"; case .discarded: return "已放弃"; case .conflict: return "合并冲突"; case .unavailable: return "未使用" }
    }
}
