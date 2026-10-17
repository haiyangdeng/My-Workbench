import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum SheetKind: String, Identifiable {
    case tool, employee, task
    var id: Self { self }
}

enum Theme {
    static let blue = Color(red: 88/255, green: 115/255, blue: 94/255)
    static let navy = Color(red: 0.17, green: 0.23, blue: 0.20)
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static let paper = adaptive(NSColor(red: 245/255, green: 248/255, blue: 250/255, alpha: 1), NSColor(red: 0.12, green: 0.16, blue: 0.18, alpha: 1))
    static let surface = adaptive(NSColor(red: 1, green: 1, blue: 1, alpha: 1), NSColor(red: 0.18, green: 0.22, blue: 0.24, alpha: 1))
    static let sidebar = adaptive(NSColor(red: 238/255, green: 243/255, blue: 248/255, alpha: 1), NSColor(red: 0.14, green: 0.18, blue: 0.21, alpha: 1))
}

enum StudioSelection: Equatable {
    case project, workspace(UUID), manageAreas, employee(UUID), task(UUID), tools, assets, knowledge, workflow, personalize, search
}
private struct WorkspaceSheetRequest: Identifiable {
    let id = UUID()
    var area: WorkArea?
}

@MainActor struct WorkbenchView: View {
    @ObservedObject var terminals = TerminalWorkspace()
    var initialSelection: StudioSelection? = nil
    var initialPage: StudioPage = .home
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
    @State private var editingTool: ToolConfig?
    @State private var showProjectSheet = false
    @State private var showRemoteToolSheet = false
    @State private var showPlannerSheet = false
    @State private var remoteToolToEdit: ToolConfig?
    @State private var pendingAssignment: (taskID: UUID, employeeID: UUID)?
    @State private var confirmAssignment = false
    @State private var searchText = ""
    @State private var ideaText = ""
    @State private var taskSeed = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("studioThemeV04") private var studioMood = "paper"

    private var accent: Color { studioMood == "paper" ? Theme.blue : Color(red: 0.28, green: 0.51, blue: 0.46) }
    private var reviewTasks: [WorkTask] { store.visibleTasks.filter { $0.status == .review } }

    var body: some View {
        HStack(spacing: 0) {
            StudioSidebar(page: $page, reviewCount: reviewTasks.count, onNavigate: { selection = nil }, onTerminal: showTerminal, onManage: { selection = .manageAreas }, terminalCount: terminals.activeCount)
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
                    TerminalPanel(terminals: terminals, store: store, dark: studioMood == "ink").frame(height: min(consoleHeight, viewHeight < 800 ? 220 : 320))
                } else { composer }
            }
        }
        .background(Theme.paper).tint(accent).ignoresSafeArea(.container, edges: .top)
        .background { GeometryReader { geometry in Color.clear.onAppear { viewHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, height in viewHeight = height } } }
        .preferredColorScheme(studioMood == "ink" ? .dark : .light)
        .onAppear { page = initialPage; if let initialSelection { selection = initialSelection } }
        .sheet(item: $areaRequest) { request in WorkspaceConfigurationSheet(store: store, areaToEdit: request.area) }
        .alert("终端提示", isPresented: Binding(get: { terminals.error != nil }, set: { if !$0 { terminals.error = nil } })) { Button("知道了") { terminals.error = nil } } message: { Text(terminals.error ?? "") }
        .sheet(item: $sheet) { kind in
            ConfigurationSheet(kind: kind, store: store, preferredEmployeeID: preferredEmployee, preferredDepartment: preferredDepartment, employeeToEdit: editingEmployee, toolToEdit: editingTool, initialTaskInput: taskSeed, onTaskSaved: { id in
                if !taskSeed.isEmpty && ideaText == taskSeed { ideaText = "" }
                if let task = store.visibleTasks.first(where: { $0.id == id }) { store.activeProjectID = task.projectID }
                selection = .task(id)
            })
        }
        .sheet(isPresented: $showPlannerSheet) { PlannerConfigurationSheet(store: store) { selection = .task($0) } }
        .sheet(isPresented: $showRemoteToolSheet) { RemoteToolConfigurationSheet(store: store, toolToEdit: remoteToolToEdit) }
        .sheet(isPresented: $showProjectSheet) { ProjectConfigurationSheet(store: store) }
        .alert("把草稿交给这位员工？", isPresented: $confirmAssignment) {
            Button("取消", role: .cancel) { pendingAssignment = nil }
            Button("确认分配") { if let assignment = pendingAssignment { store.assignDraft(assignment.taskID, to: assignment.employeeID) }; pendingAssignment = nil }
        } message: { Text("只更新草稿负责人，确认后仍由你发起执行。") }
        .alert("工作台提示", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("知道了") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onExitCommand { selection = nil }
    }

    private func studioHome(size: CGSize) -> some View {
        let heroHeight: CGFloat = terminals.isVisible ? 205 : min(286, max(210, viewHeight - 680))
        let cardHeight: CGFloat = min(306, max(274, (viewHeight - heroHeight - 135) / 2))
        return ScrollViewReader { reader in
            ScrollView {
                VStack(spacing: 0) {
                    StudioHero(height: heroHeight, width: size.width)
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
                                }).id(area.id)
                        }
                    }.padding(.horizontal, 22).padding(.bottom, 8)
                    HStack {
                        Text("所有项目 · \(store.workspaces.count) 个工作区").foregroundStyle(.secondary)
                        Spacer()
                        Button { areaRequest = WorkspaceSheetRequest(area: nil) } label: { Label("添加工作区", systemImage: "plus") }.disabled(!store.storageAvailable)
                    }.font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 28).padding(.top, 9).padding(.bottom, 4)
                }
            }.onChange(of: store.workspaces.count) { _, _ in
                if let id = store.workspaces.last?.id { withAnimation { reader.scrollTo(id, anchor: .bottom) } }
            }
        }.overlay(alignment: .topTrailing) { headerControls.padding(.horizontal, 25).padding(.top, 12) }
            .accessibilityIdentifier("studio.page.home")
    }

    private var headerControls: some View {
        HStack(spacing: 17) {
            Spacer(minLength: 0)
            Button { selection = .search } label: {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    Text("搜索项目、员工、任务…")
                    Spacer()
                    Text("⌘ K").font(.system(size: 10))
                }.font(.system(size: 11)).foregroundStyle(Color(hex: "718094"))
                    .padding(.horizontal, 14).frame(width: 300, height: 35).background(.white.opacity(0.6), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.75)))
            }.buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
            Button { if let task = reviewTasks.first { selection = .task(task.id) } else { page = .projects; selection = nil } } label: {
                Image(systemName: "bell").font(.system(size: 17)).foregroundStyle(Color(hex: "233A4F")).frame(width: 35, height: 35).background(.white.opacity(0.65), in: Circle())
                    .overlay(alignment: .topTrailing) { if !reviewTasks.isEmpty { Circle().fill(.orange).frame(width: 7, height: 7).padding(3) } }
            }.buttonStyle(.plain).help("\(reviewTasks.count) 项待验收").accessibilityLabel("待验收任务：\(reviewTasks.count)")
            Button { page = .settings; selection = nil } label: {
                Image(systemName: "person.crop.circle.fill").symbolRenderingMode(.palette).foregroundStyle(Color(hex: "335E50"), Color.white.opacity(0.9)).font(.system(size: 34))
            }.buttonStyle(.plain).help("工作室设置").accessibilityLabel("工作室设置")
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
                    Button { store.snapshot.tools.isEmpty ? newConfiguration(.tool) : newConfiguration(.employee) } label: { Label("添加员工", systemImage: "plus") }
                        .buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                }
                if page == .projects || page == .workflow || page == .assets || page == .knowledge {
                    Picker("当前项目", selection: $store.activeProjectID) {
                        Text("未归属项目").tag(Optional<UUID>.none)
                        ForEach(store.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(maxWidth: 270)
                }
            }.padding(.horizontal, 34).padding(.top, 32).padding(.bottom, 27)
            ScrollView {
                Group {
                    if page == .employees { employeeDirectory }
                    else {
                        inspectorContent(for: pageSelection).frame(maxWidth: .infinity, alignment: .leading).padding(28)
                            .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.blue.opacity(0.08)))
                    }
                }.padding(.horizontal, 34).padding(.bottom, 24)
            }
        }.accessibilityIdentifier("studio.page." + page.rawValue)
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
        VStack(alignment: .leading, spacing: 28) {
            ForEach(store.workspaces) { area in
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Label(area.name, systemImage: area.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(StudioArtwork.tint(for: area))
                        Text("\(store.employees(in: area).count) 位员工").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("添加员工") { addEmployee(to: area) }.buttonStyle(.bordered).disabled(!store.storageAvailable)
                    }
                    if store.employees(in: area).isEmpty {
                        Text("为这个工作区安排第一位伙伴。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 16)], spacing: 16) {
                            ForEach(store.employees(in: area)) { employee in
                                Button { selection = .employee(employee.id) } label: {
                                    HStack(spacing: 13) {
                                        EmployeePortrait(symbol: employee.avatarSymbol, imageData: employee.avatarImageData, fallback: String(employee.name.prefix(1)), tint: StudioArtwork.tint(for: area)).frame(width: 49, height: 49)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(employee.name).font(.system(size: 16, weight: .semibold))
                                            Text(employee.role).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                            if let tool = store.tool(employee.toolID) {
                                                Label(employee.enabled == false ? "已停用" : store.loginCheck(for: tool).state.title, systemImage: "circle.fill").font(.system(size: 9)).foregroundStyle(loginTint(store.loginCheck(for: tool).state))
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }.padding(20).frame(maxWidth: .infinity, minHeight: 112, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(StudioArtwork.tint(for: area).opacity(0.13)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 13) {
                Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(accent)
                TextField("告诉我你的想法，让 AI 帮你开始…", text: $ideaText).textFieldStyle(.plain).font(.system(size: 12)).onSubmit { composeTask() }.accessibilityIdentifier("studio.idea")
                Button { chooseReferenceFiles() } label: { Image(systemName: "paperclip").font(.system(size: 17)) }.buttonStyle(.plain).help("把文件路径加入任务输入").accessibilityLabel("添加参考文件")
                Menu {
                    Button("新建任务") { newTask() }.disabled(!store.snapshot.employees.contains { $0.enabled != false })
                    Button("让 AI 安排协作") { showPlannerSheet = true }.disabled(store.currentProject == nil || !store.snapshot.employees.contains { $0.enabled != false && store.tool($0.toolID)?.adapterKind == .codex && store.tool($0.toolID)?.isEnabled == true })
                    Button("添加工作区") { areaRequest = WorkspaceSheetRequest(area: nil) }
                    Button("打开终端", action: showTerminal)
                } label: { Image(systemName: "square.grid.2x2").frame(width: 34, height: 34).background(Theme.paper, in: Circle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("工作室快捷操作")
                Button(action: composeTask) { Image(systemName: "paperplane").font(.system(size: 16)).foregroundStyle(.white).frame(width: 39, height: 39).background(Color(hex: "3B7B65"), in: Circle()) }.buttonStyle(.plain).disabled(ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.storageAvailable).help("配置这个想法").accessibilityLabel("配置这个想法").accessibilityIdentifier("studio.compose")
            }.padding(.leading, 20).padding(.trailing, 6).frame(maxWidth: 685).frame(height: 52).background(Theme.surface, in: Capsule()).overlay(Capsule().stroke(Theme.blue.opacity(0.06))).shadow(color: .black.opacity(0.055), radius: 15, y: 7)
            Spacer(minLength: 0)
        }.padding(.horizontal, 30).frame(height: 84).overlay(alignment: .bottomTrailing) {
            Text("ONE PERSON   ×   AI TEAM").font(.system(size: 8)).tracking(1.5).foregroundStyle(.secondary.opacity(0.7)).padding(.trailing, 29).padding(.bottom, 4)
        }
    }

    private func composeTask() {
        guard !ideaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.storageAvailable else { return }
        guard store.snapshot.employees.contains(where: { $0.enabled != false }) else {
            page = store.snapshot.tools.isEmpty ? .tools : .employees; selection = nil
            store.errorMessage = "先接入工具并添加一位启用的员工，再把想法交给它。输入会保留。"
            return
        }
        newTask(input: ideaText)
    }
    private func chooseReferenceFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            let references = panel.urls.map { $0.path }.joined(separator: "\n")
            if !references.isEmpty { ideaText += (ideaText.isEmpty ? "" : "\n\n") + "参考文件：\n" + references }
        }
    }
    private func showTerminal() { if terminals.selected != nil { terminals.isVisible = true } else { openTerminal(nil) } }
    private func addEmployee(to area: WorkArea) {
        preferredDepartment = area.name; preferredEmployee = nil; editingEmployee = nil; editingTool = nil
        if store.snapshot.tools.isEmpty { page = .tools; selection = nil; sheet = .tool }
        else { sheet = .employee }
    }
    private func loginTint(_ state: LoginState) -> Color { state == .loggedIn ? accent : (state == .loggedOut || state == .failed ? .orange : .gray) }
    private func openTerminal(_ employee: Employee?, login: Bool = false) {
        let tool = employee.flatMap { store.tool($0.toolID) }
        terminals.open(employee: employee, tool: tool, directory: store.currentProject?.directory ?? FileManager.default.homeDirectoryForCurrentUser.path, login: login, onLoginEnd: { if let tool { store.checkLogin(tool.id) } })
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text(inspectorTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { selection = nil } label: { Image(systemName: "xmark").padding(7) }.buttonStyle(.plain).help("收起对象详情").accessibilityLabel("收起对象详情")
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
            if let task = store.visibleTasks.first(where: { $0.id == id }) { TaskDetail(task: task, store: store, onDraftArchived: { selection = .project }) }
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
                            HStack { Label(tool.name, systemImage: "terminal"); Spacer(); Text(check.state.title).foregroundStyle(loginTint(check.state)) }.font(.system(size: 11))
                            if let date = check.checkedAt { Text("最近检测：" + date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                            Text("共用此 CLI 配置的员工共享登录状态。").font(.system(size: 10)).foregroundStyle(.secondary)
                            HStack {
                                Button("检测登录") { store.checkLogin(tool.id) }.disabled(check.state == .checking || tool.authenticationStatusArguments == nil)
                                Button("打开终端") { openTerminal(employee) }.disabled(tool.adapterKind == .comfyUI)
                            }.buttonStyle(.bordered).font(.system(size: 11))
                            if tool.authenticationLoginArguments != nil { Button("在终端登录账号") { openTerminal(employee, login: true) }.font(.system(size: 11)) }
                            if check.state == .failed { Text(check.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled) }
                        }.padding(13).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let task = store.visibleTasks.first(where: { $0.employeeID == id && $0.projectID == store.activeProjectID && $0.status != .completed }) {
                        HStack { Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(1); Spacer(); StatusBadge(status: task.status) }
                    }
                    DisclosureGroup("职责说明") { Text(employee.instructions.isEmpty ? "尚未填写职责说明。" : employee.instructions).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled) }.font(.system(size: 11))
                    Button("配置头像与档案") { editingEmployee = employee; preferredEmployee = nil; preferredDepartment = nil; sheet = .employee }.buttonStyle(.bordered).disabled(!store.storageAvailable)
                    Button(employee.enabled == false ? "启用员工" : "停用员工") { var updated = employee; updated.enabled = !(employee.enabled ?? true); store.updateEmployee(updated) }.buttonStyle(.bordered)
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
                    ForEach(store.employees(in: area)) { employee in employeeRow(employee) }
                    Button("安排新员工") { addEmployee(to: area) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                    Button("编辑工作区") { areaRequest = WorkspaceSheetRequest(area: area) }.buttonStyle(.bordered)
                    Divider(); taskRows(store.tasks(in: area))
                }
            }
        case .manageAreas:
            VStack(alignment: .leading, spacing: 18) {
                Text("为伙伴留出空间").font(.system(size: 23, weight: .medium))
                Text("每个工作区可配置多位员工。改名与配色会保留原有任务和员工关系。").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(store.workspaces) { area in
                    Button { areaRequest = WorkspaceSheetRequest(area: area) } label: {
                        HStack { Image(systemName: area.icon).foregroundStyle(Color(hex: area.color)); Text(area.name); Spacer(); Text("\(store.employees(in: area).count) 人").foregroundStyle(.secondary); Image(systemName: "pencil") }.font(.system(size: 12)).padding(.vertical, 10)
                    }.buttonStyle(.plain)
                }
                Button("添加工作区") { areaRequest = WorkspaceSheetRequest(area: nil) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
            }
        case .tools:
            VStack(alignment: .leading, spacing: 19) {
                Text("趁手的工具，\n放在一起。").font(.system(size: 24, weight: .medium))
                Text(store.snapshot.tools.isEmpty ? "先接入一个本地工具，再招募员工。每位员工独立配置职责，多人也可以绑定同一个工具。" : "工具可被多位员工使用。通过绝对路径和参数列表注册，注册不会开始执行。").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(store.snapshot.tools) { tool in
                    VStack(alignment: .leading, spacing: 9) {
                        Label(tool.name, systemImage: "terminal").font(.system(size: 13, weight: .medium))
                        Text(tool.remote?.baseURL ?? tool.executable).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        Text(tool.adapterKind == .comfyUI ? (store.remoteChecks[tool.id] ?? "服务待检测") : (FileManager.default.isExecutableFile(atPath: tool.executable) ? "可执行 · 待业务验证" : "路径不可用")).font(.system(size: 10)).foregroundStyle(.secondary)
                        if let version = tool.detectedVersion { Text(version).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3) }
                        HStack {
                            Button("配置") { if tool.adapterKind == .comfyUI { remoteToolToEdit = tool; showRemoteToolSheet = true } else { editingTool = tool; editingEmployee = nil; sheet = .tool } }
                            Button(store.probingTools.contains(tool.id) ? "检测中…" : (tool.adapterKind == .comfyUI ? "检测连接" : "检测版本")) { if tool.adapterKind == .comfyUI { store.checkRemote(tool.id) } else { store.probeTool(tool.id) } }.disabled(store.probingTools.contains(tool.id))
                            Button(tool.isEnabled ? "停用" : "启用") { var updated = tool; updated.enabled = !tool.isEnabled; store.updateTool(updated) }
                        }.font(.system(size: 10))
                        if tool.remote?.ssh != nil {
                            Button(store.tunnelTools.contains(tool.id) ? "断开 SSH 隧道" : "连接 SSH 隧道") { if store.tunnelTools.contains(tool.id) { store.disconnectTunnel(tool.id) } else { store.connectTunnel(tool.id) } }.font(.system(size: 10))
                        }
                        Divider()
                    }
                }
                Button("接入 CLI 工具") { newConfiguration(.tool) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                Button("接入 ComfyUI 制作服务") { remoteToolToEdit = nil; showRemoteToolSheet = true }.buttonStyle(.bordered).disabled(!store.storageAvailable)
                Button("安排新员工") { newConfiguration(.employee) }.buttonStyle(.bordered).disabled(store.snapshot.tools.isEmpty || !store.storageAvailable)
                if store.snapshot.tools.isEmpty { Button("体验本地验证") { store.addLocalExample(); selection = store.visibleTasks.first.map { .task($0.id) } }.buttonStyle(.bordered).disabled(!store.storageAvailable) }
            }
        case .assets:
            VStack(alignment: .leading, spacing: 19) {
                Text("留下工作的痕迹").font(.system(size: 23, weight: .medium))
                Text("当前项目的产物保留来源执行、文件大小和验收记录。预览后，可从任务详情交给下一位员工。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                ArtifactList(store: store)
            }
        case .knowledge:
            knowledgeContent
        case .workflow:
            workflowContent
        case .personalize:
            VStack(alignment: .leading, spacing: 22) {
                Text("工作室，也有\n你的性格。").font(.system(size: 24, weight: .medium))
                Picker("同时执行", selection: $store.concurrencyLimit) { Text("1 个任务").tag(1); Text("2 个任务").tag(2) }.onChange(of: store.concurrencyLimit) { _, _ in store.schedulePending() }
                Text("默认使用参考图的浅蓝配色。你也可以选择深色，设置会在下次启动时保留。").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(["paper", "ink"], id: \.self) { mood in
                    Button { studioMood = mood } label: {
                        HStack {
                            Circle().fill(mood == "paper" ? Color(hex: "B2D7F0") : accent).frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mood == "paper" ? "云蓝 · 浅色" : "夜幕 · 深色").font(.system(size: 13))
                                Text(mood == "paper" ? "通透浅蓝与四色工作区" : "深色面板与柔和工作区插画").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if studioMood == mood { Image(systemName: "checkmark") }
                        }.padding(14).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(studioMood == mood ? 0.6 : 0.2)))
                    }.buttonStyle(.plain)
                }
                Divider()
                Button("管理工作区") { selection = .manageAreas }.buttonStyle(.bordered)
                Button("添加工作区") { areaRequest = WorkspaceSheetRequest(area: nil) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
                Text("员工、项目、任务和工作记录存储在本机。CLI 与远程制作服务使用各自的连接配置。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .search:
            VStack(alignment: .leading, spacing: 19) {
                TextField("名字、职责或任务标题", text: $searchText).textFieldStyle(.roundedBorder).focused($searchFocused).onAppear { searchFocused = true }
                Text("项目").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(store.snapshot.projects.filter { searchText.isEmpty || ($0.name + $0.goal).localizedCaseInsensitiveContains(searchText) }) { project in
                    Button { store.activeProjectID = project.id; page = .projects; selection = nil } label: { Label(project.name, systemImage: "folder").font(.system(size: 12)) }.buttonStyle(.plain)
                }
                Divider()
                Text("员工").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(store.snapshot.employees.filter { searchText.isEmpty || ($0.name + $0.role + $0.department).localizedCaseInsensitiveContains(searchText) }) { employee in employeeRow(employee) }
                Divider()
                Text("任务").font(.system(size: 10)).foregroundStyle(.secondary)
                taskRows(store.visibleTasks.filter { searchText.isEmpty || ($0.title + $0.input).localizedCaseInsensitiveContains(searchText) })
            }
        default:
            VStack(alignment: .leading, spacing: 18) {
                Picker("项目桌", selection: $store.activeProjectID) {
                    Text("未归属项目").tag(Optional<UUID>.none)
                    ForEach(store.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("添加项目") { showProjectSheet = true }.buttonStyle(.bordered)
                Button("让AI安排协作") { showPlannerSheet = true }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.currentProject == nil || !store.snapshot.employees.contains(where: { store.tool($0.toolID)?.adapterKind == .codex }))
                CollaborationPanel(store: store) { selection = .task($0) }
                ForEach(store.snapshot.handoffs.filter { $0.projectID == store.activeProjectID }) { handoff in
                    if let target = handoff.targetTaskID {
                        Button { selection = .task(target) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("交接 → " + (store.employee(handoff.targetEmployeeID)?.name ?? "未知员工"))
                                Text(handoff.goal).foregroundStyle(.secondary)
                                Text("来源 run \(handoff.sourceRunID.uuidString.prefix(8))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                            }.font(.system(size: 11))
                        }.buttonStyle(.plain).disabled(!store.visibleTasks.contains(where: { $0.id == target }))
                    }
                }
                if let project = store.currentProject { Text(project.goal).font(.system(size: 12)).foregroundStyle(.secondary) }
                Text("项目里的每一个想法").font(.system(size: 23, weight: .medium))
                Button("放一个新想法") { newTask() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.snapshot.employees.isEmpty || !store.storageAvailable)
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
    private var knowledgeContent: some View {
        VStack(alignment: .leading, spacing: 23) {
            Label("项目目标", systemImage: "scope").font(.system(size: 16, weight: .semibold))
            Text(store.currentProject?.goal ?? "在项目任务中创建项目，给伙伴一个明确的共同目标。").font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            Label("员工职责", systemImage: "person.text.rectangle").font(.system(size: 16, weight: .semibold))
            Text("汇集工作室中已配置的职责说明。点击员工即可编辑。").font(.system(size: 12)).foregroundStyle(.secondary)
            if store.snapshot.employees.isEmpty { Text("添加员工后，它的职责说明会出现在这里。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(store.snapshot.employees) { employee in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(employee.instructions.isEmpty ? "尚未填写职责说明。" : employee.instructions).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                        Button("查看与编辑员工") { selection = .employee(employee.id) }.buttonStyle(.bordered)
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
                Button("让 AI 安排协作") { showPlannerSheet = true }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.currentProject == nil || !store.snapshot.employees.contains { $0.enabled != false && store.tool($0.toolID)?.adapterKind == .codex && store.tool($0.toolID)?.isEnabled == true })
            }
            Text("先生成分工计划，确认负责人、依赖与验收方式，再启动协作。").font(.system(size: 12)).foregroundStyle(.secondary)
            if store.snapshot.plans.filter({ $0.projectID == store.activeProjectID }).isEmpty {
                Text(store.currentProject == nil ? "请先创建并选择一个项目。" : "这个项目还没有协作计划。").font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 15)
                if store.currentProject == nil { Button("创建项目") { showProjectSheet = true }.buttonStyle(.bordered) }
            }
            CollaborationPanel(store: store) { selection = .task($0) }
            Divider()
            Label("员工交接", systemImage: "arrow.triangle.branch").font(.system(size: 16, weight: .semibold))
            let handoffs = store.snapshot.handoffs.filter { $0.projectID == store.activeProjectID }
            if handoffs.isEmpty { Text("任务产物验收后，可从任务详情交给下一位伙伴。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(handoffs) { handoff in
                if let target = handoff.targetTaskID {
                    Button { selection = .task(target) } label: { Label(handoff.goal + " → " + (store.employee(handoff.targetEmployeeID)?.name ?? "未知员工"), systemImage: "arrow.right").font(.system(size: 12)) }.buttonStyle(.plain).disabled(!store.visibleTasks.contains { $0.id == target })
                }
            }
        }
    }
    private func employeeRow(_ employee: Employee) -> some View {
        Button { selection = .employee(employee.id) } label: {
            HStack {
                EmployeePortrait(symbol: employee.avatarSymbol, imageData: employee.avatarImageData, fallback: String(employee.name.prefix(1)), tint: accent).frame(width: 33, height: 33)
                VStack(alignment: .leading, spacing: 5) { Text(employee.name).font(.system(size: 12)); Text(employee.role).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10))
            }.padding(.vertical, 8)
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func taskRows(_ tasks: [WorkTask]) -> some View {
        if tasks.isEmpty { Text("还没有任务，可以先放一个新想法。").font(.system(size: 12)).foregroundStyle(.secondary) }
        ForEach(tasks) { task in
            Button { selection = .task(task.id) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text(task.title).font(.system(size: 12)).multilineTextAlignment(.leading); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    HStack { Text(store.employee(task.employeeID)?.name ?? "未知员工").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); StatusBadge(status: task.status) }
                    Divider()
                }.padding(.vertical, 7)
            }.buttonStyle(.plain)
        }
    }
    private func newConfiguration(_ kind: SheetKind) { preferredEmployee = nil; preferredDepartment = nil; editingEmployee = nil; editingTool = nil; sheet = kind }
    private func newTask(employee: UUID? = nil, input: String = "") { taskSeed = input; preferredEmployee = employee; preferredDepartment = nil; editingEmployee = nil; editingTool = nil; sheet = .task }
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
    private var run: TaskRun? { historyID.flatMap { id in runs.first { $0.id == id } } ?? runs.first }
    private var isHistorical: Bool { historyID != nil && historyID != runs.first?.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            StatusBadge(status: isHistorical ? (run?.status ?? task.status) : task.status)
            Text(task.title).font(.system(size: 19, weight: .semibold))
            Text(task.input).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            if !runs.isEmpty {
                Picker("执行记录", selection: $historyID) {
                    Text("最近一次").tag(Optional<UUID>.none)
                    ForEach(runs) { record in Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.status.title)").tag(Optional(record.id)) }
                }.onChange(of: historyID) { _, _ in loadHistory() }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label(run?.employee.name ?? store.employee(task.employeeID)?.name ?? "未知员工", systemImage: "person")
                Text(run?.workingDirectory ?? task.workingDirectory).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                Button("在Finder中打开工作目录") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: task.workingDirectory) }.buttonStyle(.link)
                Text("验收标准：\(task.acceptance)").foregroundStyle(.secondary)
                if let tool = run?.tool ?? task.toolSnapshot ?? store.employee(task.employeeID).flatMap({ store.tool($0.toolID) }) {
                    Text(tool.remote.map { "服务：" + $0.baseURL + "\n工作流：" + $0.workflowName } ?? "执行：\(tool.executable)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    if tool.adapterKind != .comfyUI {
                        DisclosureGroup("查看执行参数") {
                            Text((run?.arguments ?? tool.executionArguments(input: task.input, instructions: store.employee(task.employeeID)?.instructions ?? "", output: "（本次归档目录）")).map { String(reflecting: $0) }.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Text("超时：\(Int(tool.timeout)) 秒").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let run { Button("查看完整日志与归档") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: run.logPath)]) }.buttonStyle(.link) }
            }.font(.system(size: 11))
            if task.status == .draft, let remote = store.employee(task.employeeID).flatMap({ store.tool($0.toolID) })?.remote {
                Text("工作流：\(remote.workflowName)\n预算：\(remote.budgetNote)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if task.status == .draft {
                Picker("分配草稿", selection: $assignee) { ForEach(store.snapshot.employees.filter { $0.enabled ?? true }) { Text($0.name).tag(Optional($0.id)) } }.onAppear { assignee = task.employeeID }
                Button("确认更换负责人") { confirmAssignee = true }.disabled(assignee == nil || assignee == task.employeeID)
            }
            HStack {
                Text("执行日志").font(.system(size: 12, weight: .medium)); Spacer()
                if task.status == .running { ProgressView().controlSize(.small) }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(isHistorical ? historicalLog : task.log, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("复制最近日志").accessibilityLabel("复制显示的执行日志")
            }
            ReadOnlyTextView(text: isHistorical ? historicalLog : (task.log.isEmpty ? "任务执行后，真实日志会显示在这里。" : task.log), foregroundColor: NSColor(red: 0.77, green: 0.84, blue: 0.93, alpha: 1), backgroundColor: NSColor(red: 0.17, green: 0.23, blue: 0.20, alpha: 1), accessibilityName: "执行日志")
                .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 8))
            if !isHistorical {
                HStack {
                    if task.status == .draft { Button("执行任务") { store.run(task.id) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable) }
                    else if task.status == .running || task.status == .queued { Button(task.status == .queued ? "取消排队" : (run?.tool.adapterKind == .comfyUI ? "停止远程任务" : "停止执行与子进程")) { store.cancel(task.id) }.buttonStyle(.bordered).tint(.red) }
                    else if task.status == .review && task.purpose != .planning { Button("验收通过") { store.accept(task.id) }.buttonStyle(StudioPrimaryButtonStyle()) }
                    Spacer()
                    if let exit = task.exitCode { Text("exit \(exit)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                }
                if task.status == .draft { Button("移出草稿", role: .destructive) { confirmArchive = true }.buttonStyle(.bordered) }
                if task.status == .review && task.purpose != .review && task.purpose != .planning && task.planID != nil { Button("重新提交AI审核") { store.requestReviewAgain(task.id) }.buttonStyle(.bordered) }
                if task.status == .review && task.purpose == .planning {
                    Button("审阅协作计划") { do { planCandidate = try store.planDraft(for: task.id); showPlanApproval = true } catch { store.errorMessage = error.localizedDescription } }.buttonStyle(StudioPrimaryButtonStyle())
                }
                if ![.draft, .running, .queued].contains(task.status) {
                    TextField("返工或重试说明", text: $feedback, axis: .vertical).lineLimit(2...3)
                    if task.status == .interrupted && run?.remotePromptID != nil { Button("查询已有远程执行") { store.resumeRemote(task.id) }.buttonStyle(.bordered) }
                    Button(task.status == .interrupted ? "已检查旧作业，新建执行" : "新建一次执行") { store.run(task.id, feedback: feedback) }.buttonStyle(.bordered).disabled(!store.storageAvailable)
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
                if run.status != .running { Button("导入文件到本次归档") { importFiles(run.id) }.buttonStyle(.bordered) }
                if run.status == .completed && task.status == .completed { Button("交给下一位员工") { showHandoff = true }.buttonStyle(StudioPrimaryButtonStyle()) }
            }
        }.font(.system(size: 11))
        .sheet(isPresented: $showPlanApproval) { if let planCandidate, let projectID = task.projectID { PlanApprovalSheet(draft: planCandidate, planningTaskID: task.id, projectID: projectID, store: store) } }
        .sheet(isPresented: $showHandoff) { if let run { HandoffConfigurationSheet(task: task, run: run, store: store) } }
        .alert("更换草稿负责人？", isPresented: $confirmAssignee) { Button("取消", role: .cancel) {}; Button("确认") { if let assignee { store.assignDraft(task.id, to: assignee) } } } message: { Text("任务仍保留为草稿。") }
        .alert("移出这个草稿？", isPresented: $confirmArchive) { Button("取消", role: .cancel) {}; Button("移出草稿", role: .destructive) { if store.archiveDraft(task.id) { onDraftArchived() } } } message: { Text("可在项目桌的“已移出草稿”中恢复。") }
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
    var employeeToEdit: Employee? = nil
    var toolToEdit: ToolConfig? = nil
    var initialTaskInput: String = ""
    var onTaskSaved: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var path = ""
    @State private var arguments = ""
    @State private var role = ""
    @State private var workspaceID: UUID?
    @State private var input = ""
    @State private var acceptance = ""
    @State private var toolID: UUID?
    @State private var employeeID: UUID?
    @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var avatarSymbol: String?
    @State private var avatarImageData: Data?
    @State private var avatarError: String?
    @State private var adapter = ToolAdapter.command
    @State private var timeout = 1800.0
    @State private var workspaceWrite = false
    @State private var projectID: UUID?
    @State private var versionArguments = "--version"
    @State private var loginStatusArguments = ""
    @State private var loginArguments = ""

    private var title: String { kind == .tool ? (toolToEdit == nil ? "添加CLI工具" : "配置工具") : (kind == .employee ? (employeeToEdit == nil ? "新增AI员工" : "配置员工档案") : "新建任务") }
    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.storageAvailable else { return false }
        switch kind {
        case .tool: return timeout.isFinite && (0.1...86400).contains(timeout) && path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path)
        case .employee: return toolID != nil && workspaceID != nil && !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .task:
            var isDirectory: ObjCBool = false
            return employeeID != nil && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && workingDirectory.hasPrefix("/") && FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: kind == .tool ? "terminal" : (kind == .employee ? "person.badge.plus" : "list.bullet.clipboard"))
                    .font(.system(size: 20)).foregroundStyle(Theme.blue).frame(width: 45, height: 45).background(Theme.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    Text("明确配置，再开始执行。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Form {
                TextField(kind == .task ? "任务标题" : "名称", text: $name)
                switch kind {
                case .tool:
                    Picker("工具类型", selection: $adapter) { Text("通用 CLI").tag(ToolAdapter.command); Text("Codex").tag(ToolAdapter.codex) }
                    HStack {
                        TextField("可执行绝对路径", text: $path)
                        Button("选择文件") { choose(directory: false) { path = $0 } }
                    }
                    TextField("超时（秒）", value: $timeout, format: .number)
                    TextField("版本检测参数，每行一项", text: $versionArguments, axis: .vertical).lineLimit(1...3)
                    if adapter == .codex { Toggle("允许在项目目录写入", isOn: $workspaceWrite); Text("默认只读；保留 Codex 自身权限控制。结果自动归档。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if adapter == .command {
                        TextField("登录检测参数，每行一项（可选）", text: $loginStatusArguments, axis: .vertical).lineLimit(1...2)
                        TextField("登录参数，每行一项（可选）", text: $loginArguments, axis: .vertical).lineLimit(1...2)
                        Text("检测命令退出码0表示已登录，其他结果显示检测失败。").font(.system(size: 10)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 7) {
                        Text("参数列表，每行一项").font(.system(size: 12))
                        TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 110).padding(7).overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.25)))
                        Text("{input}替换为完整输入，不进行shell展开。产物目录可用 {output}，也会传入 MYWORKBENCH_OUTPUT_DIR。任务执行使用非交互模式；交互操作从员工终端发起。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    }
                case .employee:
                    avatarConfiguration
                    TextField("职位", text: $role)
                    Picker("工作区", selection: $workspaceID) { ForEach(store.workspaces) { Text($0.name).tag(Optional($0.id)) } }
                    Picker("绑定工具", selection: $toolID) { ForEach(store.snapshot.tools) { Text($0.name).tag(Optional($0.id)) } }
                    TextField("职责说明", text: $input, axis: .vertical).lineLimit(3...5)
                case .task:
                    Picker("归属项目", selection: $projectID) {
                        Text("未归属项目").tag(Optional<UUID>.none)
                        ForEach(store.snapshot.projects) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: projectID) { _, value in if let project = store.snapshot.projects.first(where: { $0.id == value }) { workingDirectory = project.directory } }
                    Picker("负责人", selection: $employeeID) { ForEach(store.snapshot.employees.filter { $0.enabled ?? true }) { Text($0.name).tag(Optional($0.id)) } }
                    HStack {
                        TextField("工作目录", text: $workingDirectory)
                        Button("选择目录") { choose(directory: true) { workingDirectory = $0 } }
                    }
                    TextField("任务输入", text: $input, axis: .vertical).lineLimit(3...6)
                    TextField("验收标准", text: $acceptance, axis: .vertical).lineLimit(2...3)
                }
            }.formStyle(.grouped)
            if kind == .tool { Text("CLI在本机用户权限下运行。工作目录不会限制工具访问其他文件。").font(.system(size: 10)).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { submit() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 600).frame(maxHeight: 660)
        .onChange(of: adapter) { _, value in
            if value == .codex && path.isEmpty {
                path = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
                if name.isEmpty { name = "Codex" }
            }
        }
        .onAppear {
            toolID = store.snapshot.tools.first?.id
            employeeID = preferredEmployeeID ?? store.snapshot.employees.first(where: { $0.enabled != false })?.id
            workspaceID = store.workspaces.first(where: { $0.name == preferredDepartment })?.id ?? WorkArea.defaults[2].id
            if !store.workspaces.contains(where: { $0.id == workspaceID }) { workspaceID = store.workspaces.first?.id }
            projectID = store.activeProjectID; workingDirectory = store.currentProject?.directory ?? workingDirectory
            if kind == .task { input = initialTaskInput; name = String(initialTaskInput.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(40) ?? "") }
            if let toolToEdit { name = toolToEdit.name; path = toolToEdit.executable; arguments = toolToEdit.arguments.joined(separator: "\n"); adapter = toolToEdit.adapterKind; timeout = toolToEdit.timeout; workspaceWrite = toolToEdit.codexWorkspaceWrite ?? false; versionArguments = (toolToEdit.versionArguments ?? ["--version"]).joined(separator: "\n"); loginStatusArguments = (toolToEdit.loginStatusArguments ?? []).joined(separator: "\n"); loginArguments = (toolToEdit.loginArguments ?? []).joined(separator: "\n") }
            if let employeeToEdit {
                name = employeeToEdit.name; role = employeeToEdit.role; workspaceID = employeeToEdit.workspaceID
                toolID = employeeToEdit.toolID; input = employeeToEdit.instructions
                avatarSymbol = employeeToEdit.avatarSymbol; avatarImageData = employeeToEdit.avatarImageData
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
                    }.buttonStyle(.bordered).tint(avatarImageData == nil && (avatarSymbol ?? "initials") == preset ? Theme.blue : .secondary)
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
        case .tool:
            var tool = ToolConfig(id: toolToEdit?.id ?? UUID(), name: name, executable: path, arguments: arguments.components(separatedBy: .newlines).filter { !$0.isEmpty })
            tool.adapter = adapter; tool.timeoutSeconds = min(86400, max(0.1, timeout)); tool.codexWorkspaceWrite = workspaceWrite
            tool.enabled = toolToEdit?.enabled; tool.versionArguments = versionArguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
            tool.loginStatusArguments = loginStatusArguments.components(separatedBy: .newlines).filter { !$0.isEmpty }; tool.loginArguments = loginArguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
            saved = toolToEdit == nil ? store.addTool(tool) : store.updateTool(tool)
        case .employee:
            guard let toolID else { return }
            var employee = Employee(id: employeeToEdit?.id ?? UUID(), name: name, role: role, department: store.workspaces.first(where: { $0.id == workspaceID })?.name ?? "", instructions: input, toolID: toolID, avatarSymbol: avatarSymbol, avatarImageData: avatarImageData)
            employee.enabled = employeeToEdit?.enabled; employee.workspaceID = workspaceID
            saved = employeeToEdit == nil ? store.addEmployee(employee) : store.updateEmployee(employee)
        case .task:
            guard let employeeID else { return }
            var task = WorkTask(title: name, employeeID: employeeID, input: input, workingDirectory: workingDirectory, acceptance: acceptance)
            task.projectID = projectID; saved = store.addTask(task)
            if saved { createdTaskID = task.id }
        }
        if saved { if let createdTaskID { onTaskSaved(createdTaskID) }; dismiss() }
    }
}
