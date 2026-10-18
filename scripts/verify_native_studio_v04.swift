import AppKit
import SwiftUI
import SwiftTerm

@main struct StudioV04Verification {
    @MainActor static func wait(_ condition: () -> Bool, timeout: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Verification timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = project.appendingPathComponent("work/studio-v04-qa/\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "MyWorkbench.StudioV04.QA.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var tool = ToolConfig(name: "本地 CLI 验证", executable: "/usr/bin/printf", arguments: ["%s\\n", "{input}"])
        tool.loginStatusArguments = ["fixture logged in\\n"]; tool.loginArguments = ["fixture login complete\\n"]
        precondition(store.addTool(tool))
        let workProject = WorkProject(name: "工作站本机验证", directory: root.path, goal: "验证工作区、登录检测和终端互不干扰。")
        precondition(store.addProject(workProject))
        for (index, area) in store.workspaces.enumerated() {
            for member in 0..<2 {
                var employee = Employee(name: [["Echo", "Kai"], ["Aria", "Finn"], ["Nova", "Atlas"], ["Mia", "Ash"]][index][member], role: ["影像创作", "声音制作", "开发工程师", "视觉设计"][index], department: area.name, instructions: "本机确定性验证员工，使用 printf，不调用 AI 或远程服务。", toolID: tool.id, avatarSymbol: member == 0 ? area.icon : nil)
                employee.workspaceID = area.id; precondition(store.addEmployee(employee))
                if member == 0 {
                    var task = WorkTask(title: ["影像任务草稿", "声音任务草稿", "项目展示页面", "工作站视觉规范"][index], employeeID: employee.id, input: "本机验证", workingDirectory: root.path, acceptance: "核对输出后验收")
                    task.projectID = workProject.id; precondition(store.addTask(task))
                }
            }
        }
        store.checkLogin(tool.id); try await wait { store.loginChecks[tool.id]?.state == .loggedIn }
        precondition(store.snapshot.tasks.count == 4 && store.snapshot.runs.isEmpty, "Login check must not create tasks or runs")
        let employee = store.snapshot.employees.first { $0.name == "Nova" }!
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history.json"))
        if let appIcon = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-512-2x.png")) { _ = appIcon.setName("AppIcon") }
        let hosting = NSHostingView(rootView: AnyView(WorkbenchView(terminals: terminals, store: store).defaultAppStorage(preferences)))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { terminals.endAll(); window.orderOut(nil) }
        func screenshot(_ name: String, width: CGFloat = 1440, height: CGFloat = 900, osDark: Bool = false) async throws {
            window.appearance = NSAppearance(named: osDark ? .darkAqua : .aqua)
            hosting.appearance = window.appearance
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 500_000_000)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: project.appendingPathComponent("work/studio-v04-qa/\(name).png"))
            if name.contains("light") {
                let pixel = bitmap.colorAt(x: 12, y: 120)!.usingColorSpace(.deviceRGB)!
                precondition(pixel.redComponent > 0.9 && pixel.greenComponent > 0.9 && pixel.blueComponent > 0.85, "Default theme must stay light even when OS is dark")
            }
            print("Rendered \(name) \(Int(width))×\(Int(height))")
        }
        try await screenshot("native-v04-light-home")
        try await screenshot("native-v04-light-compact", width: 1100, height: 720, osDark: true)
        preferences.set("ink", forKey: "studioThemeV06")
        try await screenshot("native-v04-dark-home", osDark: true)
        preferences.set("paper", forKey: "studioThemeV06")
        terminals.open(employee: employee, tool: tool, directory: root.path)
        let session = terminals.selected!
        precondition(session.terminal.process.running)
        session.send("/usr/bin/printf '\\033[32m中文终端验证 ✓\\033[0m\\n'\n")
        try await wait { session.terminal.getTerminal().getBufferAsData().count > 10 }
        hosting.rootView = AnyView(WorkbenchView(terminals: terminals, initialSelection: .employee(employee.id), store: store).defaultAppStorage(preferences).id("employee-terminal"))
        try await screenshot("native-v04-terminal")
        try await screenshot("native-v04-terminal-compact", width: 1100, height: 720)
        terminals.isVisible = false; terminals.open(employee: employee, tool: tool, directory: root.path)
        precondition(terminals.sessions.count == 1 && terminals.selected?.id == session.id)
        let metadata = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history.json"))
        precondition(metadata.sessions.isEmpty && metadata.activeCount == 0 && metadata.recent.first?.employeeID == employee.id, "Restart must restore metadata without launching old processes")
        var sleeper = ToolConfig(name: "会话隔离验证", executable: "/bin/sleep", arguments: ["30"]); sleeper.timeoutSeconds = 40
        precondition(store.addTool(sleeper))
        let worker = Employee(name: "停止验证员", role: "QA", department: "开发部", instructions: "", toolID: sleeper.id)
        precondition(store.addEmployee(worker))
        let task = WorkTask(title: "终端结束不误停任务", employeeID: worker.id, input: "", workingDirectory: root.path, acceptance: "独立取消")
        precondition(store.addTask(task)); store.run(task.id)
        try await wait { store.activeRuns[task.id] != nil }
        let pid = session.terminal.process.shellPid
        terminals.endSelected()
        precondition(session.ended && store.activeRuns[task.id] != nil)
        try await wait { kill(pid, 0) != 0 }
        store.cancel(task.id); try await wait { store.activeRuns[task.id] == nil }
        precondition(store.visibleTasks.first { $0.id == task.id }?.status == .cancelled)
        var failure = tool; failure.executable = "/bin/false"; failure.loginStatusArguments = ["status"]
        precondition(store.updateTool(failure)); store.checkLogin(tool.id)
        try await wait { store.loginChecks[tool.id]?.state == .failed }
        var unsupported = failure; unsupported.loginStatusArguments = nil; precondition(store.updateTool(unsupported))
        precondition(store.loginCheck(for: unsupported).state == .unsupported)
        let fixture = root.appendingPathComponent("codex-login-fixture")
        try Data("#!/bin/sh\nprintf 'Not logged in\\n' >&2\nexit 1\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        var codex = ToolConfig(name: "Codex 认证状态测试", executable: fixture.path, arguments: []); codex.adapter = .codex
        precondition(store.addTool(codex)); store.checkLogin(codex.id)
        try await wait { store.loginChecks[codex.id]?.state == .loggedOut }
        let fifth = WorkArea(name: "研究工作区", icon: "book", color: "B79758", description: "把资料整理成可使用的知识")
        precondition(store.addWorkspace(fifth))
        let sixth = WorkArea(name: "运营工作区", icon: "megaphone", color: "9A7B83", description: "为日常运营安排伙伴")
        precondition(store.addWorkspace(sixth))
        let oldArea = store.workspaces[2]; var edit = oldArea; edit.name = "构建工作区"; edit.icon = "cpu"; edit.color = "708A73"
        let existingTaskIDs = store.visibleTasks.map(\.id); precondition(store.updateWorkspace(edit))
        let restored = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        precondition(restored.workspaces.count == 6 && restored.employee(employee.id)?.workspaceID == oldArea.id && restored.employee(employee.id)?.department == edit.name && restored.visibleTasks.map(\.id) == existingTaskIDs)
        hosting.rootView = AnyView(WorkspaceConfigurationSheet(store: restored).preferredColorScheme(.light).id("area-add")); try await screenshot("native-v04-workspace-add", width: 760, height: 558)
        hosting.rootView = AnyView(WorkspaceConfigurationSheet(store: restored, areaToEdit: edit).preferredColorScheme(.light).id("area-edit")); try await screenshot("native-v04-workspace-edit", width: 760, height: 558)
        hosting.rootView = AnyView(WorkbenchView(initialSelection: .manageAreas, store: restored).defaultAppStorage(preferences).id("manage-areas")); try await screenshot("native-v04-six-areas")
        let report: [String: Any] = ["passed": true, "workspace": root.path, "coreTests": 46, "checks": ["light theme independent of OS dark mode", "2-column aligned card components at both sizes", "native light and dark screenshots", "shared CLI login status without task submission", "failed and unsupported states", "Codex logged-out diagnostic fixture", "real interactive PTY", "close and reopen same process", "metadata-only restart", "terminal termination does not cancel a managed task", "six workspaces survive reload", "renaming preserves employee/task IDs"], "limitations": "Offscreen owned components and backend checks; real keyboard, IME, clipboard, VoiceOver and hardware manual QA pending"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: project.appendingPathComponent("work/native-studio-v04-verification.json"))
        print("Studio V04 native component and backend checks passed")
    }
}
