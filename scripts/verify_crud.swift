import AppKit
import SwiftUI
import SwiftTerm

/// Exercises the same store used by the UI against an isolated database, with a local printf CLI.
@main struct CRUDVerification {
    static func check(_ value: Bool, _ reason: String) { precondition(value, reason) }
    @MainActor static func wait(_ reason: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        check(condition(), "Timed out: " + reason)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = projectRoot.appendingPathComponent("work/crud-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("workspace.sqlite")
        let store = WorkbenchStore(fileURL: database)
        var checks: [String] = []
        var cli = ToolConfig(name: "本地测试 CLI", executable: "/usr/bin/printf", arguments: ["%s", "{prompt}"])
        cli.versionArguments = []; cli.timeoutSeconds = 10
        check(store.addTool(cli), "Add CLI")
        cli.name = "通用 CLI"; check(store.updateTool(cli), "Edit CLI")
        let backup = ToolConfig(name: "备用 CLI", executable: "/usr/bin/printf", arguments: ["%s", "{prompt}"])
        check(store.addTool(backup), "Add backup")
        let area = WorkArea(name: "产品研发", icon: "terminal", color: "658398")
        check(store.addWorkspace(area), "Add workspace")
        var employee = Employee(name: "开发员工", role: "工程师", department: "", instructions: "初始职责", toolID: cli.id)
        employee.workspaceID = area.id
        check(store.addEmployee(employee), "Add employee")
        employee.name = "研发员工"; employee.instructions = "更新后的职责"
        check(store.updateEmployee(employee), "Edit employee")
        check(store.employee(employee.id)?.instructions == "更新后的职责", "Employee saved under same ID")
        checks.append("员工和 CLI 新增、读取、编辑保持原编号")
        let codeArea = WorkArea.defaults[2]
        check(store.addExistingEmployee(employee.id, to: codeArea.id), "Add membership")
        check(store.addExistingEmployee(employee.id, to: codeArea.id), "Idempotent membership")
        check(store.employees(in: codeArea).filter { $0.id == employee.id }.count == 1, "No duplicate")
        check(store.removeEmployee(employee.id, from: area.id), "Remove primary")
        check(store.employee(employee.id)?.workspaceID == codeArea.id, "Promote secondary")
        check(store.removeEmployee(employee.id, from: codeArea.id), "Remove last membership")
        check(store.unassignedEmployees.map(\.id).contains(employee.id), "Unassigned stays visible")
        let unassignedReload = WorkbenchStore(fileURL: database)
        check(unassignedReload.unassignedEmployees.contains { $0.id == employee.id }, "Restart does not recreate membership")
        check(store.addExistingEmployee(employee.id, to: area.id), "Reassign")
        checks.append("工作区添加已有员工不重复，移出主工作区自动改用其他归属，移出最后一个后重启仍为未分配")
        var app = WorkProject(name: "增删改查验证", directory: root.path, goal: "验证持久化")
        app.moduleIDs = [area.id]
        check(store.addProject(app), "Add project")
        app.goal = "修改后的目标"; check(store.updateProject(app), "Edit project")
        let category = ProjectCategory(name: "临时分类")
        check(store.addCategory(category), "Category")
        check(store.moveProject(app.id, to: category.id), "Categorize")
        store.deleteCategory(category.id)
        check(store.project(app.id)?.categoryID == nil, "Category removal preserves project")
        checks.append("项目可编辑，分类删除后项目移到未分类")
        var task = WorkTask(title: "首次任务", employeeID: employee.id, input: "原输入", workingDirectory: root.path, acceptance: "原验收条件")
        task.projectID = app.id
        check(store.addTask(task), "Add task")
        store.run(task.id)
        check(!store.deleteObject(DeletionTarget(.employee, employee.id)), "Running employee protected")
        check(!store.deleteObject(DeletionTarget(.task, task.id)), "Running task protected")
        check(!store.deleteObject(DeletionTarget(.project, app.id)), "Running project protected")
        try await wait("task result") { store.snapshot.tasks.first { $0.id == task.id }?.status == .review && store.activeRuns.isEmpty }
        let historicalRun = store.runs(for: task.id).first!
        check(historicalRun.input == "原输入" && historicalRun.acceptance == "原验收条件", "Real CLI run completed")
        task = store.snapshot.tasks.first { $0.id == task.id }!
        task.title = "修改后的任务"; task.input = "更新输入"; task.acceptance = "更新验收条件"
        check(store.updateTask(task), "Edit existing task")
        check(store.snapshot.tasks.first { $0.id == task.id }?.status == .draft, "Edit creates pending draft")
        check(store.runs(for: task.id) == [historicalRun], "Run snapshot remains immutable")
        checks.append("执行中的员工、任务和项目不能删除；普通任务可修改后重新执行，原执行快照保留")
        let originalFile = root.appendingPathComponent("交付.txt")
        try "原始产物内容".write(to: originalFile, atomically: true, encoding: .utf8)
        store.importArtifact(originalFile, runID: historicalRun.id)
        let artifact = store.artifacts(for: historicalRun.id).first!
        let archiveFile = try store.archive.url(for: artifact)
        check(store.renameArtifact(artifact.id, to: "交付说明"), "Rename artifact")
        check(store.artifacts(for: historicalRun.id).first?.name == "交付说明", "Visible label")
        check(store.deleteObject(DeletionTarget(.artifact, artifact.id)), "Delete artifact")
        try store.refreshArtifacts(runID: historicalRun.id); check(store.save(), "Save refreshed metadata")
        check(store.artifacts(for: historicalRun.id).isEmpty, "Rescan does not resurrect")
        check(FileManager.default.fileExists(atPath: archiveFile.path), "Archive retained")
        checks.append("产物重命名不改变文件，删除后重新扫描不复活，归档原文件保留")
        let conversationID = store.sendMessage("验证对话", projectID: app.id, conversationID: nil, agentIDs: [employee.id], mode: .single, access: .readOnly)!
        try await wait("chat") { store.snapshot.messages(in: conversationID).last?.state == .replied && store.activeTurns.isEmpty }
        store.renameConversation(conversationID, to: "新对话名称")
        check(store.conversation(conversationID)?.title == "新对话名称", "Rename chat")
        check(store.deleteObject(DeletionTarget(.conversation, conversationID)), "Delete chat")
        let messageCount = store.snapshot.messages.count
        let deletedReply = store.snapshot.messages(in: conversationID).last!.id
        check(!store.retryTurn(deletedReply, newSession: true) && store.promoteToTask(deletedReply) == nil, "Deleted chat rejects cached retry and promotion")
        check(store.sendMessage("缓存界面不能续发", projectID: app.id, conversationID: conversationID, agentIDs: [employee.id], mode: .single, access: .readOnly) == nil, "Deleted chat rejects sends")
        check(store.snapshot.messages.count == messageCount, "Messages retained")
        checks.append("对话可重命名、删除；历史消息保留，删除后的旧界面不能继续发送")
        var server = ComfyServer(name: "临时服务器", baseURL: "http://127.0.0.1:1")
        check(store.saveServer(server, token: nil), "Add server")
        server.name = "更新服务器"; check(store.saveServer(server, token: nil), "Edit server")
        let workflow = Data(#"{"9":{"class_type":"SaveImage","inputs":{}}}"#.utf8)
        var template = WorkflowTemplate(name: "临时模板", moduleIDs: [area.id], workflow: workflow, outputs: [TemplateOutput(nodeID: "9", kind: .image)])
        check(store.saveTemplate(template), "Add template")
        template.name = "更新模板"; check(store.saveTemplate(template), "Edit template")
        check(store.deleteObject(DeletionTarget(.server, server.id)), "Delete server")
        check(store.deleteObject(DeletionTarget(.template, template.id)), "Delete template")
        check(!store.saveServer(server, token: nil) && !store.saveTemplate(template), "Cached editor cannot resurrect resources")
        checks.append("服务器和工作流模板可新增、编辑、删除，旧编辑页不能重新保存已删除资源")
        // Plan fixtures deliberately skip execution to isolate plan removal from CLI planning behavior.
        var step = WorkTask(title: "停止的计划步骤", employeeID: employee.id, input: "步骤", workingDirectory: root.path, acceptance: "通过")
        let plan = CollaborationPlan(projectID: app.id, title: "计划", goal: "目标", taskIDs: [step.id])
        step.planID = plan.id; step.status = .cancelled
        check(store.change { $0.plans.append(plan); $0.tasks.append(step) }, "Plan fixture")
        check(store.renamePlan(plan.id, to: "修改后的计划"), "Rename plan")
        check(!store.deleteObject(DeletionTarget(.task, step.id)), "Plan step deletion protected")
        check(store.deleteObject(DeletionTarget(.plan, plan.id)), "Delete stopped plan")
        check(!store.visibleTasks.contains { $0.id == step.id }, "Plan steps removed")
        checks.append("计划可重命名、删除；计划步骤须随计划删除，停止后的步骤从任务列表移除")
        check(!store.deleteObject(DeletionTarget(.tool, cli.id)), "Bound CLI protected")
        employee = store.employee(employee.id)!; employee.toolID = backup.id
        check(store.updateEmployee(employee), "Rebind CLI")
        check(store.deleteObject(DeletionTarget(.tool, cli.id)), "Delete unbound CLI")
        check(historicalRun.tool.id == cli.id && store.runs(for: task.id).first?.employee.toolID == cli.id, "Snapshots retain former CLI")
        checks.append("绑定员工的 CLI 不能删除，更换绑定后可删；旧执行仍保留原员工与 CLI 快照")

        // Render actual SwiftUI management surfaces before removal, using a separate terminal metadata file.
        store.errorMessage = nil
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
        let suite = "Workbench.CRUD.QA.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        let shots = output.appendingPathComponent("snapshots"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        var screenshots: [String] = []
        func render(_ name: String, _ view: some View, width: CGFloat = 1440, height: CGFloat = 1000) async throws {
            hosting.rootView = AnyView(view.defaultAppStorage(preferences).id(name))
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 700_000_000); hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let target = shots.appendingPathComponent(name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: target); screenshots.append(target.path)
        }
        try await render("employees", WorkbenchView(terminals: terminals, initialPage: .employees, store: store))
        try await render("workspace", WorkbenchView(terminals: terminals, initialSelection: .workspace(area.id), store: store))
        try await render("employee-edit", ConfigurationSheet(kind: .employee, store: store, employeeToEdit: store.employee(employee.id)), width: 620, height: 740)
        try await render("task-edit", ConfigurationSheet(kind: .task, store: store, taskToEdit: store.snapshot.tasks.first { $0.id == task.id }), width: 620, height: 740)
        try await render("workspace-members", WorkspaceMemberPicker(store: store, area: codeArea), width: 600, height: 500)
        try await render("tools", WorkbenchView(terminals: terminals, initialPage: .tools, store: store))
        window.orderOut(nil); terminals.endAll()

        check(store.deleteObject(DeletionTarget(.workspace, area.id)), "Delete workspace")
        check(store.unassignedEmployees.contains { $0.id == employee.id }, "Workspace deletion leaves employee")
        check(store.project(app.id)?.moduleIDs == [], "Workspace module removed")
        check(store.deleteObject(DeletionTarget(.employee, employee.id)), "Delete employee globally")
        check(store.snapshot.employees.current.isEmpty, "All memberships hidden")
        check(!store.updateEmployee(employee), "Cached employee editor cannot resurrect")
        check(store.deleteObject(DeletionTarget(.task, task.id)), "Delete independent task")
        check(store.deleteObject(DeletionTarget(.project, app.id)), "Delete project")
        check(FileManager.default.fileExists(atPath: originalFile.path), "Project files retained")
        let loaded = WorkbenchStore(fileURL: database)
        check(loaded.storageAvailable && loaded.snapshot.employees.current.isEmpty && loaded.visibleTasks.isEmpty && loaded.activeProjects.isEmpty, "Restart keeps lists empty")
        check(loaded.snapshot.servers.current.isEmpty && loaded.snapshot.templates.current.isEmpty && loaded.snapshot.plans.current.isEmpty && loaded.snapshot.artifacts.current.isEmpty && loaded.snapshot.conversations.current.isEmpty, "All resources stay deleted")
        check(!loaded.workspaces.contains { $0.id == area.id } && !loaded.cliTools.contains { $0.id == cli.id }, "Deleted config stays removed")
        check(loaded.runs(for: task.id).first == historicalRun && loaded.snapshot.messages.count == messageCount, "History persists unchanged")
        checks.append("工作区删除保留员工并移除模块关联；全局员工、任务、项目删除后重启不复活，文件与历史执行保留")
        let report: [String: Any] = ["passed": true, "workspace": root.path, "checks": checks, "screenshots": screenshots,
            "limitations": ["隔离数据库与本地 printf CLI；计划以停止状态植入；原生界面为离屏渲染，未代替人工点击验收。"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("crud-verification.json"))
        for line in checks { print("✓ " + line) }
        print("CRUD verification passed: \(checks.count) checks, \(screenshots.count) snapshots")
        exit(0)
    }
}
