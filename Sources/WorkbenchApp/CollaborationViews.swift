import SwiftUI

struct PlannerConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    var onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var managerID: UUID?
    @State private var goal = ""
    private var managers: [Employee] { store.planningCandidates }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("让一位伙伴安排这件事").font(.system(size: 24, weight: .medium))
            Text("AI先拆解目标与依赖。计划确认后，员工才开始执行。").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                Text(store.currentProject?.name ?? "请先在项目桌添加并选择项目")
                Picker("负责拆解的员工", selection: $managerID) { ForEach(managers) { Text($0.name).tag(Optional($0.id)) } }
                TextField("这次要完成什么", text: $goal, axis: .vertical).lineLimit(6...10)
            }.formStyle(.grouped)
            Text(managers.isEmpty ? "需要一位绑定 CLI、且该 CLI 配置了只读权限（或不由工作台管理权限）的员工。" : "拆解以只读方式运行所选员工的 CLI，生成计划。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("生成协作计划") {
                if let managerID, let projectID = store.activeProjectID, let id = store.generatePlan(goal: goal, managerID: managerID, projectID: projectID) { onCreated(id); dismiss() }
            }.buttonStyle(.borderedProminentPointer).disabled(managerID == nil || store.activeProjectID == nil || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.storageAvailable) }
        }.padding(30).frame(width: 610, height: 470).onAppear { managerID = managers.first?.id }
    }
}

struct PlanApprovalSheet: View {
    @State var draft: PlanDraft
    let planningTaskID: UUID?
    let projectID: UUID
    @ObservedObject var store: WorkbenchStore
    /// Set for a team plan from a conversation: steps may only use the agents chosen for that message.
    var teamMessageID: UUID? = nil
    var allowedAgentIDs: [UUID]? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var autoReview = false
    @State private var reviewerID: UUID?
    @State private var maximumReworks = 1
    @State private var issue: String?
    @State private var useWorktrees = false
    private var reviewers: [Employee] { store.planningCandidates.filter { !draft.steps.map(\.employeeID).contains($0.id) } }
    private var assignable: [Employee] { store.snapshot.employees.current.filter { ($0.enabled ?? true) && (allowedAgentIDs?.contains($0.id) ?? true) } }
    private func levels(for employeeID: UUID) -> [AccessLevel] {
        guard let agent = store.employee(employeeID), let tool = store.tool(agent.toolID) else { return [.readOnly] }
        let allowed = AccessLevel.allCases.filter { $0 <= (agent.maxAccess ?? .readOnly) && tool.supports($0) }
        return allowed.isEmpty ? [.readOnly] : allowed
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("把计划摊开，一起看清楚").font(.system(size: 24, weight: .medium))
            TextField("计划名称", text: $draft.title).font(.system(size: 16))
            Text(draft.goal).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(draft.steps.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Text("\(index + 1) / \(draft.steps[index].id)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary); Spacer() }
                            TextField("步骤名称", text: $draft.steps[index].title).font(.system(size: 14, weight: .medium))
                            Picker("负责员工", selection: $draft.steps[index].employeeID) { ForEach(assignable) { Text("\($0.name) · \($0.role)").tag($0.id) } }
                            Picker("权限", selection: Binding(get: { draft.steps[index].access ?? .readOnly }, set: { draft.steps[index].access = $0 })) {
                                ForEach(levels(for: draft.steps[index].employeeID), id: \.self) { Text($0.title).tag($0) }
                            }.pickerStyle(.segmented)
                            TextField("输入", text: $draft.steps[index].input, axis: .vertical).lineLimit(2...4)
                            TextField("验收标准", text: $draft.steps[index].acceptance, axis: .vertical).lineLimit(2...3)
                            TextField("前序步骤编号，用逗号分隔", text: Binding(get: { draft.steps[index].dependencies.joined(separator: ", ") }, set: { draft.steps[index].dependencies = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }))
                            Button("删除这个步骤", role: .destructive) { let removed = draft.steps.remove(at: index).id; for i in draft.steps.indices { draft.steps[i].dependencies.removeAll { $0 == removed } } }
                                .buttonStyle(.linkPointer).font(.system(size: 10)).disabled(draft.steps.count <= 1)
                        }.font(.system(size: 11)).padding(17).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            Button("添加步骤") {
                let id = "step-\(draft.steps.count + 1)-\(UUID().uuidString.prefix(4))"
                if let agent = assignable.first { draft.steps.append(PlanStep(id: String(id), title: "新步骤", employeeID: agent.id, input: "", acceptance: "", access: .readOnly)) }
            }.font(.system(size: 11)).disabled(draft.steps.count >= 20 || assignable.isEmpty)
            Toggle("可编辑步骤各自在独立的 git worktree 中运行，验收后由你选择合并或放弃（项目需是 git 仓库）", isOn: $useWorktrees)
            Toggle("交由AI审核，达标后自动继续", isOn: $autoReview)
            if autoReview {
                Picker("审核员工", selection: $reviewerID) { ForEach(reviewers) { Text($0.name).tag(Optional($0.id)) } }
                Stepper("每步最多返工 \(maximumReworks) 次", value: $maximumReworks, in: 0...2)
                Text("本轮最多 \(draft.steps.count * (1 + maximumReworks) * 2) 次执行与审核。审核无法确认达标时暂停计划；费用由工具账户计费。").font(.system(size: 10)).foregroundStyle(.secondary)
            } else { Text("每步成功后等待你验收，再执行依赖它的步骤。").font(.system(size: 11)).foregroundStyle(.secondary) }
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("稍后再看") { dismiss() }.keyboardShortcut(.cancelAction); Button("确认计划并启动") { approve() }.buttonStyle(.borderedProminentPointer).disabled(autoReview && reviewerID == nil) }
        }.padding(30).frame(width: 690, height: 680).onAppear { reviewerID = reviewers.first?.id }
    }
    private func approve() {
        do {
            try draft.validate(workspace: store.snapshot)
            for index in draft.steps.indices where !levels(for: draft.steps[index].employeeID).contains(draft.steps[index].access ?? .readOnly) { draft.steps[index].access = .readOnly }
            let approved: UUID?
            if let teamMessageID { approved = store.approveTeamPlan(messageID: teamMessageID, draft: draft, reviewerID: autoReview ? reviewerID : nil, maximumReworks: maximumReworks, useWorktrees: useWorktrees) }
            else { approved = store.approvePlan(draft, planningTaskID: planningTaskID, projectID: projectID, reviewerID: autoReview ? reviewerID : nil, maximumReworks: maximumReworks, useWorktrees: useWorktrees) }
            if approved != nil { dismiss() } else { issue = store.errorMessage; store.errorMessage = nil }
        } catch { issue = error.localizedDescription }
    }
}

struct CollaborationPanel: View {
    @ObservedObject var store: WorkbenchStore
    var onTask: (UUID) -> Void
    @State private var renaming: CollaborationPlan?
    @State private var title = ""
    var body: some View {
        ForEach(store.snapshot.plans.current.filter { $0.projectID == store.activeProjectID }) { plan in
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(plan.title).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Button("重命名") { title = plan.title; renaming = plan }
                    Button("删除计划", role: .destructive) { store.pendingDeletion = DeletionTarget(.plan, plan.id) }
                }.font(.system(size: 10))
                let completed = plan.taskIDs.filter { id in store.snapshot.tasks.contains { $0.id == id && $0.status == .completed } }.count
                Text("完成步骤 \(completed)/\(plan.taskIDs.count) · \(plan.paused ? "已暂停" : (completed == plan.taskIDs.count ? "已交付" : "协作中"))").font(.system(size: 10)).foregroundStyle(.secondary)
                ProgressView(value: Double(completed), total: Double(max(1, plan.taskIDs.count)))
                ForEach(plan.taskIDs, id: \.self) { id in
                    if let task = store.snapshot.tasks.first(where: { $0.id == id }) {
                        Button { onTask(id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(task.title); Spacer(); StatusBadge(status: task.status) }
                                Text(store.employee(task.employeeID)?.name ?? "未知员工").foregroundStyle(.secondary)
                                if !(task.dependencyIDs ?? []).isEmpty { Text("依赖：" + (task.dependencyIDs ?? []).compactMap { dependency in store.snapshot.tasks.first { $0.id == dependency }?.title }.joined(separator: "、")).foregroundStyle(.secondary) }
                            }.font(.system(size: 10)).padding(.vertical, 5)
                        }.buttonStyle(.plainPointer)
                    }
                }
                HStack {
                    Button(plan.paused ? "继续后续步骤" : "暂停后续步骤") { store.pausePlan(plan.id, paused: !plan.paused) }
                    Button("停止整个计划") { store.stopPlan(plan.id) }.tint(.red)
                }.font(.system(size: 10)).disabled(completed == plan.taskIDs.count)
                Text(plan.reviewerID == nil ? "人工审核" : "AI审核 · 返工上限\(plan.maximumReworks)次").font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
            }.padding(.vertical, 8)
        }.alert("重命名计划", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $title)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") { if let id = renaming?.id { store.renamePlan(id, to: title) }; renaming = nil }
        }
    }
}
