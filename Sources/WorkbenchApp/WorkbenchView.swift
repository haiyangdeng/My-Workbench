import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum SheetKind: String, Identifiable {
    case tool, employee, task
    var id: Self { self }
}

enum Theme {
    /// Theme preference key. A new key so every install starts in the dark default; light stays selectable in Settings.
    static let preferenceKey = "studioThemeV06"
    static let defaultMood = StudioStyle.ink.rawValue
    /// True while the pixel style is active. Ink and pixel share the dark system appearance, so the dark branch of every
    /// color reads this to choose between them. WorkbenchView sets it from the saved style before its content draws.
    nonisolated(unsafe) static var pixelActive = false
    static func activate(_ style: StudioStyle) { if pixelActive != style.isPixel { pixelActive = style.isPixel } }
    static let blue = adaptive("58735E", "4DB293", pixel: "29ADFF")
    static let navy = Color(red: 0.17, green: 0.23, blue: 0.20)
    static func adaptive(_ light: NSColor, _ dark: NSColor, pixel: NSColor? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return light }
            return pixelActive ? (pixel ?? dark) : dark
        })
    }
    static func adaptive(_ light: String, _ dark: String, pixel: String? = nil) -> Color {
        func color(_ hex: String) -> NSColor {
            let value = UInt32(hex, radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        return adaptive(color(light), color(dark), pixel: pixel.map(color))
    }
    // Dark values follow the 2026-10-18 dark reference: navy canvas, graphite-navy panels, green accent.
    // Pixel values are an arcade night palette: deep indigo, warm white text, PICO-8-like accents.
    static let paper = adaptive("F5F8FA", "0B1826", pixel: "080B1E")
    static let surface = adaptive("FFFFFF", "1A2532", pixel: "111737")
    static let sidebar = adaptive("EEF3F8", "13202D", pixel: "0C1029")
    static let raised = adaptive("FFFFFF", "222D3A", pixel: "1A2350")
    static let input = adaptive("FFFFFF", "1C2836", pixel: "0F1433")
    static let border = adaptive("DDE7EF", "2B3746", pixel: "2A3672")
    static let primaryText = adaptive("111C27", "F2F5F8", pixel: "F4F1EA")
    static let secondaryText = adaptive("718094", "A9B4C2", pixel: "9AA4D2")
    static let actionFill = adaptive("58735E", "2F8170", pixel: "1D63D8")
    /// Text on the pixel style's bright workspace-color blocks.
    static let pixelInk = Color(hex: "0B0E22")
}

enum StudioSelection: Equatable {
    case project, workspace(UUID), manageAreas, employee(UUID), task(UUID), tools, assets, knowledge, workflow, personalize, search
}
private struct EmployeeWorkspaceRemoval {
    var employeeID: UUID
    var workspaceID: UUID
}
private struct WorkspaceSheetRequest: Identifiable {
    let id = UUID()
    var area: WorkArea?
}
private struct ProjectSheetRequest: Identifiable {
    let id = UUID()
    var project: WorkProject?
}
private struct ServerRequest: Identifiable {
    let id = UUID()
    var server: ComfyServer?
}
private struct TemplateRequest: Identifiable {
    let id = UUID()
    var template: WorkflowTemplate?
}

@MainActor struct WorkbenchView: View {
    @ObservedObject var terminals = TerminalWorkspace()
    var initialSelection: StudioSelection? = nil
    var initialPage: StudioPage = .home
    var initialProjectID: UUID? = nil
    @ObservedObject var store: WorkbenchStore
    @State private var page: StudioPage = .home
    @State private var sheet: SheetKind?
    @State private var selection: StudioSelection?
    @State private var preferredEmployee: UUID?
    @State private var preferredDepartment: String?
    @State private var areaRequest: WorkspaceSheetRequest?
    @State private var consoleHeight: CGFloat = 280
    @State private var viewHeight: CGFloat = 900
    private var compact: Bool { viewHeight < 800 || terminals.isVisible }
    @State private var editingEmployee: Employee?
    @State private var editingTask: WorkTask?
    @State private var employeeSearch = ""
    @State private var memberPickerArea: WorkArea?
    @State private var pendingMemberRemoval: EmployeeWorkspaceRemoval?
    @State private var editingTool: ToolConfig?
    @State private var projectRequest: ProjectSheetRequest?
    @State private var openProjectID: UUID?
    @State private var showCategorySheet = false
    @State private var showNeedCLI = false
    @State private var offerAgentForTool: UUID?
    @State private var preferredTool: UUID?
    @State private var assetCategory = ProjectFilter.Category.all
    @State private var assetProjectID: UUID?
    @State private var assetModuleID: UUID?
    @State private var chatAgents: [UUID] = []
    @State private var chatMode = ChatMode.single
    @State private var directorScope: DirectorScope?
    @State private var chatAccess = AccessLevel.readOnly
    @State private var chatAttachments: [String] = []
    @State private var composerProjectID: UUID?
    @State private var openConversationID: UUID?
    @State private var projectTab = ProjectTab.conversations
    @State private var teamPlanTurn: ChatMessage?
    @State private var serverRequest: ServerRequest?
    @State private var templateRequest: TemplateRequest?
    @State private var manualRunTemplate: WorkflowTemplate?
    @State private var projectsModuleFilter: UUID?
    @State private var projectsCategoryFilter: UUID?
    @State private var searchCategory: UUID?
    @State private var searchModule: UUID?
    @State private var showRemoteToolSheet = false
    @State private var showPlannerSheet = false
    @State private var remoteToolToEdit: ToolConfig?
    @State private var pendingAssignment: (taskID: UUID, employeeID: UUID)?
    @State private var confirmAssignment = false
    @State private var searchText = ""
    @State private var ideaText = ""
    @State private var taskSeed = ""
    @FocusState private var searchFocused: Bool
    @AppStorage(Theme.preferenceKey) private var studioMood = Theme.defaultMood
    @State private var didAppear = false

    private var style: StudioStyle { StudioStyle.from(studioMood) }
    private var pixel: Bool { style.isPixel }
    private var accent: Color { Theme.blue }
    private var reviewTasks: [WorkTask] { store.visibleTasks.filter { $0.status == .review } }

    /// The window content in the current style. Ink and pixel share the dark appearance, so their colors would not
    /// redraw on their own when switching; a new identity per style redraws them.
    private var styledContent: some View {
        studioLayout
            .background { ZStack { Theme.paper; if pixel { PixelGrid() } } }.tint(accent).ignoresSafeArea(.container, edges: .top)
            .background { GeometryReader { geometry in Color.clear.onAppear { viewHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, height in viewHeight = height } } }
            .environment(\.studioStyle, style)
            .id(style)
    }

    private var studioLayout: some View {
        HStack(spacing: 0) {
            StudioSidebar(page: $page, reviewCount: reviewTasks.count, onNavigate: { selection = nil; openProjectID = nil; projectsModuleFilter = nil; projectsCategoryFilter = nil }, onTerminal: showTerminal, onManage: { selection = .manageAreas }, terminalCount: terminals.activeCount)
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ZStack(alignment: .topTrailing) {
                        if page == .home { studioHome(size: proxy.size) } else { destinationPage }
                        if selection != nil {
                            inspector.frame(width: proxy.size.width > 1080 ? 390 : 350).padding(.top, 62).padding(.trailing, 18).padding(.bottom, 12)
                        }
                    }
                }
                if terminals.isVisible {
                    Rectangle().fill(accent.opacity(0.16)).frame(height: 4).overlay { Capsule().fill(accent.opacity(0.45)).frame(width: 45, height: 2) }
                        .gesture(DragGesture().onChanged { value in consoleHeight = min(380, max(210, consoleHeight - value.translation.height / 12)) })
                    TerminalPanel(terminals: terminals, store: store, dark: style.isDark).frame(height: min(consoleHeight, viewHeight < 800 ? 220 : 320))
                } else { composer }
            }
        }
    }

    var body: some View {
        let _ = Theme.activate(style)
        styledContent
        .preferredColorScheme(style.isDark ? .dark : .light)
        .onAppear {
            applyAppearance()
            guard !didAppear else { return }
            didAppear = true
            page = initialPage; if let initialSelection { selection = initialSelection }; if let initialProjectID { openProject(initialProjectID) }
        }
        .onChange(of: studioMood) { _, _ in applyAppearance() }
        .sheet(item: $areaRequest) { request in WorkspaceConfigurationSheet(store: store, areaToEdit: request.area) }
        .alert("终端提示", isPresented: Binding(get: { terminals.error != nil }, set: { if !$0 { terminals.error = nil } })) { Button("知道了") { terminals.error = nil } } message: { Text(terminals.error ?? "") }
        .sheet(item: $sheet) { kind in
            if kind == .tool {
                CLIConfigurationSheet(store: store, toolToEdit: editingTool) { id, isNew in
                    if isNew && !store.snapshot.employees.current.contains(where: { $0.toolID == id }) { offerAgentForTool = id }
                }
            } else {
                ConfigurationSheet(kind: kind, store: store, preferredEmployeeID: preferredEmployee, preferredDepartment: preferredDepartment, preferredToolID: preferredTool, employeeToEdit: editingEmployee, taskToEdit: editingTask, initialTaskInput: taskSeed, onTaskSaved: { id in
                    if !taskSeed.isEmpty && ideaText == taskSeed { ideaText = "" }
                    if let task = store.visibleTasks.first(where: { $0.id == id }) { store.activeProjectID = task.projectID }
                    selection = .task(id)
                }, onRequestCLI: { DispatchQueue.main.async { editingTool = nil; sheet = .tool } })
            }
        }
        .sheet(isPresented: $showCategorySheet) { CategoryManagerSheet(store: store) }
        .alert("还没有添加 CLI", isPresented: $showNeedCLI) {
            Button("添加 CLI") { newConfiguration(.tool) }
            Button("取消", role: .cancel) {}
        } message: { Text("AI 员工需要绑定一个你添加的 CLI。输入栏里的内容会保留。") }
        .alert("找不到 CLI", isPresented: Binding(get: { store.missingCLIToolID != nil }, set: { if !$0 { store.missingCLIToolID = nil } })) {
            Button("修正路径") { if let id = store.missingCLIToolID, let tool = store.tool(id) { editingEmployee = nil; editingTool = tool; sheet = .tool }; store.missingCLIToolID = nil }
            Button("取消", role: .cancel) { store.missingCLIToolID = nil }
        } message: {
            let tool = store.missingCLIToolID.flatMap { store.tool($0) }
            Text("「\(tool?.name ?? "CLI")」的可执行文件已不存在或不能运行：\(tool?.executable ?? "")。修正路径后再试，本次没有开始执行。")
        }
        .alert("为这个 CLI 安排一位 AI 员工？", isPresented: Binding(get: { offerAgentForTool != nil }, set: { if !$0 { offerAgentForTool = nil } })) {
            Button("创建员工") { let id = offerAgentForTool; offerAgentForTool = nil; preferredEmployee = nil; preferredDepartment = nil; editingEmployee = nil; editingTool = nil; preferredTool = id; sheet = .employee }
            Button("稍后", role: .cancel) { offerAgentForTool = nil }
        } message: { Text("员工绑定这个 CLI 后，就可以接收任务。") }
        .sheet(isPresented: $showPlannerSheet) { PlannerConfigurationSheet(store: store) { selection = .task($0) } }
        .sheet(isPresented: $showRemoteToolSheet) { RemoteToolConfigurationSheet(store: store, toolToEdit: remoteToolToEdit) }
        .sheet(item: $projectRequest) { request in ProjectConfigurationSheet(store: store, projectToEdit: request.project) { id in
            if request.project == nil { composerProjectID = id; if page == .projects { openProject(id) } }
        } }
        .sheet(item: $teamPlanTurn) { turn in
            if let draft = turn.planDraft, let conversation = store.conversation(turn.conversationID) {
                if turn.turnKind == .production { ProductionApprovalSheet(store: store, turnID: turn.id, draft: draft) }
                else { PlanApprovalSheet(draft: draft, planningTaskID: nil, projectID: conversation.projectID, store: store, teamMessageID: turn.id, allowedAgentIDs: store.message(turn.replyToID)?.targetIDs) }
            }
        }
        .sheet(item: $serverRequest) { request in ServerSheet(store: store, serverToEdit: request.server) }
        .sheet(item: $templateRequest) { request in TemplateSheet(store: store, templateToEdit: request.template) }
        .sheet(item: $manualRunTemplate) { template in ManualRunSheet(store: store, templateID: template.id) { id in selection = .task(id) } }
        .alert("把草稿交给这位员工？", isPresented: $confirmAssignment) {
            Button("取消", role: .cancel) { pendingAssignment = nil }
            Button("确认分配") { if let assignment = pendingAssignment { store.assignDraft(assignment.taskID, to: assignment.employeeID) }; pendingAssignment = nil }
        } message: { Text("只更新草稿负责人，确认后仍由你发起执行。") }
        .alert("工作台提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .sheet(item: $memberPickerArea) { WorkspaceMemberPicker(store: store, area: $0) }
        .alert("移出当前工作区？", isPresented: Binding(get: { pendingMemberRemoval != nil }, set: { if !$0 { pendingMemberRemoval = nil } })) {
            Button("取消", role: .cancel) { pendingMemberRemoval = nil }
            Button("移出", role: .destructive) { if let item = pendingMemberRemoval { store.removeEmployee(item.employeeID, from: item.workspaceID) }; pendingMemberRemoval = nil }
        } message: { Text("只移除这位员工在当前工作区的成员关系。档案、其他工作区和历史任务都会保留；没有其他工作区时，员工会放入“未分配工作区”。") }
        .modifier(ObjectDeletionModifier(store: store, terminals: terminals, onDeleted: { target in
            selection = nil
            let currentAgentIDs = Set(store.snapshot.employees.current.map(\.id))
            chatAgents.removeAll { !currentAgentIDs.contains($0) }
            if target.kind == .project && openProjectID == target.objectID { openProjectID = nil; openConversationID = nil }
            if target.kind == .conversation && openConversationID == target.objectID { openConversationID = nil }
            if store.project(composerProjectID)?.isDeleted == true { composerProjectID = store.activeProjects.first?.id }
        }))
        .onExitCommand { selection = nil }
    }

    private func studioHome(size: CGSize) -> some View {
        let heroHeight: CGFloat = terminals.isVisible ? 205 : min(286, max(210, viewHeight - 680))
        let cardHeight: CGFloat = min(306, max(274, (viewHeight - heroHeight - 135) / 2))
        return ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    StudioHero(height: heroHeight, width: size.width)
                    if !store.hasCLI && store.storageAvailable { addCLIBanner.padding(.horizontal, 22).padding(.bottom, 14) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 19), GridItem(.flexible(), spacing: 19)], spacing: 18) {
                        ForEach(store.workspaces) { area in
                            StudioWorkspaceCard(area: area, members: store.employees(in: area), tasks: store.tasks(in: area), height: cardHeight, available: store.storageAvailable,
                                onOpen: { selection = .workspace(area.id) },
                                onEdit: { areaRequest = WorkspaceSheetRequest(area: area) },
                                onEmployee: { selection = .employee($0.id) },
                                onAddEmployee: { addEmployee(to: area) },
                                onTask: { selection = .task($0.id) },
                                onNewTask: { newTask(employee: store.employees(in: area).first(where: { $0.enabled != false })?.id) },
                                onAssign: { taskID, employeeID in
                                    guard store.visibleTasks.contains(where: { $0.id == taskID && $0.status == .draft }) else { return false }
                                    pendingAssignment = (taskID, employeeID); confirmAssignment = true; return true
                                }, projectCount: store.projectCount(moduleID: area.id),
                                onProjects: { projectsModuleFilter = area.id; openProjectID = nil; selection = nil; page = .projects },
                                onEditEmployee: editEmployee, onRemoveEmployee: { pendingMemberRemoval = EmployeeWorkspaceRemoval(employeeID: $0.id, workspaceID: area.id) },
                                onDeleteEmployee: { store.pendingDeletion = DeletionTarget(.employee, $0.id) },
                                onDeleteWorkspace: { store.pendingDeletion = DeletionTarget(.workspace, area.id) },
                                onAddExistingEmployee: { memberPickerArea = area }).id(area.id)
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 8)
                    HStack {
                        Text("所有项目 · \(store.workspaces.count) 个工作区").foregroundStyle(.secondary)
                        Spacer()
                        Button { areaRequest = WorkspaceSheetRequest(area: nil) } label: { Label("添加工作区", systemImage: "plus") }.disabled(!store.storageAvailable)
                    }.font(.system(size: 10)).buttonStyle(.plainPointer).padding(.horizontal, 28).padding(.top, 9).padding(.bottom, 4)
                }
            }.onChange(of: store.workspaces.count) { _, _ in
                if let id = store.workspaces.last?.id { withAnimation { reader.scrollTo(id, anchor: .bottom) } }
            }
        }.overlay(alignment: .topTrailing) { headerControls.padding(.horizontal, 25).padding(.top, 12) }
            .accessibilityIdentifier("studio.page.home")
    }

    private var addCLIBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 16)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("还没有添加 CLI").font(.system(size: 12, weight: .semibold))
                Text("工作台不内置任何 CLI。手动添加 Claude Code、Codex 或其他 CLI 后，就能安排 AI 员工。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("添加 CLI") { newConfiguration(.tool) }.buttonStyle(StudioPrimaryButtonStyle()).accessibilityIdentifier("home.add-cli")
        }.padding(.horizontal, 18).padding(.vertical, 12).background(Theme.surface.opacity(0.9), in: StudioShape(14, pixel: pixel)).overlay(StudioShape(14, pixel: pixel).stroke(pixel ? Theme.border : accent.opacity(0.18), lineWidth: pixel ? 2 : 1))
    }

    private var headerFill: Color { Theme.adaptive(NSColor.white.withAlphaComponent(0.65), NSColor(srgbRed: 0.11, green: 0.157, blue: 0.212, alpha: 0.92), pixel: NSColor(srgbRed: 0.059, green: 0.078, blue: 0.2, alpha: 0.94)) }
    private var headerStroke: Color { Theme.adaptive("FFFFFF", "2B3746", pixel: "2A3672") }

    private var headerControls: some View {
        HStack(spacing: 17) {
            Spacer(minLength: 0)
            Button { selection = .search } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text("搜索项目、员工、任务…")
                    Spacer()
                    Text("⌘ K").font(.system(size: 10))
                }.font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 14).frame(width: 300, height: 35).background(headerFill, in: StudioShape(17.5, pixel: pixel)).overlay(StudioShape(17.5, pixel: pixel).stroke(headerStroke, lineWidth: pixel ? 2 : 1))
            }.buttonStyle(.plainPointer).keyboardShortcut("k", modifiers: .command)
            Button { if let task = reviewTasks.first { selection = .task(task.id) } else { page = .projects; selection = nil } } label: {
                Image(systemName: "bell").font(.system(size: 17)).foregroundStyle(Theme.adaptive("233A4F", "E6EDF4")).frame(width: 35, height: 35).background(headerFill, in: StudioShape(17.5, pixel: pixel)).overlay(StudioShape(17.5, pixel: pixel).stroke(headerStroke, lineWidth: pixel ? 2 : 1))
                    .overlay(alignment: .topTrailing) { if !reviewTasks.isEmpty { Circle().fill(.orange).frame(width: 7, height: 7).padding(3) } }
            }.buttonStyle(.plainPointer).help("\(reviewTasks.count) 项待验收").accessibilityLabel("待验收任务：\(reviewTasks.count)")
            Button { page = .settings; selection = nil } label: {
                if pixel {
                    Image(systemName: "person.fill").font(.system(size: 16)).foregroundStyle(Theme.primaryText).frame(width: 35, height: 35)
                        .background(Theme.raised, in: StudioShape(17.5, pixel: true)).overlay(StudioShape(17.5, pixel: true).stroke(Theme.blue, lineWidth: 2))
                } else {
                    Image(systemName: "person.crop.circle.fill").symbolRenderingMode(.palette).foregroundStyle(Theme.adaptive("335E50", "1C2836"), Theme.adaptive(NSColor.white.withAlphaComponent(0.9), NSColor(srgbRed: 0.93, green: 0.95, blue: 0.97, alpha: 1))).font(.system(size: 34))
                }
            }.buttonStyle(.plainPointer).help("工作室设置").accessibilityLabel("工作室设置")
        }.frame(height: 36)
    }

    private var destinationPage: some View {
        VStack(spacing: 0) {
            headerControls.padding(.horizontal, 28).padding(.top, 12)
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.title).font(.system(size: 31, weight: .bold))
                    Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                if page == .employees {
                    Button { store.snapshot.tools.current.isEmpty ? newConfiguration(.tool) : newConfiguration(.employee) } label: { Label("添加员工", systemImage: "plus") }
                        .buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                }
                if page == .projects && openProjectID == nil {
                    Button("管理分类") { showCategorySheet = true }.buttonStyle(.borderedPointer).disabled(!store.storageAvailable)
                    Button { projectRequest = ProjectSheetRequest(project: nil) } label: { Label("添加项目", systemImage: "plus") }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                }
                if page == .workflow || page == .knowledge {
                    Picker("当前项目", selection: $store.activeProjectID) {
                        Text("未归属项目").tag(Optional<UUID>.none)
                        ForEach(store.snapshot.projects.current.filter { !$0.isArchived || $0.id == store.activeProjectID }) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 270)
                }
            }.padding(.horizontal, 34).padding(.top, 32).padding(.bottom, 27)
            if page == .projects && store.project(openProjectID) != nil { projectWorkspace }
            else { ScrollView {
                Group {
                    if page == .employees { employeeDirectory }
                    else if page == .projects && openProjectID == nil {
                        AllProjectsView(store: store, accent: accent, onOpen: openProject, onEdit: { projectRequest = ProjectSheetRequest(project: $0) }, onTask: { selection = .task($0) }, initialModuleID: projectsModuleFilter, initialCategoryID: projectsCategoryFilter)
                            .id((projectsModuleFilter?.uuidString ?? "") + "|" + (projectsCategoryFilter?.uuidString ?? ""))
                    } else {
                        inspectorContent(for: pageSelection).frame(maxWidth: .infinity, alignment: .leading).padding(28)
                            .background(Theme.surface.opacity(0.92), in: StudioShape(20, pixel: pixel))
                            .overlay(StudioShape(20, pixel: pixel).stroke(pixel ? Theme.border : Theme.blue.opacity(0.08), lineWidth: pixel ? 2 : 1))
                    }
                }.padding(.horizontal, 34).padding(.bottom, 24)
            } }
        }.accessibilityIdentifier("studio.page." + page.rawValue)
    }

    /// One project: header, tabs, and the conversation layout that scrolls on its own.
    private var projectWorkspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            projectHeader
            Picker("项目内容", selection: $projectTab) { ForEach(ProjectTab.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 320)
                .accessibilityIdentifier("project.tabs")
            switch projectTab {
            case .conversations:
                HStack(alignment: .top, spacing: 0) {
                    if let id = openProjectID { ConversationListView(store: store, projectID: id, selection: $openConversationID, accent: accent) }
                    Divider()
                    if let conversationID = openConversationID, store.conversation(conversationID)?.projectID == openProjectID {
                        ConversationView(store: store, conversationID: conversationID, accent: accent, onContinueInTerminal: continueInTerminal, onOpenTask: { selection = .task($0) }, onReviewPlan: { teamPlanTurn = $0 })
                            .padding(.leading, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("开始一个新对话").font(.system(size: 18, weight: .semibold))
                            Text("在下方输入栏点 @ 选择一位或几位 AI 员工，写下要做的事并发送。一位员工时直接回复；几位员工时可以并行比较，或选“团队”让负责人先拆解计划。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            if store.snapshot.employees.current.isEmpty { Button("添加 AI 员工") { store.hasCLI ? newConfiguration(.employee) : (showNeedCLI = true) }.buttonStyle(StudioPrimaryButtonStyle()) }
                        }.padding(.leading, 24).padding(.top, 8).frame(maxWidth: 520, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                }.frame(maxHeight: .infinity, alignment: .top)
            case .tasks:
                ScrollView { inspectorContent(for: .project).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }
            case .plans:
                ScrollView { workflowContent.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }
            case .assets:
                ScrollView { ArtifactList(store: store).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6) }
            }
        }.padding(.horizontal, 34).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func importCLI() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if let id = store.importDefinition(data), let tool = store.tool(id) { editingEmployee = nil; editingTool = tool; sheet = .tool }
    }
    private func exportCLI(_ tool: ToolConfig) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = tool.name + ".cli.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportedDefinition(tool.id).write(to: url, options: .atomic) } catch { store.errorMessage = "导出失败：\(error.localizedDescription)" }
    }
    /// Every window, sheet, alert and file dialog follows the chosen theme, not just this view.
    @ViewBuilder private func styleSwatch(_ option: StudioStyle) -> some View {
        switch option {
        case .ink: Circle().fill(Color(hex: "0B1826")).overlay(Circle().stroke(Color(hex: "4DB293"), lineWidth: 2))
        case .paper: Circle().fill(Color(hex: "B2D7F0"))
        case .pixel:
            // Four workspace colors as 2×2 pixel blocks on the indigo canvas.
            VStack(spacing: 2) {
                HStack(spacing: 2) { Rectangle().fill(Color(hex: "FF9A1F")); Rectangle().fill(Color(hex: "A66BFF")) }
                HStack(spacing: 2) { Rectangle().fill(Color(hex: "29ADFF")); Rectangle().fill(Color(hex: "2BD46F")) }
            }.padding(6).background(Color(hex: "080B1E"), in: StudioShape(10, pixel: true)).overlay(StudioShape(10, pixel: true).stroke(Color(hex: "2A3672"), lineWidth: 2))
        }
    }
    private func applyAppearance() { style.applyAppearance() }
    private func openProject(_ id: UUID) {
        store.activeProjectID = id; openProjectID = id; selection = nil
        openConversationID = store.conversations(in: id).first?.id
    }
    private func continueInTerminal(_ turn: ChatMessage) {
        guard let agentID = turn.agentID, let agent = store.employee(agentID), let tool = store.tool(agent.toolID), let session = store.session(for: turn),
              let project = store.conversation(turn.conversationID).flatMap({ store.project($0.projectID) }) else { return }
        guard tool.executableAvailable else { store.missingCLIToolID = tool.id; return }
        terminals.open(employee: agent, tool: tool, directory: project.directory, environment: store.environment(for: tool), command: tool.terminalResumeArguments(sessionID: session.nativeID))
    }
    @ViewBuilder private var projectHeader: some View {
        if let project = store.project(openProjectID) {
            VStack(alignment: .leading, spacing: 12) {
                Button { openProjectID = nil } label: { Label("所有项目", systemImage: "chevron.left") }.buttonStyle(.linkPointer).accessibilityIdentifier("projects.back")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(project.name).font(.system(size: 23, weight: .semibold))
                    let category = store.category(store.snapshot.categoryID(of: project))
                    Label(category?.name ?? ProjectCategory.uncategorizedName, systemImage: category?.icon ?? "tray").font(.system(size: 11)).foregroundStyle(category.map { Color(hex: $0.color) } ?? .secondary)
                    if project.isArchived { Text("已归档 · 只能查看").font(.system(size: 11)).foregroundStyle(.orange) }
                    Spacer()
                    Button("编辑项目") { projectRequest = ProjectSheetRequest(project: project) }.buttonStyle(.borderedPointer)
                    Button("删除项目", role: .destructive) { store.pendingDeletion = DeletionTarget(.project, project.id) }.buttonStyle(.borderedPointer)
                    Button(project.isArchived ? "取消归档" : "归档") { store.setProjectArchived(project.id, !project.isArchived) }.buttonStyle(.borderedPointer)
                }
                HStack(spacing: 8) {
                    ForEach(store.snapshot.modules(of: project), id: \.self) { id in
                        if let area = store.workspaces.first(where: { $0.id == id }) { Label(area.name, systemImage: area.icon).font(.system(size: 10)).foregroundStyle(StudioArtwork.tint(for: area)) }
                    }
                    Text(project.directory).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let usage = store.usageTotal({ $0.projectID == project.id }) { Text("用量 " + WorkbenchStore.describe(usage)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Divider()
            }
        }
    }

    private var pageSelection: StudioSelection {
        switch page {
        case .tools: .tools
        case .assets: .assets
        case .knowledge: .knowledge
        case .workflow: .workflow
        case .settings: .personalize
        default: .project
        }
    }

    private var employeeDirectory: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                StudioSearchField(prompt: "搜索员工姓名、职位或职责", text: $employeeSearch).frame(maxWidth: 360)
                Spacer()
                Button("新增 AI 员工") { newConfiguration(.employee) }.buttonStyle(.borderedPointer).disabled(!store.hasCLI || !store.storageAvailable)
            }
            ForEach(store.workspaces) { area in
                employeeGroup(title: area.name, area: area, members: store.employees(in: area))
            }
            if !store.unassignedEmployees.isEmpty || store.workspaces.isEmpty {
                employeeGroup(title: "未分配工作区", area: nil, members: store.unassignedEmployees)
            }
        }
    }
    private func employeeGroup(title: String, area: WorkArea?, members: [Employee]) -> some View {
        let tint = area.map(StudioArtwork.accent(for:)) ?? accent
        let filtered = members.filter { employeeSearch.isEmpty || ($0.name + $0.role + $0.instructions).localizedCaseInsensitiveContains(employeeSearch) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: area?.icon ?? "person.crop.square").font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                Text("\(members.count) 位员工").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if let area {
                    Menu("添加员工") {
                        Button("新增员工") { addEmployee(to: area) }
                        Button("添加已有员工") { memberPickerArea = area }
                    }.disabled(!store.storageAvailable)
                }
            }
            if filtered.isEmpty { Text(employeeSearch.isEmpty ? "还没有员工，可以添加一位伙伴。" : "没有匹配的员工。").font(.system(size: 12)).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                ForEach(filtered) { employee in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { selection = .employee(employee.id) } label: {
                            HStack(spacing: 12) {
                                EmployeePortrait(symbol: employee.avatarSymbol, imageData: employee.avatarImageData, fallback: String(employee.name.prefix(1)), tint: tint).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(employee.name).font(.system(size: 15, weight: .semibold))
                                    Text(employee.role).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(store.tool(employee.toolID)?.name ?? "CLI 未配置").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 11))
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plainPointer)
                        HStack(spacing: 12) {
                            Button("编辑") { editEmployee(employee) }
                            if let area { Button("移出工作区") { pendingMemberRemoval = EmployeeWorkspaceRemoval(employeeID: employee.id, workspaceID: area.id) } }
                            Spacer(minLength: 0)
                            Button("删除", role: .destructive) { store.pendingDeletion = DeletionTarget(.employee, employee.id) }
                        }.font(.system(size: 11)).buttonStyle(.linkPointer).disabled(!store.storageAvailable)
                    }.padding(18).background(Theme.surface, in: StudioShape(14, pixel: pixel))
                        .overlay(StudioShape(14, pixel: pixel).stroke(pixel ? tint.opacity(0.55) : tint.opacity(0.15), lineWidth: pixel ? 2 : 1))
                        .contextMenu { employeeActionButtons(employee, workspaceID: area?.id) }
                        .accessibilityIdentifier("employees.card." + employee.id.uuidString)
                }
            }
        }
    }
    private func editEmployee(_ employee: Employee) {
        editingEmployee = employee; editingTask = nil; preferredEmployee = nil; preferredDepartment = nil; preferredTool = nil; sheet = .employee
    }
    @ViewBuilder private func employeeActionButtons(_ employee: Employee, workspaceID: UUID?) -> some View {
        Button("查看员工档案") { selection = .employee(employee.id) }
        Button("编辑员工") { editEmployee(employee) }
        if let workspaceID { Button("移出当前工作区") { pendingMemberRemoval = EmployeeWorkspaceRemoval(employeeID: employee.id, workspaceID: workspaceID) } }
        Divider()
        Button("删除员工", role: .destructive) { store.pendingDeletion = DeletionTarget(.employee, employee.id) }
    }

    private var composerConversationTitle: String? {
        guard page == .projects, openProjectID != nil, projectTab == .conversations else { return nil }
        return store.conversation(openConversationID)?.title
    }
    private var composer: some View {
        ChatComposerView(store: store, accent: accent, text: $ideaText, agentIDs: $chatAgents, mode: $chatMode, access: $chatAccess, attachments: $chatAttachments,
                         projectID: $composerProjectID, lockedProjectID: page == .projects ? openProjectID : nil, conversationTitle: composerConversationTitle,
                         onSend: sendChat, onAttach: chooseReferenceFiles, onNewTask: composeTask, onPlanner: { showPlannerSheet = true },
                         onAddWorkspace: { areaRequest = WorkspaceSheetRequest(area: nil) }, onTerminal: showTerminal,
                         onNewProject: { projectRequest = ProjectSheetRequest(project: nil) },
                         onNewConversation: { openConversationID = nil; if page == .projects, openProjectID != nil { projectTab = .conversations } }, directorScope: $directorScope)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) {
                Text("ONE PERSON   ×   AI TEAM").font(.system(size: 8)).tracking(1.5).foregroundStyle(.secondary.opacity(0.7)).padding(.trailing, 29).padding(.bottom, 4)
            }
            .onAppear { if composerProjectID == nil { composerProjectID = store.currentProject?.isArchived == false ? store.activeProjectID : store.activeProjects.first?.id } }
    }

    /// Sends the input bar to the chosen agents: into the open conversation, or a new one in the target project.
    private func sendChat() {
        let text = ideaText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !chatAttachments.isEmpty), store.storageAvailable else { return }
        guard store.hasCLI else { showNeedCLI = true; return }
        let enabled = store.snapshot.employees.current.filter { $0.enabled != false && store.tool($0.toolID)?.isCLI == true }
        guard !enabled.isEmpty else {
            page = .employees; selection = nil
            store.errorMessage = "先添加一位绑定 CLI 的 AI 员工，再发送。输入会保留。"
            return
        }
        for agent in enabled where text.contains("@" + agent.name) && !chatAgents.contains(agent.id) { chatAgents.append(agent.id) }
        if chatAgents.isEmpty && enabled.count == 1 { chatAgents = [enabled[0].id] }
        guard !chatAgents.isEmpty else { store.errorMessage = "先点输入栏里的 @ 选择员工，或在消息里写 @名字。输入会保留。"; return }
        if chatAgents.count == 1 && chatMode != .director { chatMode = .single } else if chatAgents.count > 1 && (chatMode == .single || chatMode == .director) { chatMode = .parallel }
        let inProject = page == .projects && openProjectID != nil
        guard let projectID = inProject ? openProjectID : (store.project(composerProjectID)?.isArchived == false ? composerProjectID : nil) else {
            store.errorMessage = "先在输入栏左上角选择一个项目，或新建项目。输入会保留。"; return
        }
        let conversationID = inProject && projectTab == .conversations ? openConversationID : nil
        guard let id = store.sendMessage(text, attachments: chatAttachments, projectID: projectID, conversationID: conversationID, agentIDs: chatAgents, mode: chatMode, access: chatAccess, directorScope: chatMode == .director ? directorScope : nil) else { return }
        ideaText = ""; chatAttachments = []
        page = .projects; selection = nil
        if openProjectID != projectID { openProject(projectID) }
        projectTab = .conversations; openConversationID = id
    }

    private func composeTask() {
        guard !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.storageAvailable else { return }
        guard store.hasCLI else { showNeedCLI = true; return }
        guard store.snapshot.employees.current.contains(where: { $0.enabled != false }) else {
            page = .employees; selection = nil
            store.errorMessage = "先添加一位启用的 AI 员工，再把想法交给它。输入会保留。"
            return
        }
        newTask(input: ideaText + (chatAttachments.isEmpty ? "" : "\n\n参考文件：\n" + chatAttachments.joined(separator: "\n")))
    }
    private func chooseReferenceFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        if panel.runModal() == .OK { for url in panel.urls where !chatAttachments.contains(url.path) { chatAttachments.append(url.path) } }
    }
    private func showTerminal() { if terminals.selected != nil { terminals.isVisible = true } else { openTerminal(nil) } }
    private func addEmployee(to area: WorkArea) {
        preferredDepartment = area.name; preferredEmployee = nil; editingEmployee = nil; editingTask = nil; editingTool = nil; preferredTool = nil
        if store.snapshot.tools.current.isEmpty { showNeedCLI = true }
        else { sheet = .employee }
    }
    private func loginTint(_ state: LoginState) -> Color { state == .loggedIn ? accent : (state == .loggedOut || state == .failed ? .orange : .gray) }
    private func openTerminal(_ employee: Employee?, login: Bool = false) {
        let tool = employee.flatMap { store.tool($0.toolID) }
        terminals.open(employee: employee, tool: tool, directory: store.currentProject?.directory ?? FileManager.default.homeDirectoryForCurrentUser.path, login: login, environment: tool.map { store.environment(for: $0) } ?? [:], onLoginEnd: { if let tool { store.checkLogin(tool.id) } })
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text(inspectorTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { selection = nil } label: { Image(systemName: "xmark").padding(7) }.buttonStyle(.plainPointer).help("收起对象详情").accessibilityLabel("收起对象详情")
            }.padding(.horizontal, 21).padding(.vertical, 15)
            Divider()
            ScrollView {
                inspectorContent(for: selection).padding(21).frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .employee(let id) = selection, let employee = store.employee(id) {
                let task = store.visibleTasks.first { $0.employeeID == id && $0.projectID == store.activeProjectID && $0.status != .completed }
                Divider()
                Button {
                    if let task { selection = .task(task.id) } else { newTask(employee: id) }
                } label: { Text(task == nil ? "交给这位员工" : "审阅并执行任务 ↗").frame(maxWidth: .infinity) }
                    .buttonStyle(StudioPrimaryButtonStyle()).padding(12)
                    .disabled(task == nil && (!store.storageAvailable || employee.enabled == false))
            }
        }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.2))).shadow(color: .black.opacity(0.13), radius: 25, x: -6, y: 8)
    }
    private var inspectorTitle: String {
        switch selection {
        case .task: return "任务详情 · 本地执行"
        case .employee: return "员工档案"
        case .workspace: return "工作区成员"
        case .manageAreas: return "管理工作区"
        case .tools: return "工具架"
        case .assets: return "素材盒"
        case .knowledge: return "项目知识"
        case .workflow: return "协作工作流"
        case .personalize: return "布置工作室"
        case .search: return "找到工作室里的对象"
        default: return "项目桌"
        }
    }
    @ViewBuilder private func inspectorContent(for destination: StudioSelection?) -> some View {
        switch destination {
        case .task(let id):
            if let task = store.visibleTasks.first(where: { $0.id == id }) { TaskDetail(task: task, store: store, onDraftArchived: { selection = .project }, onEdit: { editingEmployee = nil; editingTool = nil; taskSeed = ""; editingTask = task; sheet = .task }) }
        case .employee(let id):
            if let employee = store.employee(id) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 13) {
                        EmployeePortrait(symbol: employee.avatarSymbol, imageData: employee.avatarImageData, fallback: String(employee.name.prefix(1)), tint: accent).frame(width: 42, height: 42)
                        Text(employee.name).font(.system(size: 25, weight: .medium))
                    }
                    Text("\(employee.role) · \(employee.department)").font(.system(size: 12)).foregroundStyle(.secondary)
                    if let tool = store.tool(employee.toolID) {
                        let check = store.loginCheck(for: tool)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Label(tool.name, systemImage: "terminal"); Spacer(); Text(tool.isCLI && !tool.executableAvailable ? "CLI 缺失" : check.state.title).foregroundStyle(tool.isCLI && !tool.executableAvailable ? .orange : loginTint(check.state)) }.font(.system(size: 11))
                            if tool.isCLI && !tool.executableAvailable { Button("修正 CLI 路径") { editingEmployee = nil; editingTool = tool; sheet = .tool }.font(.system(size: 11)) }
                            Text("最高权限：" + (tool.managesAccess ? (employee.maxAccess ?? .readOnly).title : "未由工作台管理") + (employee.model.map { $0.isEmpty ? "" : " · 模型 " + $0 } ?? "")).font(.system(size: 10)).foregroundStyle(.secondary)
                            if let date = check.checkedAt { Text("最近检测：" + date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                            Text("共用此 CLI 配置的员工共享登录状态。").font(.system(size: 10)).foregroundStyle(.secondary)
                            HStack {
                                Button("检测登录") { store.checkLogin(tool.id) }.disabled(check.state == .checking || tool.authenticationStatusArguments == nil)
                                Button("打开终端") { openTerminal(employee) }.disabled(!tool.isCLI || !tool.executableAvailable)
                            }.buttonStyle(.borderedPointer).font(.system(size: 11))
                            if tool.authenticationLoginArguments != nil { Button("在终端登录账号") { openTerminal(employee, login: true) }.font(.system(size: 11)) }
                            if check.state == .failed { Text(check.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled) }
                        }.padding(13).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let task = store.visibleTasks.first(where: { $0.employeeID == id && $0.projectID == store.activeProjectID && $0.status != .completed }) {
                        HStack { Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(1); Spacer(); StatusBadge(status: task.status) }
                    }
                    DisclosureGroup("职责说明") { Text(employee.instructions.isEmpty ? "尚未填写职责说明。" : employee.instructions).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled) }.font(.system(size: 11))
                    Button("编辑员工档案") { editEmployee(employee) }.buttonStyle(.borderedPointer).disabled(!store.storageAvailable)
                    Button(employee.enabled == false ? "启用员工" : "停用员工") { var updated = employee; updated.enabled = !(employee.enabled ?? true); store.updateEmployee(updated) }.buttonStyle(.borderedPointer)
                    Button("删除员工", role: .destructive) { store.pendingDeletion = DeletionTarget(.employee, employee.id) }.buttonStyle(.borderedPointer)
                    Divider()
                    Text("桌上的任务").font(.system(size: 11, weight: .medium))
                    taskRows(store.visibleTasks.filter { $0.employeeID == id })
                }
            }
        case .workspace(let id):
            if let area = store.workspaces.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 18) {
                    Label(area.name, systemImage: area.icon).font(.system(size: 23, weight: .medium)).foregroundStyle(Color(hex: area.color))
                    Text(area.description).font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(store.employees(in: area)) { employee in employeeRow(employee, workspaceID: area.id) }
                    Button("新增员工") { addEmployee(to: area) }
                    Button("添加已有员工") { memberPickerArea = area }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                    Button("编辑工作区") { areaRequest = WorkspaceSheetRequest(area: area) }.buttonStyle(.borderedPointer)
                    Button("删除工作区", role: .destructive) { store.pendingDeletion = DeletionTarget(.workspace, area.id) }.buttonStyle(.borderedPointer)
                    Divider(); taskRows(store.tasks(in: area))
                }
            }
        case .manageAreas:
            VStack(alignment: .leading, spacing: 18) {
                Text("为伙伴留出空间").font(.system(size: 23, weight: .medium))
                Text("每个工作区可配置多位员工。改名与配色会保留原有任务和员工关系。").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(store.workspaces) { area in
                    HStack {
                        Button { areaRequest = WorkspaceSheetRequest(area: area) } label: {
                            Label(area.name, systemImage: area.icon).foregroundStyle(Color(hex: area.color))
                        }.buttonStyle(.plainPointer)
                        Spacer()
                        Text("\(store.employees(in: area).count) 人").foregroundStyle(.secondary)
                        Button("编辑") { areaRequest = WorkspaceSheetRequest(area: area) }
                        Button("删除", role: .destructive) { store.pendingDeletion = DeletionTarget(.workspace, area.id) }
                    }.font(.system(size: 12)).padding(.vertical, 8)
                }
                Button("添加工作区") { areaRequest = WorkspaceSheetRequest(area: nil) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
            }
        case .tools:
            ToolShelfView(store: store, accent: accent, onAddCLI: { newConfiguration(.tool) }, onEditCLI: { tool in editingEmployee = nil; editingTool = tool; sheet = .tool },
                          onAddRemote: { remoteToolToEdit = nil; showRemoteToolSheet = true }, onEditRemote: { remoteToolToEdit = $0; showRemoteToolSheet = true },
                          onAddEmployee: { newConfiguration(.employee) }, onLogin: { tool in
                terminals.open(employee: nil, tool: tool, directory: FileManager.default.homeDirectoryForCurrentUser.path, login: true, environment: store.environment(for: tool), onLoginEnd: { store.checkLogin(tool.id) })
            }, onAddServer: { serverRequest = ServerRequest(server: nil) }, onEditServer: { serverRequest = ServerRequest(server: $0) },
               onAddTemplate: { templateRequest = TemplateRequest(template: nil) }, onEditTemplate: { templateRequest = TemplateRequest(template: $0) },
               onRunTemplate: { manualRunTemplate = $0 }, onImportCLI: importCLI, onExportCLI: exportCLI)
        case .assets:
            VStack(alignment: .leading, spacing: 19) {
                Text("留下工作的痕迹").font(.system(size: 23, weight: .medium))
                Text("所有项目的产物都保留来源执行、文件大小和验收记录。按分类、项目或工作区筛选；预览后，可从任务详情交给下一位员工。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                HStack(spacing: 10) {
                    Picker("分类", selection: $assetCategory) {
                        Text("全部分类").tag(ProjectFilter.Category.all)
                        ForEach(store.snapshot.sortedCategories) { Text($0.name).tag(ProjectFilter.Category.id($0.id)) }
                        Text(ProjectCategory.uncategorizedName).tag(ProjectFilter.Category.uncategorized)
                    }.frame(maxWidth: 190)
                    Picker("项目", selection: $assetProjectID) {
                        Text("全部项目").tag(Optional<UUID>.none)
                        ForEach(store.snapshot.projects.current) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 220)
                    Picker("工作区", selection: $assetModuleID) {
                        Text("全部工作区").tag(Optional<UUID>.none)
                        ForEach(store.workspaces) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 190)
                }.font(.system(size: 11)).accessibilityIdentifier("assets.filters")
                ArtifactList(store: store, filter: assetMatches)
            }
        case .knowledge:
            knowledgeContent
        case .workflow:
            workflowContent
        case .personalize:
            VStack(alignment: .leading, spacing: 22) {
                Text("工作室，也有\n你的性格。").font(.system(size: 24, weight: .medium))
                Picker("同时执行", selection: $store.concurrencyLimit) { Text("1 个任务").tag(1); Text("2 个任务").tag(2) }.onChange(of: store.concurrencyLimit) { _, _ in store.schedulePending() }
                Text("默认使用深色。你也可以改用像素风格或浅色，设置会在下次启动时保留，不随系统外观变化。").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(StudioStyle.allCases) { option in
                    Button { studioMood = option.rawValue } label: {
                        HStack {
                            styleSwatch(option).frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(option.title).font(.system(size: 13))
                                Text(option.subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if style == option { Image(systemName: "checkmark") }
                        }.padding(14).background(accent.opacity(0.06), in: StudioShape(12, pixel: pixel))
                            .overlay(StudioShape(12, pixel: pixel).stroke(accent.opacity(style == option ? 0.6 : 0.2), lineWidth: pixel ? 2 : 1))
                    }.buttonStyle(.plainPointer).accessibilityIdentifier("settings.style." + option.rawValue)
                }
                Divider()
                Button("管理工作区") { selection = .manageAreas }.buttonStyle(.borderedPointer)
                Button("添加工作区") { areaRequest = WorkspaceSheetRequest(area: nil) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                Text("员工、项目、任务和工作记录存储在本机。CLI 与远程制作服务使用各自的连接配置。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .search:
            searchContent
        default:
            VStack(alignment: .leading, spacing: 18) {
                if page == .projects && openProjectID != nil { EmptyView() }
                else {
                    Picker("项目桌", selection: $store.activeProjectID) {
                        Text("未归属项目").tag(Optional<UUID>.none)
                        ForEach(store.snapshot.projects.current.filter { !$0.isArchived || $0.id == store.activeProjectID }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("添加项目") { projectRequest = ProjectSheetRequest(project: nil) }.buttonStyle(.borderedPointer)
                }
                Button("让AI安排协作") { showPlannerSheet = true }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.currentProject?.isArchived != false || store.planningCandidates.isEmpty)
                CollaborationPanel(store: store) { selection = .task($0) }
                ForEach(store.snapshot.handoffs.filter { $0.projectID == store.activeProjectID }) { handoff in
                    if let target = handoff.targetTaskID {
                        Button { selection = .task(target) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("交接 → " + (store.employee(handoff.targetEmployeeID)?.name ?? "未知员工"))
                                Text(handoff.goal).foregroundStyle(.secondary)
                                Text("来源 run \(handoff.sourceRunID.uuidString.prefix(8))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            }.font(.system(size: 11))
                        }.buttonStyle(.plainPointer).disabled(!store.visibleTasks.contains(where: { $0.id == target }))
                    }
                }
                if let project = store.currentProject { Text(project.goal).font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("项目里的每一个想法").font(.system(size: 23, weight: .medium))
                Button("放一个新想法") { newTask() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.snapshot.employees.current.isEmpty || !store.storageAvailable || store.currentProject?.isArchived == true)
                taskRows(store.visibleTasks.filter { $0.projectID == store.activeProjectID })
                if !store.archivedDrafts.filter({ $0.projectID == store.activeProjectID }).isEmpty {
                    DisclosureGroup("已移出草稿") {
                        ForEach(store.archivedDrafts.filter { $0.projectID == store.activeProjectID }) { draft in
                            HStack { Text(draft.title); Spacer(); Button("恢复") { store.restoreDraft(draft.id) }.accessibilityLabel("恢复草稿：" + draft.title) }.font(.system(size: 11)).padding(.vertical, 6)
                        }
                    }
                }
            }
        }
    }
    private func assetMatches(_ artifact: WorkArtifact) -> Bool {
        if let assetProjectID, artifact.projectID != assetProjectID { return false }
        let project = store.project(artifact.projectID)
        switch assetCategory {
        case .all: break
        case .uncategorized: if let project, store.snapshot.categoryID(of: project) != nil { return false }
        case .id(let id): guard let project, store.snapshot.categoryID(of: project) == id else { return false }
        }
        if let assetModuleID, store.snapshot.moduleID(of: artifact) != assetModuleID { return false }
        return true
    }
    private var knowledgeContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            Label("项目目标", systemImage: "scope").font(.system(size: 16, weight: .semibold))
            Text(store.currentProject?.goal ?? "在项目任务中创建项目，给伙伴一个明确的共同目标。").font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            Label("员工职责", systemImage: "person.text.rectangle").font(.system(size: 16, weight: .semibold))
            Text("汇集工作室中已配置的职责说明。点击员工即可编辑。").font(.system(size: 12)).foregroundStyle(.secondary)
            if store.snapshot.employees.current.isEmpty { Text("添加员工后，它的职责说明会出现在这里。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(store.snapshot.employees.current) { employee in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(employee.instructions.isEmpty ? "尚未填写职责说明。" : employee.instructions).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                        Button("查看与编辑员工") { selection = .employee(employee.id) }.buttonStyle(.borderedPointer)
                    }.padding(.vertical, 12)
                } label: { Text(employee.name + " · " + employee.role).font(.system(size: 13, weight: .medium)) }
            }
            Divider()
            Label("已验收经验", systemImage: "checkmark.seal").font(.system(size: 16, weight: .semibold))
            Text("当前项目已验收任务的输入、标准与产物保留在来源任务中，可查看后继续交接。").font(.system(size: 12)).foregroundStyle(.secondary)
            let accepted = store.visibleTasks.filter { $0.projectID == store.activeProjectID && $0.status == .completed }
            if accepted.isEmpty { Text("还没有已验收的任务。").font(.system(size: 12)).foregroundStyle(.secondary) }
            else { taskRows(accepted) }
        }
    }
    private var workflowContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("项目协作", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("让 AI 安排协作") { showPlannerSheet = true }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.currentProject?.isArchived != false || store.planningCandidates.isEmpty)
            }
            Text("先生成分工计划，确认负责人、依赖与验收方式，再启动协作。").font(.system(size: 12)).foregroundStyle(.secondary)
            if store.snapshot.plans.current.filter({ $0.projectID == store.activeProjectID }).isEmpty {
                Text(store.currentProject == nil ? "请先创建并选择一个项目。" : "这个项目还没有协作计划。").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 15)
                if store.currentProject == nil { Button("创建项目") { projectRequest = ProjectSheetRequest(project: nil) }.buttonStyle(.borderedPointer) }
            }
            CollaborationPanel(store: store) { selection = .task($0) }
            Divider()
            Label("员工交接", systemImage: "arrow.triangle.branch").font(.system(size: 16, weight: .semibold))
            let handoffs = store.snapshot.handoffs.filter { $0.projectID == store.activeProjectID }
            if handoffs.isEmpty { Text("任务产物验收后，可从任务详情交给下一位伙伴。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(handoffs) { handoff in
                if let target = handoff.targetTaskID {
                    Button { selection = .task(target) } label: { Label(handoff.goal + " → " + (store.employee(handoff.targetEmployeeID)?.name ?? "未知员工"), systemImage: "arrow.right").font(.system(size: 12)) }.buttonStyle(.plainPointer).disabled(!store.visibleTasks.contains { $0.id == target })
                }
            }
        }
    }
    // CH-13: one search over projects, categories, conversations, employees and tasks, narrowed by category and module.
    private func searchProjectMatches(_ id: UUID?) -> Bool {
        guard searchCategory != nil || searchModule != nil else { return true }
        guard let project = store.project(id) else { return false }
        return (searchCategory == nil || project.categoryID == searchCategory) && (searchModule.map { (project.moduleIDs ?? []).contains($0) } ?? true)
    }
    private func searchHit(_ text: String) -> Bool { searchText.isEmpty || text.localizedCaseInsensitiveContains(searchText) }
    private var searchCategories: [ProjectCategory] { store.snapshot.sortedCategories.filter { (searchCategory == nil || $0.id == searchCategory) && searchHit($0.name) } }
    private var searchProjects: [WorkProject] { store.snapshot.projects.current.filter { searchProjectMatches($0.id) && searchHit($0.name + $0.goal) } }
    private var searchConversations: [Conversation] {
        store.snapshot.conversations.current.filter { conversation in
            searchProjectMatches(conversation.projectID) && (searchHit(conversation.title) || (!searchText.isEmpty && store.snapshot.messages.contains { $0.conversationID == conversation.id && $0.text.localizedCaseInsensitiveContains(searchText) }))
        }
    }
    private var searchEmployees: [Employee] {
        store.snapshot.employees.current.filter { employee in
            let inModule = searchModule.map { employee.workspaceID == $0 || (employee.additionalWorkspaceIDs ?? []).contains($0) } ?? true
            return inModule && searchHit(employee.name + employee.role + employee.department)
        }
    }
    private var searchTasks: [WorkTask] { store.visibleTasks.filter { searchProjectMatches($0.projectID) && searchHit($0.title + $0.input) } }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 19) {
            TextField("名字、职责、对话或任务标题", text: $searchText).textFieldStyle(.roundedBorder).focused($searchFocused).onAppear { searchFocused = true }
            HStack {
                Picker("分类", selection: $searchCategory) {
                    Text("全部分类").tag(Optional<UUID>.none)
                    ForEach(store.snapshot.sortedCategories) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 220)
                Picker("工作区", selection: $searchModule) {
                    Text("全部工作区").tag(Optional<UUID>.none)
                    ForEach(store.workspaces) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 220)
            }.font(.system(size: 11)).accessibilityIdentifier("search.filters")
            Text("分类").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(searchCategories) { category in
                Button { projectsCategoryFilter = category.id; projectsModuleFilter = searchModule; openProjectID = nil; selection = nil; page = .projects } label: {
                    Label(category.name + " · \(store.snapshot.projects.current.filter { $0.categoryID == category.id }.count) 个项目", systemImage: category.icon.isEmpty ? "folder" : category.icon).font(.system(size: 12))
                }.buttonStyle(.plainPointer)
            }
            Divider()
            Text("项目").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(searchProjects) { project in
                Button { page = .projects; openProject(project.id) } label: { Label(project.name, systemImage: "folder").font(.system(size: 12)) }.buttonStyle(.plainPointer)
            }
            Divider()
            Text("对话").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(searchConversations) { conversation in
                Button { page = .projects; openProject(conversation.projectID); projectTab = .conversations; openConversationID = conversation.id } label: {
                    Label(conversation.title + " · " + (store.project(conversation.projectID)?.name ?? ""), systemImage: "bubble.left.and.bubble.right").font(.system(size: 12))
                }.buttonStyle(.plainPointer)
            }
            Divider()
            Text("员工").font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(searchEmployees) { employee in employeeRow(employee) }
            Divider()
            Text("任务").font(.system(size: 10)).foregroundStyle(.secondary)
            taskRows(searchTasks)
        }
    }

    private func employeeRow(_ employee: Employee, workspaceID: UUID? = nil) -> some View {
        Button { selection = .employee(employee.id) } label: {
            HStack {
                EmployeePortrait(symbol: employee.avatarSymbol, imageData: employee.avatarImageData, fallback: String(employee.name.prefix(1)), tint: accent).frame(width: 33, height: 33)
                VStack(alignment: .leading, spacing: 5) { Text(employee.name).font(.system(size: 12)); Text(employee.role).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10))
            }.padding(.vertical, 8)
        }.buttonStyle(.plainPointer).contextMenu { employeeActionButtons(employee, workspaceID: workspaceID) }
            .overlay(alignment: .trailing) { Menu { employeeActionButtons(employee, workspaceID: workspaceID) } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel("员工操作：" + employee.name) }
    }
    @ViewBuilder private func taskRows(_ tasks: [WorkTask]) -> some View {
        if tasks.isEmpty { Text("还没有任务，可以先放一个新想法。").font(.system(size: 12)).foregroundStyle(.secondary) }
        ForEach(tasks) { task in
            Button { selection = .task(task.id) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text(task.title).font(.system(size: 12)).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    HStack { Text(store.ownerName(task)).font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); StatusBadge(status: task.status) }
                    Divider()
                }.padding(.vertical, 7)
            }.buttonStyle(.plainPointer)
        }
    }
    private func newConfiguration(_ kind: SheetKind) { preferredEmployee = nil; preferredDepartment = nil; preferredTool = nil; editingEmployee = nil; editingTool = nil; editingTask = nil; sheet = kind }
    private func newTask(employee: UUID? = nil, input: String = "") { taskSeed = input; preferredEmployee = employee; preferredDepartment = nil; preferredTool = nil; editingEmployee = nil; editingTool = nil; editingTask = nil; sheet = .task }
}

struct EmployeePortrait: View {
    var symbol: String?
    var imageData: Data?
    var fallback: String
    var tint: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle().fill(tint.opacity(0.2))
                if let imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: geometry.size.width * 0.43)).foregroundStyle(tint)
                } else {
                    Text(fallback).font(.system(size: geometry.size.width * 0.4, weight: .medium))
                }
            }.clipShape(Circle())
        }.accessibilityHidden(true)
    }
}

enum AvatarImageLoader {
    static func load(_ url: URL) throws -> Data {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize <= 10 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "MyWorkbench.Avatar", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择不超过10MB的有效图片。"])
        }
        return data
    }
}

struct StatusBadge: View {
    let status: WorkStatus
    var compact = false
    private var color: Color {
        switch status {
        case .running: return .blue
        case .review: return .orange
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 4, height: 4); Text(status.title) }
            .font(.system(size: compact ? 9 : 10)).foregroundStyle(color).padding(.horizontal, compact ? 7 : 9).padding(.vertical, compact ? 3 : 5)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct TaskDetail: View {
    let task: WorkTask
    @ObservedObject var store: WorkbenchStore
    var onDraftArchived: () -> Void = {}
    var onEdit: () -> Void = {}
    @State private var historyID: UUID?
    @State private var historicalLog = ""
    @State private var feedback = ""
    @State private var showHandoff = false
    @State private var assignee: UUID?
    @State private var confirmAssignee = false
    @State private var showPlanApproval = false
    @State private var planCandidate: PlanDraft?
    @State private var confirmArchive = false
    private var runs: [TaskRun] { store.runs(for: task.id) }
    private var run: TaskRun? { if let historyID { return runs.first { $0.id == historyID } }; return task.status == .draft ? nil : runs.first }
    private var isHistorical: Bool { historyID != nil && (task.status == .draft || historyID != runs.first?.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            StatusBadge(status: isHistorical ? (run?.status ?? task.status) : task.status)
            Text(task.title).font(.system(size: 19, weight: .semibold))
            Text(isHistorical ? (run?.input ?? task.input) : task.input).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            if !runs.isEmpty {
                Picker("执行记录", selection: $historyID) {
                    Text(task.status == .draft ? "当前修改稿（尚未执行）" : "最近一次").tag(Optional<UUID>.none)
                    ForEach(runs) { record in Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.status.title)").tag(Optional(record.id)) }
                }.onChange(of: historyID) { _, _ in loadHistory() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label(run?.employee.name ?? store.ownerName(task), systemImage: task.generation != nil ? "wand.and.stars" : "person")
                Text(run?.workingDirectory ?? task.workingDirectory).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Button("在Finder中打开工作目录") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: task.workingDirectory) }.buttonStyle(.linkPointer)
                Text("验收标准：\(run?.acceptance ?? task.acceptance)").foregroundStyle(.secondary)
                if let tool = run?.tool ?? task.toolSnapshot ?? store.employee(task.employeeID).flatMap({ store.tool($0.toolID) }) {
                    Text(tool.remote.map { "服务：" + $0.baseURL + "\n工作流：" + $0.workflowName } ?? "执行：\(tool.executable)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    if tool.isCLI {
                        DisclosureGroup("查看执行参数") {
                            Text((run?.arguments ?? previewArguments(tool)).map { String(reflecting: $0) }.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                        if let run, let level = run.accessLevel {
                            Text(["权限：" + (run.tool.managesAccess ? level.title : "未由工作台管理"), run.model.map { "模型：" + $0 }, run.sessionID.map { "会话：" + $0 }].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let usage = run?.usage {
                            Text(["用量：", usage.costUSD.map { String(format: "$%.4f", $0) }, usage.inputTokens.map { "输入 \($0)" }, usage.outputTokens.map { "输出 \($0) tokens" }].compactMap { $0 }.joined(separator: " ")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Text("超时：\(Int(tool.timeout)) 秒").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let run { Button("查看完整日志与归档") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.logPath)]) }.buttonStyle(.linkPointer) }
            }.font(.system(size: 11))
            if task.status == .draft, let remote = store.employee(task.employeeID).flatMap({ store.tool($0.toolID) })?.remote {
                Text("工作流：\(remote.workflowName)\n预算：\(remote.budgetNote)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if task.status == .draft {
                Picker("分配草稿", selection: $assignee) { ForEach(store.snapshot.employees.current.filter { $0.enabled ?? true }) { Text($0.name).tag(Optional($0.id)) } }.onAppear { assignee = task.employeeID }
                Button("确认更换负责人") { confirmAssignee = true }.disabled(assignee == nil || assignee == task.employeeID)
            }
            HStack {
                Text("执行日志").font(.system(size: 12, weight: .medium)); Spacer()
                if task.status == .running { ProgressView().controlSize(.small) }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(isHistorical ? historicalLog : task.log, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plainPointer).help("复制最近日志").accessibilityLabel("复制显示的执行日志")
            }
            ReadOnlyTextView(text: isHistorical ? historicalLog : (task.log.isEmpty ? "任务执行后，真实日志会显示在这里。" : task.log), foregroundColor: NSColor(red: 0.77, green: 0.84, blue: 0.93, alpha: 1), backgroundColor: NSColor(red: 0.17, green: 0.23, blue: 0.20, alpha: 1), accessibilityName: "执行日志")
                .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
            if !isHistorical {
                HStack {
                    if task.status == .draft { Button("执行任务") { store.run(task.id) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable) }
                    else if task.status == .running || task.status == .queued { Button(task.status == .queued ? "取消排队" : (run?.tool.adapterKind == .comfyUI ? "停止远程任务" : "停止执行与子进程")) { store.cancel(task.id) }.buttonStyle(.borderedPointer).tint(.red) }
                    else if task.status == .review && task.purpose != .planning { Button("验收通过") { store.accept(task.id) }.buttonStyle(StudioPrimaryButtonStyle()) }
                    Spacer()
                    if let exit = task.exitCode { Text("exit \(exit)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                }
                if ![.running, .queued].contains(task.status) {
                    HStack {
                        if task.planID == nil && task.generation == nil && task.command == nil { Button("编辑任务", action: onEdit).buttonStyle(.borderedPointer) }
                        Button("删除任务", role: .destructive) { store.pendingDeletion = DeletionTarget(.task, task.id) }.buttonStyle(.borderedPointer)
                    }
                }
                if task.status == .draft { Button("移出草稿", role: .destructive) { confirmArchive = true }.buttonStyle(.borderedPointer) }
                if task.generation != nil && ![.draft, .running, .queued].contains(task.status) { Button("用相同参数再运行") { store.rerunGeneration(task.id) }.buttonStyle(.borderedPointer).help("复用这次提交的参数和种子") }
                if (task.generation != nil || task.command != nil) && task.status == .completed {
                    Button("导出到项目文件夹") { if let folder = store.exportOutputs(task.id) { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }.buttonStyle(.borderedPointer)
                }
                if let worktree = task.worktree { WorktreePanel(store: store, task: task, worktree: worktree) }
                if task.status == .review && task.purpose != .review && task.purpose != .planning && task.planID != nil { Button("重新提交AI审核") { store.requestReviewAgain(task.id) }.buttonStyle(.borderedPointer) }
                if task.status == .review && task.purpose == .planning {
                    Button("审阅协作计划") { do { planCandidate = try store.planDraft(for: task.id); showPlanApproval = true } catch { store.errorMessage = error.localizedDescription } }.buttonStyle(StudioPrimaryButtonStyle())
                }
                if ![.draft, .running, .queued].contains(task.status) {
                    TextField("返工或重试说明", text: $feedback, axis: .vertical).lineLimit(2...3)
                    if task.status == .interrupted && run?.remotePromptID != nil { Button("查询已有远程执行") { store.resumeRemote(task.id) }.buttonStyle(.borderedPointer) }
                    Button(task.status == .interrupted ? "已检查旧作业，新建执行" : "新建一次执行") { store.run(task.id, feedback: feedback) }.buttonStyle(.borderedPointer).disabled(!store.storageAvailable)
                }
            }
            ForEach(store.snapshot.reviews.filter { $0.sourceTaskID == task.id }) { review in
                VStack(alignment: .leading, spacing: 7) {
                    Text("AI审核：\(review.decision.decision.rawValue)").font(.system(size: 11, weight: .medium))
                    Text(review.decision.notes).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("来源 run \(review.sourceRunID.uuidString.prefix(8))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if let run {
                Divider()
                Text("这次执行的产物").font(.system(size: 12, weight: .medium))
                Text("run \(run.id.uuidString.prefix(8))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                if let prompt = run.remotePromptID { Text("服务端编号：\(prompt)").font(.system(size: 9, design: .monospaced)).textSelection(.enabled) }
                ForEach(run.remoteArtifacts ?? []) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.filename).font(.system(size: 11, weight: .medium))
                        Text(file.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "文件大小待查询").font(.system(size: 10)).foregroundStyle(.secondary)
                        if file.localArtifactID == nil { Button(store.downloadingFiles.contains(file.id) ? "下载中…" : "下载到本次归档") { store.downloadRemote(runID: run.id, fileID: file.id) }.disabled(store.downloadingFiles.contains(file.id)) }
                    }
                }
                ArtifactList(store: store, runID: run.id)
                if run.status != .running { Button("导入文件到本次归档") { importFiles(run.id) }.buttonStyle(.borderedPointer) }
                if run.status == .completed && task.status == .completed { Button("交给下一位员工") { showHandoff = true }.buttonStyle(StudioPrimaryButtonStyle()) }
            }
        }.font(.system(size: 11))
        .sheet(isPresented: $showPlanApproval) { if let planCandidate, let projectID = task.projectID { PlanApprovalSheet(draft: planCandidate, planningTaskID: task.id, projectID: projectID, store: store) } }
        .sheet(isPresented: $showHandoff) { if let run { HandoffConfigurationSheet(task: task, run: run, store: store) } }
        .alert("更换草稿负责人？", isPresented: $confirmAssignee) { Button("取消", role: .cancel) {}; Button("确认") { if let assignee { store.assignDraft(task.id, to: assignee) } } } message: { Text("任务仍保留为草稿。") }
        .alert("移出这个草稿？", isPresented: $confirmArchive) { Button("取消", role: .cancel) {}; Button("移出草稿", role: .destructive) { if store.archiveDraft(task.id) { onDraftArchived() } } } message: { Text("可在项目桌的“已移出草稿”中恢复。") }
    }
    private func previewArguments(_ tool: ToolConfig) -> [String] {
        let employee = store.employee(task.employeeID)
        let level = employee.flatMap { try? store.accessLevel(for: task, employee: $0, tool: tool) } ?? .readOnly
        let call = CLIInvocation(prompt: task.input, instructions: employee?.instructions ?? "", outputDirectory: "（本次归档目录）", workingDirectory: task.workingDirectory, model: employee?.model, access: level, sessionID: tool.assignsSessionID ? "（运行时生成）" : nil)
        do { return try tool.invocation(call) } catch { return [error.localizedDescription] }
    }
    private func loadHistory() {
        guard let run, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: run.logPath)) else { historicalLog = "日志文件不可访问"; return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd(); try handle.seek(toOffset: size > 128000 ? size - 128000 : 0)
            var data = try handle.readToEnd() ?? Data()
            while let first = data.first, first & 0xC0 == 0x80 { data.removeFirst() }
            historicalLog = String(decoding: data, as: UTF8.self)
        } catch { historicalLog = error.localizedDescription }
    }
    private func importFiles(_ id: UUID) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { store.importArtifact(url, runID: id) } }
    }
}

struct ConfigurationSheet: View {
    let kind: SheetKind
    @ObservedObject var store: WorkbenchStore
    var preferredEmployeeID: UUID? = nil
    var preferredDepartment: String? = nil
    var preferredToolID: UUID? = nil
    var employeeToEdit: Employee? = nil
    var taskToEdit: WorkTask? = nil
    var initialTaskInput: String = ""
    var onTaskSaved: (UUID) -> Void = { _ in }
    var onRequestCLI: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var workspaceID: UUID?
    @State private var extraWorkspaces: Set<UUID> = []
    @State private var input = ""
    @State private var acceptance = ""
    @State private var toolID: UUID?
    @State private var employeeID: UUID?
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var avatarSymbol: String?
    @State private var avatarImageData: Data?
    @State private var avatarError: String?
    @State private var projectID: UUID?
    @State private var maxAccess = AccessLevel.readOnly
    @State private var model = ""
    @State private var taskAccess = AccessLevel.readOnly

    private var title: String { kind == .employee ? (employeeToEdit == nil ? "新增AI员工" : "配置员工档案") : (taskToEdit == nil ? "新建任务" : "编辑任务") }
    private var selectedTool: ToolConfig? { toolID.flatMap { store.tool($0) } }
    private var taskEmployee: Employee? { employeeID.flatMap { store.employee($0) } }
    private var taskTool: ToolConfig? { taskEmployee.flatMap { store.tool($0.toolID) } }
    /// Levels a task may request: up to the agent's ceiling and only those its CLI defines.
    private var taskLevels: [AccessLevel] {
        guard let employee = taskEmployee, let tool = taskTool, tool.isCLI, tool.managesAccess else { return [] }
        return AccessLevel.allCases.filter { $0 <= (employee.maxAccess ?? .readOnly) && tool.supports($0) }
    }
    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.storageAvailable else { return false }
        switch kind {
        case .tool: return false
        case .employee:
            guard let tool = selectedTool else { return false }
            return !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!tool.isCLI || tool.supports(maxAccess))
        case .task:
            var isDirectory: ObjCBool = false
            return employeeID != nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workingDirectory.hasPrefix("/") && FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) && isDirectory.boolValue && (taskLevels.isEmpty || taskLevels.contains(taskAccess))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: kind == .employee ? "person.badge.plus" : "list.bullet.clipboard")
                    .font(.system(size: 20)).foregroundStyle(Theme.blue).frame(width: 45, height: 45).background(Theme.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    Text("明确配置，再开始执行。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if kind == .employee && store.snapshot.tools.current.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("还没有添加 CLI", systemImage: "terminal").font(.system(size: 14, weight: .semibold))
                    Text("AI 员工需要绑定一个 CLI。工作台不内置任何 CLI，请先手动添加。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("添加 CLI") { dismiss(); onRequestCLI() }.buttonStyle(StudioPrimaryButtonStyle())
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            Form {
                TextField(kind == .task ? "任务标题" : "名称", text: $name)
                switch kind {
                case .tool: EmptyView()
                case .employee:
                    avatarConfiguration
                    TextField("职位", text: $role)
                    Picker("工作区", selection: $workspaceID) { Text("未分配工作区").tag(Optional<UUID>.none); ForEach(store.workspaces) { Text($0.name).tag(Optional($0.id)) } }
                    Picker("绑定 CLI", selection: $toolID) {
                        ForEach(store.snapshot.tools.current) { tool in Text(tool.name + (tool.isCLI && !tool.executableAvailable ? "（缺失）" : (tool.isCLI ? "" : " · ComfyUI"))).tag(Optional(tool.id)) }
                    }
                    if let tool = selectedTool, tool.isCLI {
                        Picker("最高权限", selection: $maxAccess) { ForEach(AccessLevel.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        if !tool.managesAccess { Text("这个 CLI 没有配置权限参数，工作台不管理它的权限。").font(.system(size: 10)).foregroundStyle(.secondary) }
                        else if !tool.supports(maxAccess) { Text("「\(tool.name)」没有配置「\(maxAccess.title)」参数。请换一个权限，或先编辑 CLI。").font(.system(size: 10)).foregroundStyle(.red) }
                        else { Text("任务可以请求更低的权限，但不会超过这里的上限。").font(.system(size: 10)).foregroundStyle(.secondary) }
                        if !(tool.modelArguments ?? []).isEmpty { TextField("默认模型（可选）", text: $model) }
                    }
                    TextField("职责说明", text: $input, axis: .vertical).lineLimit(3...5)
                    DisclosureGroup("也出现在其他工作区") {
                        ForEach(store.workspaces.filter { $0.id != workspaceID }) { area in
                            Toggle(area.name, isOn: Binding(get: { extraWorkspaces.contains(area.id) }, set: { if $0 { extraWorkspaces.insert(area.id) } else { extraWorkspaces.remove(area.id) } }))
                        }
                    }
                case .task:
                    Picker("归属项目", selection: $projectID) {
                        Text("未归属项目").tag(Optional<UUID>.none)
                        ForEach(store.activeProjects) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: projectID) { _, value in
                        if let original = taskToEdit, value == original.projectID, workingDirectory == original.workingDirectory { return }
                        if let project = store.snapshot.projects.current.first(where: { $0.id == value }) { workingDirectory = project.directory }
                    }
                    Picker("负责人", selection: $employeeID) { ForEach(store.snapshot.employees.current.filter { $0.enabled ?? true }) { Text($0.name).tag(Optional($0.id)) } }
                        .onChange(of: employeeID) { _, _ in if taskToEdit?.employeeID != employeeID { taskAccess = taskLevels.last ?? .readOnly } }
                    if !taskLevels.isEmpty {
                        Picker("权限", selection: $taskAccess) { ForEach(taskLevels, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    } else if let tool = taskTool, tool.isCLI, tool.managesAccess {
                        Text("负责人的 CLI 没有配置可用的权限参数，无法执行。").font(.system(size: 10)).foregroundStyle(.red)
                    }
                    if let tool = taskTool, tool.isCLI, !tool.executableAvailable { Text("负责人的 CLI「\(tool.name)」缺失，执行前需要修正路径。").font(.system(size: 10)).foregroundStyle(.orange) }
                    HStack {
                        TextField("工作目录", text: $workingDirectory)
                        Button("选择目录") { choose(directory: true) { workingDirectory = $0 } }
                    }
                    TextField("任务输入", text: $input, axis: .vertical).lineLimit(3...6)
                    TextField("验收标准", text: $acceptance, axis: .vertical).lineLimit(2...3)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { submit() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 600).frame(maxHeight: 700)
        .onAppear {
            toolID = preferredToolID ?? store.cliTools.first?.id ?? store.snapshot.tools.current.first?.id
            employeeID = preferredEmployeeID ?? store.snapshot.employees.current.first(where: { $0.enabled != false })?.id
            taskAccess = taskLevels.last ?? .readOnly
            workspaceID = store.workspaces.first(where: { $0.name == preferredDepartment })?.id ?? WorkArea.defaults[2].id
            if !store.workspaces.contains(where: { $0.id == workspaceID }) { workspaceID = store.workspaces.first?.id }
            projectID = store.currentProject?.isArchived == false ? store.activeProjectID : nil
            workingDirectory = store.project(projectID)?.directory ?? workingDirectory
            if kind == .task { input = initialTaskInput; name = String(initialTaskInput.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(40) ?? "") }
            if let taskToEdit {
                name = taskToEdit.title; input = taskToEdit.input; acceptance = taskToEdit.acceptance
                employeeID = taskToEdit.employeeID; projectID = taskToEdit.projectID; workingDirectory = taskToEdit.workingDirectory
                taskAccess = taskToEdit.accessLevel ?? .readOnly
            }
            if let employeeToEdit {
                name = employeeToEdit.name; role = employeeToEdit.role; workspaceID = employeeToEdit.workspaceID
                toolID = employeeToEdit.toolID; input = employeeToEdit.instructions
                avatarSymbol = employeeToEdit.avatarSymbol; avatarImageData = employeeToEdit.avatarImageData
                maxAccess = employeeToEdit.maxAccess ?? .readOnly; model = employeeToEdit.model ?? ""
                extraWorkspaces = Set(employeeToEdit.additionalWorkspaceIDs ?? [])
            }
        }
    }

    private var avatarConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                EmployeePortrait(symbol: avatarSymbol, imageData: avatarImageData, fallback: name.isEmpty ? "+" : String(name.prefix(1)), tint: Theme.blue).frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text("员工头像").font(.system(size: 12, weight: .medium))
                    Text("选择预设，或上传本地图片。图片保存后不依赖原文件。").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("上传图片") { chooseAvatar() }.font(.system(size: 11))
                }
            }
            HStack(spacing: 7) {
                ForEach(["initials", "person.fill", "sparkles", "cpu", "paintpalette.fill"], id: \.self) { preset in
                    Button {
                        avatarSymbol = preset == "initials" ? nil : preset
                        avatarImageData = nil; avatarError = nil
                    } label: {
                        if preset == "initials" { Text("姓名") } else { Image(systemName: preset) }
                    }.buttonStyle(.borderedPointer).tint(avatarImageData == nil && (avatarSymbol ?? "initials") == preset ? Theme.blue : .secondary)
                        .help(["initials": "姓名首字", "person.fill": "人物", "sparkles": "灵感", "cpu": "开发", "paintpalette.fill": "设计"][preset] ?? "头像预设")
                        .accessibilityLabel(["initials": "姓名首字头像", "person.fill": "人物头像", "sparkles": "灵感头像", "cpu": "开发头像", "paintpalette.fill": "设计头像"][preset] ?? "头像预设")
                        .accessibilityValue(avatarImageData == nil && (avatarSymbol ?? "initials") == preset ? "已选择" : "未选择")
                }
            }
            if let avatarError { Text(avatarError).font(.system(size: 10)).foregroundStyle(.red) }
        }.padding(.vertical, 7)
    }
    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do { avatarImageData = try AvatarImageLoader.load(url); avatarError = nil }
            catch { avatarError = error.localizedDescription }
        }
    }

    private func choose(directory: Bool, completion: (String) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }

    private func submit() {
        let saved: Bool
        var createdTaskID: UUID?
        switch kind {
        case .tool: return
        case .employee:
            guard let toolID else { return }
            var employee = Employee(id: employeeToEdit?.id ?? UUID(), name: name, role: role, department: store.workspaces.first(where: { $0.id == workspaceID })?.name ?? "", instructions: input, toolID: toolID, avatarSymbol: avatarSymbol, avatarImageData: avatarImageData)
            employee.enabled = employeeToEdit?.enabled; employee.workspaceID = workspaceID
            employee.maxAccess = maxAccess
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            employee.model = trimmedModel.isEmpty ? nil : trimmedModel
            let extras = store.workspaces.map(\.id).filter { extraWorkspaces.contains($0) && $0 != workspaceID }
            employee.additionalWorkspaceIDs = extras.isEmpty ? nil : extras
            saved = employeeToEdit == nil ? store.addEmployee(employee) : store.updateEmployee(employee)
        case .task:
            guard let employeeID else { return }
            var task = taskToEdit ?? WorkTask(title: name, employeeID: employeeID, input: input, workingDirectory: workingDirectory, acceptance: acceptance)
            task.title = name; task.employeeID = employeeID; task.input = input; task.workingDirectory = workingDirectory; task.acceptance = acceptance
            task.projectID = projectID; task.accessLevel = taskLevels.isEmpty ? nil : taskAccess
            saved = taskToEdit == nil ? store.addTask(task) : store.updateTask(task)
            if saved { createdTaskID = task.id }
        }
        if saved { if let createdTaskID { onTaskSaved(createdTaskID) }; dismiss() }
    }
}
