import Foundation
import AppKit
import Darwin

@main struct RealCollaborationVerification {
    @MainActor static func wait(_ store: WorkbenchStore, _ id: UUID, status: WorkStatus, timeout: Double = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = ""
        while Date() < deadline {
            let current = store.snapshot.tasks.first { $0.id == id }!
            if current.status.rawValue != previous { previous = current.status.rawValue; print("\(current.title): \(current.status.title)") }
            if current.status == status { return }
            if [.failed, .cancelled, .timedOut].contains(current.status), status != current.status { throw NSError(domain: "QA", code: 1, userInfo: [NSLocalizedDescriptionKey: current.log]) }
            if let error = store.errorMessage { throw NSError(domain: "QA", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "QA", code: 3, userInfo: [NSLocalizedDescriptionKey: "Collaboration timed out; inspect archived runs"])
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--resume-workspace"), CommandLine.arguments.count > index + 1 {
            let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
            let plan = store.snapshot.plans.first!
            let unstarted = Set(store.snapshot.tasks.filter { $0.planID == plan.id && $0.toolSnapshot == nil && $0.employeeSnapshot == nil && $0.exitCode == nil }.map(\.id))
            // Repair only this QA workspace's synthetic records from the earlier migration defect.
            store.snapshot.runs.removeAll { $0.id == $0.taskID && unstarted.contains($0.taskID) }
            precondition(store.save())
            let source = plan.taskIDs[0]
            let before = store.runs(for: source).count
            if store.snapshot.tasks.contains(where: { $0.id == source && $0.status == .review }) { store.requestReviewAgain(source) }
            store.pausePlan(plan.id, paused: false)
            for id in plan.taskIDs where store.snapshot.tasks.contains(where: { $0.id == id && $0.status == .interrupted }) && store.runs(for: id).isEmpty { store.run(id) }
            for id in plan.taskIDs { try await wait(store, id, status: .completed, timeout: 300) }
            precondition(store.runs(for: source).count == before)
            precondition(store.snapshot.reviews.filter { $0.decision.decision == .pass }.count == 2)
            let total = store.snapshot.runs.count
            store.pausePlan(plan.id, paused: false); store.schedulePending()
            try await Task.sleep(nanoseconds: 200_000_000); precondition(store.snapshot.runs.count == total)
            let restored = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
            precondition(restored.snapshot.plans.count == 1 && restored.snapshot.reviews.count == 3 && restored.snapshot.runs.count == 6)
            print("Real collaboration accepted: plan \(plan.id), 6 actual Codex runs including one blocked review and recheck, 2 accepted deliveries, 2 passing reviews, restart retained, no repeated production run")
            print("QA workspace: \(root.path)"); return
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/collaboration-qa/\(UUID())")
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await ProcessRunner().run(id: UUID(), tool: ToolConfig(name: "git", executable: "/usr/bin/git", arguments: ["init", directory.path]), input: "", directory: directory.path, onOutput: { _ in })
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var tool = ToolConfig(name: "Codex 协作验收", executable: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", arguments: [])
        tool.adapter = .codex; tool.timeoutSeconds = 150; precondition(store.addTool(tool))
        let designer = Employee(name: "Mia", role: "视觉文稿设计", department: "设计部", instructions: "直接以最终回复交付明确要求的短文稿，不修改文件，不调用其他工具。", toolID: tool.id)
        let developer = Employee(name: "Nova", role: "实现文稿设计", department: "开发部", instructions: "只读取本任务明确引用的已验收文稿。以最终回复输出检查清单，不修改任何文件。", toolID: tool.id)
        let manager = Employee(name: "Atlas", role: "拆解与审核", department: "开发部", instructions: "负责规划和有证据的审核，不承担生产步骤。审核时读取明确引用的候选产物与验收标准。", toolID: tool.id)
        precondition(store.addEmployee(designer)); precondition(store.addEmployee(developer)); precondition(store.addEmployee(manager))
        let project = WorkProject(name: "AI工作室协作文稿验收", directory: directory.path, goal: "通过实际AI拆解、两位员工交接及AI审核，形成两份短文稿。")
        precondition(store.addProject(project))
        let goal = "只规划两个生产步骤。第一步分配给 Mia（\(designer.id.uuidString)），直接回复一份160字以内的中文文稿，标题必须为‘工作室视觉规范’，包含3个明确的十六进制色值和一句头像配置建议。第二步分配给 Nova（\(developer.id.uuidString)），必须依赖第一步验收；读取依赖交付的文稿，回复160字以内的中文文稿，标题必须为‘实现检查清单’，复用第一步3个色值，包含3条检查项。Atlas只用于规划和审核，不安排生产步骤。两个步骤仅交付文本，不开发程序或生成图片。不要求员工写文件，最后回复会自动归档。为每步给出以上可检验标准。"
        let planningID = store.generatePlan(goal: goal, managerID: manager.id, projectID: project.id)!
        try await wait(store, planningID, status: .review)
        let draft = try store.planDraft(for: planningID)
        precondition(draft.steps.count == 2)
        let design = draft.steps.first { $0.employeeID == designer.id }!, build = draft.steps.first { $0.employeeID == developer.id }!
        precondition(design.dependencies.isEmpty && build.dependencies == [design.id])
        print("Real AI plan validated: 2 steps, Mia → Nova")
        let planID = store.approvePlan(draft, planningTaskID: planningID, projectID: project.id, reviewerID: manager.id, maximumReworks: 0)!
        let plan = store.snapshot.plans.first { $0.id == planID }!
        for id in plan.taskIDs {
            try await wait(store, id, status: .completed, timeout: 300)
            let run = store.runs(for: id)[0]
            precondition(run.status == .completed && store.artifacts(for: run.id).contains { $0.accepted })
        }
        let records = store.snapshot.reviews
        precondition(records.count == 2 && records.allSatisfy { $0.decision.decision == .pass })
        let totalRuns = store.snapshot.runs.count; store.schedulePending(); store.pausePlan(planID, paused: false)
        try await Task.sleep(nanoseconds: 200_000_000); precondition(store.snapshot.runs.count == totalRuns)
        let restored = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        precondition(restored.snapshot.plans.count == 1 && restored.snapshot.reviews.count == 2 && restored.snapshot.runs.count == 5)
        print("Real collaboration accepted: plan \(planID), 5 actual Codex runs, 2 accepted deliveries, 2 evidence-backed reviews, restart retained, no repeated run")
        print("QA workspace: \(root.path)")
    }
}
