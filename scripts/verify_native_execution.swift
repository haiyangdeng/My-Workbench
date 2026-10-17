import Foundation
import AppKit

@main struct NativeExecutionVerification {
    @MainActor static func verifyVersionDetection(_ root: URL) async throws {
        let directory = root.appendingPathComponent("version-probe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("workspace.sqlite")
        let store = WorkbenchStore(fileURL: file)
        var tool = ToolConfig(name: "版本检测验证", executable: "/usr/bin/printf", arguments: [])
        tool.versionArguments = ["%s", "1.2.3"]
        precondition(store.addTool(tool))
        func finishProbe() async throws {
            store.probeTool(tool.id)
            let deadline = Date().addingTimeInterval(12)
            while store.probingTools.contains(tool.id) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(!store.probingTools.contains(tool.id), "Version probe did not finish")
        }
        try await finishProbe()
        precondition(store.tool(tool.id)?.detectedVersion?.contains("1.2.3") == true && store.errorMessage == nil)
        precondition(WorkbenchStore(fileURL: file).tool(tool.id)?.detectedVersion == store.tool(tool.id)?.detectedVersion)
        tool = store.tool(tool.id)!; tool.versionArguments = ["%s", "2.0.0"]
        precondition(store.updateTool(tool)); try await finishProbe()
        let lastSuccessfulVersion = store.tool(tool.id)?.detectedVersion
        precondition(lastSuccessfulVersion?.contains("2.0.0") == true)
        tool = store.tool(tool.id)!; tool.executable = "/bin/sh"
        tool.versionArguments = ["-c", "printf 'version-probe-failure' >&2; exit 7"]
        precondition(store.updateTool(tool)); try await finishProbe()
        precondition(store.errorMessage?.contains("version-probe-failure") == true)
        precondition(store.tool(tool.id)?.detectedVersion == lastSuccessfulVersion)
        precondition(store.snapshot.tasks.isEmpty && store.snapshot.runs.isEmpty)
        print("Tool version detection passed: real process, version-only argv, SQLite reload, updated version, nonzero stderr diagnostic, no task execution")
    }
    @MainActor static func wait(_ store: WorkbenchStore, _ id: UUID, for status: WorkStatus, timeout: Double = 12) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if store.snapshot.tasks.first(where: { $0.id == id })?.status == status { return }
            if let error = store.errorMessage { throw NSError(domain: "QA", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "QA", code: 2, userInfo: [NSLocalizedDescriptionKey: "Task \(id) did not reach \(status); actual \(String(describing: store.snapshot.tasks.first { $0.id == id }?.status))"])
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = project.appendingPathComponent("work/execution-qa/\(UUID())")
        let a = root.appendingPathComponent("project-a"), b = root.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var tool = ToolConfig(name: "归档测试", executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$1\" > \"$MYWORKBENCH_OUTPUT_DIR/result.txt\"; printf '%s' \"$1\"; printf 'stderr-check' >&2", "fixture", "{input}"])
        tool.timeoutSeconds = 10
        precondition(store.addTool(tool))
        var employee = Employee(name: "开发工程师", role: "开发", department: "开发部", instructions: "保留原始输入", toolID: tool.id)
        let reviewer = Employee(name: "验收员", role: "验证", department: "开发部", instructions: "检查产物", toolID: tool.id)
        precondition(store.addEmployee(employee)); precondition(store.addEmployee(reviewer))
        let firstProject = WorkProject(name: "项目 A", directory: a.path), secondProject = WorkProject(name: "项目 B", directory: b.path)
        precondition(store.addProject(firstProject)); precondition(store.addProject(secondProject)); store.activeProjectID = firstProject.id
        var task = WorkTask(title: "归档验收", employeeID: employee.id, input: "中文; $(echo 不展开) `不执行`", workingDirectory: a.path, acceptance: "输出原样保存")
        task.projectID = firstProject.id; precondition(store.addTask(task))
        store.run(task.id); try await wait(store, task.id, for: .review)
        let first = store.runs(for: task.id)[0]
        precondition(store.artifacts(for: first.id).count == 1)
        let firstOutput = try String(contentsOf: store.archive.url(for: store.artifacts(for: first.id)[0]), encoding: .utf8)
        precondition(firstOutput == task.input)
        store.accept(task.id); precondition(store.snapshot.tasks.first { $0.id == task.id }!.status == .completed)
        employee.name = "改名工程师"; precondition(store.updateEmployee(employee))
        store.run(task.id, feedback: "追加验收说明"); try await wait(store, task.id, for: .review)
        let second = store.runs(for: task.id)[0]
        precondition(second.id != first.id && second.employee.name == "改名工程师")
        precondition(store.runs(for: task.id)[1].employee.name == "开发工程师")
        precondition(store.runs(for: task.id)[1].status == .completed)
        let firstLog = try String(contentsOf: URL(fileURLWithPath: first.logPath), encoding: .utf8)
        precondition(firstLog.contains(task.input))
        store.accept(task.id)
        let extra = a.appendingPathComponent("result.txt"); try Data("explicit import".utf8).write(to: extra)
        store.importArtifact(extra, runID: second.id)
        precondition(store.artifacts(for: second.id).count == 2)
        let imported = store.artifacts(for: second.id).first { !$0.accepted }!; store.acceptArtifact(imported.id)
        let handoff = WorkHandoff(sourceTaskID: task.id, sourceRunID: second.id, targetEmployeeID: reviewer.id, projectID: firstProject.id, artifactIDs: store.artifacts(for: second.id).map(\.id), goal: "复核归档结果", acceptance: "引用来源文件并保留旧版本")
        precondition(store.confirmHandoff(handoff)); precondition(!store.confirmHandoff(handoff))
        let downstream = store.snapshot.tasks.first { $0.handoffID == handoff.id }!
        precondition(downstream.status == .draft && downstream.projectID == firstProject.id && downstream.employeeID == reviewer.id)
        precondition(downstream.input.contains(second.outputDirectory))
        precondition(store.activeRuns.isEmpty)
        var waitingTool = ToolConfig(name: "并发验收", executable: "/bin/sleep", arguments: ["0.7"]); waitingTool.timeoutSeconds = 5
        precondition(store.addTool(waitingTool))
        var worker = reviewer; worker.toolID = waitingTool.id; precondition(store.updateEmployee(worker))
        var pendingIDs: [UUID] = []
        store.concurrencyLimit = 2
        for i in 0..<3 {
            let queued = WorkTask(title: "并发 \(i)", employeeID: worker.id, input: "test", workingDirectory: a.path, acceptance: "退出 0")
            precondition(store.addTask(queued)); pendingIDs.append(queued.id); store.run(queued.id)
        }
        precondition(store.activeRuns.count == 2)
        precondition(store.snapshot.tasks.first { $0.id == pendingIDs[2] }!.status == .queued)
        store.cancel(pendingIDs[2]); precondition(store.snapshot.tasks.first { $0.id == pendingIDs[2] }!.status == .cancelled)
        try await wait(store, pendingIDs[0], for: .review); try await wait(store, pendingIDs[1], for: .review)
        let restored = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        precondition(restored.runs(for: task.id).count == 2 && restored.snapshot.handoffs.count == 1 && restored.snapshot.artifacts.count == 3)
        precondition(restored.snapshot.projects.count == 2 && restored.employee(employee.id)?.name == "改名工程师")
        var removable = WorkTask(title: "可恢复草稿", employeeID: employee.id, input: "保留原输入", workingDirectory: a.path, acceptance: "按原编号恢复")
        removable.projectID = firstProject.id; precondition(store.addTask(removable))
        precondition(store.archiveDraft(removable.id))
        precondition(!store.visibleTasks.contains { $0.id == removable.id } && store.archivedDrafts.contains { $0.id == removable.id })
        store.run(removable.id); precondition(store.activeRuns[removable.id] == nil && store.runs(for: removable.id).isEmpty && store.errorMessage?.contains("草稿已移出") == true)
        store.errorMessage = nil
        precondition(!store.assignDraft(removable.id, to: reviewer.id))
        let archived = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        precondition(archived.archivedDrafts.first?.id == removable.id && archived.archivedDrafts.first?.input == removable.input)
        precondition(store.restoreDraft(removable.id))
        precondition(store.snapshot.tasks.first { $0.id == removable.id }! == removable)
        store.run(removable.id); try await wait(store, removable.id, for: .review)
        precondition(!store.archiveDraft(removable.id) && store.runs(for: removable.id).count == 1)
        store.errorMessage = nil
        print("Draft lifecycle passed: recoverable removal, SQLite reload, stable identity and input, execution/reassignment guard, restore, executed-task protection")
        waitingTool.enabled = false; precondition(store.updateTool(waitingTool))
        let beforeDisabled = store.snapshot.runs.count
        store.run(pendingIDs[0]); precondition(store.errorMessage?.contains("工具已停用") == true && store.snapshot.runs.count == beforeDisabled)
        store.errorMessage = nil; waitingTool.enabled = true; precondition(store.updateTool(waitingTool))
        print("Native M2 checks passed: SQLite restart, literal input, stdout/stderr, review, retry versions, employee snapshot, artifact import, handoff draft, duplicate protection, two concurrent runs, queue cancellation")
        try await verifyVersionDetection(root)
        if CommandLine.arguments.contains("--real-codex") {
            let codexPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            _ = try await ProcessRunner().run(id: UUID(), tool: ToolConfig(name: "git", executable: "/usr/bin/git", arguments: ["init", a.path]), input: "", directory: a.path, onOutput: { _ in })
            var codex = ToolConfig(name: "Codex 实际验收", executable: codexPath, arguments: []); codex.adapter = .codex; codex.timeoutSeconds = 90
            precondition(store.addTool(codex))
            let ai = Employee(name: "Codex 验证员", role: "集成验收", department: "开发部", instructions: "只完成明确要求的文本回复。", toolID: codex.id)
            precondition(store.addEmployee(ai))
            var aiTask = WorkTask(title: "Codex 非交互验收", employeeID: ai.id, input: "只回复‘Workbench集成验收通过’。不要调用工具、读取文件或执行命令。", workingDirectory: a.path, acceptance: "真实 Codex 回复指定句子，退出 0，result.md 独立归档")
            aiTask.projectID = firstProject.id; precondition(store.addTask(aiTask)); store.run(aiTask.id)
            try await wait(store, aiTask.id, for: .review, timeout: 100)
            let run = store.runs(for: aiTask.id)[0], artifacts = store.artifacts(for: store.runs(for: aiTask.id)[0].id)
            precondition(artifacts.count >= 1)
            let result = artifacts.first { $0.relativePath.hasSuffix("result.md") }!
            let message = try String(contentsOf: store.archive.url(for: result), encoding: .utf8)
            precondition(message.contains("Workbench集成验收通过"))
            store.accept(aiTask.id)
            print("Real Codex accepted: task \(aiTask.id), run \(run.id), log \(run.logPath)")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--remote-fixture"), CommandLine.arguments.count > index + 1 {
            let serverURL = CommandLine.arguments[index + 1]
            var remote = ToolConfig(name: "ComfyUI HTTP 合约测试", executable: "/usr/bin/true", arguments: [])
            remote.adapter = .comfyUI; remote.timeoutSeconds = 10
            remote.remote = ComfyConnection(baseURL: serverURL, workflow: Data(#"{"1":{"class_type":"Text","inputs":{"text":"{input}"}}}"#.utf8), workflowName: "HTTP fixture")
            precondition(store.addTool(remote))
            let operatorEmployee = Employee(name: "远程执行员", role: "API 验证", department: "视频部", instructions: "", toolID: remote.id)
            precondition(store.addEmployee(operatorEmployee))
            var remoteTask = WorkTask(title: "远程 HTTP 合约测试", employeeID: operatorEmployee.id, input: "success", workingDirectory: a.path, acceptance: "下载完整文件并保留服务编号")
            remoteTask.projectID = firstProject.id; precondition(store.addTask(remoteTask)); store.run(remoteTask.id)
            try await wait(store, remoteTask.id, for: .review)
            let remoteRun = store.runs(for: remoteTask.id)[0], file = store.runs(for: remoteTask.id)[0].remoteArtifacts![0]
            precondition(remoteRun.remotePromptID == remoteRun.id.uuidString.lowercased()); precondition(file.byteCount != nil)
            store.accept(remoteTask.id); precondition(store.errorMessage != nil); store.errorMessage = nil
            store.downloadRemote(runID: remoteRun.id, fileID: file.id)
            for _ in 0..<200 where store.downloadingFiles.contains(file.id) { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(store.runs(for: remoteTask.id)[0].remoteArtifacts![0].localArtifactID != nil)
            let output = store.artifacts(for: remoteRun.id)[0]
            let text = try String(contentsOf: store.archive.url(for: output), encoding: .utf8)
            precondition(text == "ComfyUI contract fixture 中文\n")
            store.accept(remoteTask.id); precondition(store.snapshot.tasks.first { $0.id == remoteTask.id }!.status == .completed)
            let rejected = WorkTask(title: "远程工作流拒绝测试", employeeID: operatorEmployee.id, input: "reject", workingDirectory: a.path, acceptance: "HTTP400明确失败，不记录为不确定中断")
            precondition(store.addTask(rejected)); store.run(rejected.id)
            try await wait(store, rejected.id, for: .failed)
            precondition(store.snapshot.tasks.first { $0.id == rejected.id }!.log.contains("HTTP 400"))
            let cancelled = WorkTask(title: "远程取消合约测试", employeeID: operatorEmployee.id, input: "cancel", workingDirectory: a.path, acceptance: "只取消本次任务")
            precondition(store.addTask(cancelled)); store.run(cancelled.id)
            try await Task.sleep(nanoseconds: 300_000_000); store.cancel(cancelled.id)
            try await wait(store, cancelled.id, for: .cancelled)
            if let t = store.snapshot.tasks.firstIndex(where: { $0.id == remoteTask.id }) { store.snapshot.tasks[t].status = .interrupted }
            if let r = store.snapshot.runs.firstIndex(where: { $0.id == remoteRun.id }) { store.snapshot.runs[r].status = .interrupted }
            precondition(store.save())
            let recovered = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
            recovered.resumeRemote(remoteTask.id); try await wait(recovered, remoteTask.id, for: .review)
            precondition(recovered.runs(for: remoteTask.id).count == 1)
            precondition(recovered.runs(for: remoteTask.id)[0].remoteArtifacts![0].localArtifactID == output.id)
            print("Remote HTTP contract checks passed: stable prompt id, queue/history, size, download integrity, review gate, scoped cancellation, restart query without resubmission, preserved local artifact")
        }
        if CommandLine.arguments.contains("--collaboration") {
            var producer = tool
            producer.id = UUID(); producer.name = "协作产物测试"; precondition(store.addTool(producer))
            let designer = Employee(name: "视觉员工", role: "设计", department: "设计部", instructions: "", toolID: producer.id)
            let builder = Employee(name: "开发员工", role: "开发", department: "开发部", instructions: "", toolID: producer.id)
            precondition(store.addEmployee(designer)); precondition(store.addEmployee(builder))
            let reviewerScript = "if [ ! -f review.once ]; then touch review.once; printf '%s' '{\"decision\":\"rework\",\"notes\":\"补齐交付说明\"}'; else printf '%s' '{\"decision\":\"pass\",\"notes\":\"产物已检查，保留来源执行\"}'; fi > \"$MYWORKBENCH_OUTPUT_DIR/result.json\""
            let reviewTool = ToolConfig(name: "审核协议测试", executable: "/bin/sh", arguments: ["-c", reviewerScript])
            precondition(store.addTool(reviewTool))
            let reviewEmployee = Employee(name: "协议审核员", role: "审核", department: "开发部", instructions: "", toolID: reviewTool.id)
            precondition(store.addEmployee(reviewEmployee))
            let draft = PlanDraft(title: "设计与开发协作", goal: "验证交接与返工", steps: [PlanStep(id: "design", title: "设计交付", employeeID: designer.id, input: "设计说明", acceptance: "归档文件"), PlanStep(id: "build", title: "开发交付", employeeID: builder.id, input: "实现检查", acceptance: "包含来源文件", dependencies: ["design"])])
            precondition(store.approvePlan(draft, planningTaskID: nil, projectID: firstProject.id, reviewerID: designer.id) == nil && store.snapshot.plans.isEmpty)
            precondition(store.errorMessage?.contains("没有参与生产") == true); store.errorMessage = nil
            let planID = store.approvePlan(draft, planningTaskID: nil, projectID: firstProject.id, reviewerID: reviewEmployee.id, maximumReworks: 1)!
            let plan = store.snapshot.plans.first { $0.id == planID }!
            let firstID = plan.taskIDs[0], secondID = plan.taskIDs[1]
            try await wait(store, secondID, for: .completed, timeout: 15)
            precondition(store.runs(for: firstID).count == 2 && store.runs(for: secondID).count == 1)
            precondition(store.runs(for: firstID)[0].feedback == "补齐交付说明")
            precondition(store.runs(for: secondID)[0].input.contains(store.runs(for: firstID)[0].outputDirectory))
            precondition(store.snapshot.reviews.filter { $0.sourceTaskID == firstID || $0.sourceTaskID == secondID }.count == 3)
            let totalRuns = store.snapshot.runs.count
            store.pausePlan(planID, paused: true); store.pausePlan(planID, paused: false); store.schedulePending()
            try await Task.sleep(nanoseconds: 100_000_000); precondition(store.snapshot.runs.count == totalRuns)
            let persistent = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
            precondition(persistent.snapshot.plans.count == 1 && persistent.snapshot.reviews.count == 3)
            print("Collaboration checks passed: cross-area DAG, reviewer protocol, one rework, retained versions, accepted dependency artifacts, three review records, no duplicate on resume, SQLite reload")

            let manual = PlanDraft(title: "暂停与恢复验收", goal: "人工验收后才放行", steps: [PlanStep(id: "first", title: "暂停前执行", employeeID: worker.id, input: "first", acceptance: "退出0"), PlanStep(id: "second", title: "暂停后执行", employeeID: worker.id, input: "second", acceptance: "退出0", dependencies: ["first"])])
            let manualID = store.approvePlan(manual, planningTaskID: nil, projectID: firstProject.id, reviewerID: nil)!
            let manualPlan = store.snapshot.plans.first { $0.id == manualID }!
            store.pausePlan(manualID, paused: true)
            try await wait(store, manualPlan.taskIDs[0], for: .review)
            store.accept(manualPlan.taskIDs[0])
            precondition(store.snapshot.tasks.first { $0.id == manualPlan.taskIDs[1] }!.status == .queued && store.runs(for: manualPlan.taskIDs[1]).isEmpty)
            precondition(store.save())
            let restarted = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
            precondition(restarted.snapshot.tasks.first { $0.id == manualPlan.taskIDs[1] }!.status == .interrupted)
            precondition(restarted.runs(for: manualPlan.taskIDs[1]).isEmpty && restarted.activeRuns.isEmpty)
            restarted.pausePlan(manualID, paused: false)
            try await wait(restarted, manualPlan.taskIDs[1], for: .review)
            restarted.accept(manualPlan.taskIDs[1])
            precondition(restarted.runs(for: manualPlan.taskIDs[0]).count == 1 && restarted.runs(for: manualPlan.taskIDs[1]).count == 1)

            let stopID = restarted.approvePlan(manual, planningTaskID: nil, projectID: firstProject.id, reviewerID: nil)!
            let stopPlan = restarted.snapshot.plans.first { $0.id == stopID }!
            restarted.stopPlan(stopID)
            try await wait(restarted, stopPlan.taskIDs[0], for: .cancelled)
            precondition(restarted.snapshot.tasks.first { $0.id == stopPlan.taskIDs[1] }!.status == .cancelled && restarted.runs(for: stopPlan.taskIDs[1]).isEmpty)

            let boundTool = ToolConfig(name: "持续返工协议", executable: "/bin/sh", arguments: ["-c", "printf '%s' '{\"decision\":\"rework\",\"notes\":\"需人工确认\"}' > \"$MYWORKBENCH_OUTPUT_DIR/result.json\""])
            precondition(restarted.addTool(boundTool))
            let boundReviewer = Employee(name: "边界审核员", role: "审核", department: "开发部", instructions: "", toolID: boundTool.id)
            precondition(restarted.addEmployee(boundReviewer))
            let boundID = restarted.approvePlan(draft, planningTaskID: nil, projectID: firstProject.id, reviewerID: boundReviewer.id, maximumReworks: 0)!
            let boundPlan = restarted.snapshot.plans.first { $0.id == boundID }!
            for _ in 0..<300 where restarted.snapshot.plans.first(where: { $0.id == boundID })?.paused != true { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(restarted.snapshot.plans.first { $0.id == boundID }!.paused)
            precondition(restarted.runs(for: boundPlan.taskIDs[0]).count == 1 && restarted.runs(for: boundPlan.taskIDs[1]).isEmpty)
            precondition(restarted.snapshot.reviews.last?.decision.decision == .rework)
            print("Collaboration recovery checks passed: independent reviewer, pause retains active work, accepted dependency stays queued while paused, restart never auto-starts, continue starts only unstarted work, whole-plan stop, zero-rework boundary")
        }
        if CommandLine.arguments.contains("--codex-login-failure") {
            let codexPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            let emptyHome = root.appendingPathComponent("codex-empty-home"); try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
            let log = try RunLog(url: root.appendingPathComponent("codex-login-failure.log"))
            let login = ToolConfig(name: "独立未登录状态检查", executable: codexPath, arguments: ["login", "status"])
            let result = try await ProcessRunner().run(id: UUID(), tool: login, input: "", directory: a.path, environment: ["CODEX_HOME": emptyHome.path], onOutput: { log.append($0) })
            let message = log.drain(); try log.close()
            precondition(result.status == .failed && message.lowercased().contains("not logged in"))
            print("Codex login failure diagnostic passed: isolated empty home, nonzero exit, preserved message; existing login untouched")
        }
        if CommandLine.arguments.contains("--keychain") {
            let id = UUID(), vault = CredentialVault()
            defer { try? vault.remove(toolID: id) }
            let initial = try vault.read(toolID: id); precondition(initial == nil)
            try vault.save("local-qa-placeholder", toolID: id)
            let saved = try vault.read(toolID: id); precondition(saved == "local-qa-placeholder")
            try vault.save("updated-qa-placeholder", toolID: id)
            let updated = try vault.read(toolID: id); precondition(updated == "updated-qa-placeholder")
            try vault.remove(toolID: id)
            let removed = try vault.read(toolID: id); precondition(removed == nil)
            print("Keychain integration passed: fresh test account, add, read, update, remove; no real credential used")
        }
        print("QA workspace: \(root.path)")
    }
}
