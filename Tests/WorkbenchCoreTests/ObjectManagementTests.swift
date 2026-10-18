import XCTest
@testable import WorkbenchCore

final class ObjectManagementTests: XCTestCase {
    private func fixture() -> (WorkspaceSnapshot, Employee, ToolConfig, WorkProject) {
        var snapshot = WorkspaceSnapshot()
        let tool = ToolConfig(name: "CLI", executable: "/usr/bin/true", arguments: [])
        var employee = Employee(name: "工程师", role: "开发", department: WorkArea.defaults[2].name, instructions: "实现", toolID: tool.id)
        employee.workspaceID = WorkArea.defaults[2].id
        let project = WorkProject(name: "项目", directory: "/tmp", goal: "验证")
        snapshot.tools = [tool]; snapshot.employees = [employee]; snapshot.projects = [project]
        return (snapshot, employee, tool, project)
    }

    func testEmployeeRemovalHidesAllMembershipsAndPreservesHistoricalSnapshots() throws {
        var (snapshot, employee, tool, project) = fixture()
        employee.additionalWorkspaceIDs = [WorkArea.defaults[0].id]; snapshot.employees = [employee]
        var task = WorkTask(title: "已完成", employeeID: employee.id, input: "原输入", workingDirectory: "/tmp", acceptance: "原标准")
        task.projectID = project.id; task.status = .completed; task.employeeSnapshot = employee
        var run = TaskRun(task: task, employee: employee, tool: tool, directory: URL(fileURLWithPath: "/tmp/archive")); run.status = .completed
        snapshot.tasks = [task]; snapshot.runs = [run]
        try snapshot.deleteObject(DeletionTarget(.employee, employee.id))
        XCTAssertTrue(snapshot.employees.current.isEmpty)
        XCTAssertFalse(snapshot.employees[0].enabled ?? true)
        XCTAssertEqual(snapshot.tasks[0], task)
        XCTAssertEqual(snapshot.runs[0], run)
        snapshot.migrateWorkspaces()
        XCTAssertTrue(snapshot.employees.current.isEmpty)
    }

    func testAddingExistingEmployeeDoesNotDuplicateMembershipAndRemovingPrimaryPromotesAnother() throws {
        var (snapshot, employee, _, _) = fixture()
        let video = WorkArea.defaults[0], code = WorkArea.defaults[2]
        try snapshot.addEmployee(employee.id, to: video.id)
        try snapshot.addEmployee(employee.id, to: video.id)
        XCTAssertEqual(snapshot.employees[0].additionalWorkspaceIDs, [video.id])
        try snapshot.removeEmployee(employee.id, from: code.id)
        XCTAssertEqual(snapshot.employees[0].workspaceID, video.id)
        XCTAssertEqual(snapshot.employees[0].department, video.name)
        try snapshot.removeEmployee(employee.id, from: video.id)
        snapshot.migrateWorkspaces()
        XCTAssertNil(snapshot.employees[0].workspaceID)
        XCTAssertEqual(snapshot.employees[0].department, "")
        XCTAssertEqual(snapshot.workspaces.count, 4)
        employee = snapshot.employees[0]
        try snapshot.addEmployee(employee.id, to: code.id)
        XCTAssertEqual(snapshot.employees[0].workspaceID, code.id)
    }

    func testDeletingWorkspaceMovesMembersToUnassignedAndRemovesOnlyThatModule() throws {
        var (snapshot, employee, _, project) = fixture()
        let code = WorkArea.defaults[2].id, video = WorkArea.defaults[0].id
        snapshot.projects[0].moduleIDs = [code, video]
        try snapshot.deleteObject(DeletionTarget(.workspace, code))
        XCTAssertEqual(snapshot.workspaces.current.count, 3)
        XCTAssertNil(snapshot.employees[0].workspaceID)
        XCTAssertEqual(snapshot.projects[0].id, project.id)
        XCTAssertEqual(snapshot.projects[0].moduleIDs, [video])
        snapshot.migrateWorkspaces()
        XCTAssertEqual(snapshot.workspaces.current.count, 3)
        XCTAssertEqual(snapshot.employees[0].id, employee.id)
    }

    func testBoundToolCannotBeDeletedButCanAfterEmployeeDeletion() throws {
        var (snapshot, employee, tool, _) = fixture()
        let original = snapshot
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.tool, tool.id)))
        XCTAssertEqual(snapshot, original)
        try snapshot.deleteObject(DeletionTarget(.employee, employee.id))
        try snapshot.deleteObject(DeletionTarget(.tool, tool.id))
        XCTAssertTrue(snapshot.tools.current.isEmpty)
        XCTAssertFalse(snapshot.tools[0].isEnabled)
    }

    func testRunningTaskAndChatBlockEmployeeDeletionWithoutChangingRecords() throws {
        var (snapshot, employee, _, project) = fixture()
        var task = WorkTask(title: "正在执行", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        task.status = .running; snapshot.tasks = [task]
        let original = snapshot
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.employee, employee.id)))
        XCTAssertEqual(snapshot, original)
        snapshot.tasks.removeAll()
        let conversation = Conversation(projectID: project.id, title: "对话")
        var turn = ChatMessage(conversationID: conversation.id, role: .agent, text: "")
        turn.agentID = employee.id; turn.state = .queued; snapshot.conversations = [conversation]; snapshot.messages = [turn]
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.employee, employee.id)))
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.conversation, conversation.id)))
    }

    func testDeletingProjectHidesContentsButKeepsRunsAndMessages() throws {
        var (snapshot, employee, tool, project) = fixture()
        let conversation = Conversation(projectID: project.id, title: "历史")
        let message = ChatMessage(conversationID: conversation.id, role: .user, text: "原请求")
        var task = WorkTask(title: "历史任务", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        task.projectID = project.id; task.status = .completed
        var run = TaskRun(task: task, employee: employee, tool: tool, directory: URL(fileURLWithPath: "/tmp/archive")); run.status = .completed
        let artifact = WorkArtifact(taskID: task.id, runID: run.id, projectID: project.id, relativePath: "test.txt", byteCount: 1, fileType: "txt")
        snapshot.tasks = [task]; snapshot.runs = [run]; snapshot.artifacts = [artifact]
        snapshot.conversations = [conversation]; snapshot.messages = [message]
        try snapshot.deleteObject(DeletionTarget(.project, project.id))
        XCTAssertTrue(snapshot.projects.current.isEmpty)
        XCTAssertTrue(snapshot.projects[0].isArchived)
        XCTAssertTrue(snapshot.projects(matching: ProjectFilter()).isEmpty)
        XCTAssertTrue(snapshot.tasks.current.isEmpty)
        XCTAssertTrue(snapshot.artifacts.current.isEmpty)
        XCTAssertTrue(snapshot.conversations.current.isEmpty)
        XCTAssertEqual(snapshot.runs, [run]); XCTAssertEqual(snapshot.messages, [message])
        XCTAssertEqual(snapshot.employees.current.count, 1)
    }

    func testPlanDeletionRequiresStoppingAndRetainsStepHistory() throws {
        var (snapshot, employee, _, project) = fixture()
        var task = WorkTask(title: "步骤", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        var plan = CollaborationPlan(projectID: project.id, title: "计划", goal: "目标", taskIDs: [task.id])
        task.planID = plan.id; task.status = .queued; snapshot.tasks = [task]; snapshot.plans = [plan]
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.plan, plan.id)))
        snapshot.tasks[0].status = .cancelled
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.task, task.id)))
        var review = WorkTask(title: "审核步骤", employeeID: employee.id, input: "审核", workingDirectory: "/tmp", acceptance: "通过")
        review.planID = plan.id; review.purpose = .review; review.status = .running
        snapshot.tasks.append(review)
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.plan, plan.id)))
        snapshot.tasks[1].status = .cancelled
        try snapshot.deleteObject(DeletionTarget(.plan, plan.id))
        XCTAssertTrue(snapshot.plans.current.isEmpty); XCTAssertTrue(snapshot.tasks.current.isEmpty)
        plan = snapshot.plans[0]; XCTAssertTrue(plan.paused)
        XCTAssertEqual(snapshot.tasks[0].id, task.id)
    }

    func testUnresolvedRemoteJobBlocksServerTemplateAndProjectDeletion() throws {
        var (snapshot, employee, tool, project) = fixture()
        let server = ComfyServer(name: "GPU", baseURL: "http://127.0.0.1:1")
        let template = WorkflowTemplate(name: "工作流", workflow: Data("{}".utf8))
        var task = WorkTask(title: "状态未知", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        task.projectID = project.id; task.status = .interrupted
        task.generation = GenerationSpec(templateID: template.id, serverID: server.id, versionHash: template.versionHash)
        var run = TaskRun(task: task, employee: employee, tool: tool, directory: URL(fileURLWithPath: "/tmp/archive"))
        run.remotePromptID = UUID().uuidString; run.status = .interrupted
        snapshot.servers = [server]; snapshot.templates = [template]; snapshot.tasks = [task]; snapshot.runs = [run]
        for target in [DeletionTarget(.server, server.id), DeletionTarget(.template, template.id), DeletionTarget(.project, project.id)] {
            XCTAssertThrowsError(try snapshot.deleteObject(target))
        }
    }

    func testArtifactDeletionProtectsDownstreamAndLeavesFileMetadata() throws {
        var (snapshot, employee, _, _) = fixture()
        let source = WorkTask(title: "来源", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        var downstream = WorkTask(title: "下游", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        downstream.dependencyIDs = [source.id]
        let artifact = WorkArtifact(taskID: source.id, runID: UUID(), projectID: nil, relativePath: "source/file.png", byteCount: 100, fileType: "png", accepted: true)
        snapshot.tasks = [source, downstream]; snapshot.artifacts = [artifact]
        XCTAssertThrowsError(try snapshot.deleteObject(DeletionTarget(.artifact, artifact.id)))
        snapshot.tasks[1].status = .completed
        try snapshot.deleteObject(DeletionTarget(.artifact, artifact.id))
        XCTAssertTrue(snapshot.artifacts.current.isEmpty)
        XCTAssertEqual(snapshot.artifacts[0].relativePath, artifact.relativePath)
        XCTAssertEqual(snapshot.artifacts[0].accepted, artifact.accepted)
    }

    func testDeletedRecordsPersistAndLegacyMigrationDoesNotResurrectThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var (snapshot, employee, _, _) = fixture()
        let area = WorkArea.defaults[2].id
        try snapshot.deleteObject(DeletionTarget(.workspace, area))
        try snapshot.deleteObject(DeletionTarget(.employee, employee.id))
        let persistence = WorkspacePersistence(fileURL: root.appendingPathComponent("workspace.sqlite"))
        try persistence.save(snapshot)
        let loaded = try persistence.load()
        XCTAssertTrue(loaded.employees.current.isEmpty)
        XCTAssertFalse(loaded.workspaces.current.contains { $0.id == area })
        XCTAssertNotNil(loaded.employees[0].deletedAt)
        XCTAssertEqual(loaded.employees[0].id, employee.id)
    }

    func testPendingProductionPlanCannotUseDeletedTemplate() throws {
        var (snapshot, employee, _, _) = fixture()
        let server = ComfyServer(name: "GPU", baseURL: "http://127.0.0.1:1")
        let template = WorkflowTemplate(name: "模板", workflow: Data(#"{"9":{"class_type":"SaveImage","inputs":{}}}"#.utf8))
        snapshot.servers = [server]; snapshot.templates = [template]
        var step = PlanStep(id: "generate", title: "出图", employeeID: employee.id, input: "图", acceptance: "可查看")
        step.kind = .generate; step.templateID = template.id; step.serverID = server.id
        let draft = PlanDraft(title: "制作", goal: "制作图", steps: [step])
        XCTAssertNoThrow(try snapshot.validateProduction(draft, attachments: []))
        try snapshot.deleteObject(DeletionTarget(.template, template.id))
        XCTAssertThrowsError(try snapshot.validateProduction(draft, attachments: []))
    }
}
