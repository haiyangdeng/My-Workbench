import SwiftUI

struct PlannerConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    var onCreated: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var managerID: UUID?
    @State private var goal = ""
    private var managers: [Employee] { store.snapshot.employees.filter { ($0.enabled ?? true) && store.tool($0.toolID)?.adapterKind == .codex && store.tool($0.toolID)?.isEnabled == true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("让一位伙伴安排这件事").font(.system(size: 24, weight: .medium))
            Text("AI先拆解目标与依赖。计划确认后，员工才开始执行。").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                Text(store.currentProject?.name ?? "请先在项目桌添加并选择项目")
                Picker("负责拆解的员工", selection: $managerID) { ForEach(managers) { Text($0.name).tag(Optional($0.id)) } }
                TextField("这次要完成什么", text: $goal, axis: .vertical).lineLimit(6...10)
            }.formStyle(.grouped)
            Text("拆解使用已配置的 Codex 工具，以只读模式生成计划。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("生成协作计划") {
                if let managerID, let projectID = store.activeProjectID, let id = store.generatePlan(goal: goal, managerID: managerID, projectID: projectID) { onCreated(id); dismiss() }
            }.buttonStyle(.borderedProminent).disabled(managerID == nil || store.activeProjectID == nil || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.storageAvailable) }
        }.padding(30).frame(width: 610, height: 470).onAppear { managerID = managers.first?.id }
    }
}

struct PlanApprovalSheet: View {
    @State var draft: PlanDraft
    let planningTaskID: UUID
    let projectID: UUID
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss
    @State private var autoReview = false
    @State private var reviewerID: UUID?
    @State private var maximumReworks = 1
    @State private var issue: String?
    private var reviewers: [Employee] { store.snapshot.employees.filter { ($0.enabled ?? true) && !draft.steps.map(\.employeeID).contains($0.id) && store.tool($0.toolID)?.adapterKind == .codex && store.tool($0.toolID)?.isEnabled == true } }
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
                            Picker("负责员工", selection: $draft.steps[index].employeeID) { ForEach(store.snapshot.employees.filter { $0.enabled ?? true }) { Text("\($0.name) · \($0.role)").tag($0.id) } }
                            TextField("输入", text: $draft.steps[index].input, axis: .vertical).lineLimit(2...4)
                            TextField("验收标准", text: $draft.steps[index].acceptance, axis: .vertical).lineLimit(2...3)
                            TextField("前序步骤编号，用逗号分隔", text: Binding(get: { draft.steps[index].dependencies.joined(separator: ", ") }, set: { draft.steps[index].dependencies = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }))
                        }.font(.system(size: 11)).padding(17).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            Toggle("交由AI审核，达标后自动继续", isOn: $autoReview)
            if autoReview {
                Picker("审核员工", selection: $reviewerID) { ForEach(reviewers) { Text($0.name).tag(Optional($0.id)) } }
                Stepper("每步最多返工 \(maximumReworks) 次", value: $maximumReworks, in: 0...2)
                Text("本轮最多 \(draft.steps.count * (1 + maximumReworks) * 2) 次执行与审核。审核无法确认达标时暂停计划；费用由工具账户计费。").font(.system(size: 10)).foregroundStyle(.secondary)
            } else { Text("每步成功后等待你验收，再执行依赖它的步骤。").font(.system(size: 11)).foregroundStyle(.secondary) }
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("稍后再看") { dismiss() }.keyboardShortcut(.cancelAction); Button("确认计划并启动") { approve() }.buttonStyle(.borderedProminent).disabled(autoReview && reviewerID == nil) }
        }.padding(30).frame(width: 690, height: 680).onAppear { reviewerID = reviewers.first?.id }
    }
    private func approve() {
        do {
            try draft.validate(workspace: store.snapshot)
            if store.approvePlan(draft, planningTaskID: planningTaskID, projectID: projectID, reviewerID: autoReview ? reviewerID : nil, maximumReworks: maximumReworks) != nil { dismiss() }
            else { issue = store.errorMessage }
        } catch { issue = error.localizedDescription }
    }
}

struct CollaborationPanel: View {
    @ObservedObject var store: WorkbenchStore
    var onTask: (UUID) -> Void
    var body: some View {
        ForEach(store.snapshot.plans.filter { $0.projectID == store.activeProjectID }) { plan in
            VStack(alignment: .leading, spacing: 13) {
                Text(plan.title).font(.system(size: 14, weight: .medium))
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
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Button(plan.paused ? "继续后续步骤" : "暂停后续步骤") { store.pausePlan(plan.id, paused: !plan.paused) }
                    Button("停止整个计划") { store.stopPlan(plan.id) }.tint(.red)
                }.font(.system(size: 10)).disabled(completed == plan.taskIDs.count)
                Text(plan.reviewerID == nil ? "人工审核" : "AI审核 · 返工上限\(plan.maximumReworks)次").font(.system(size: 10)).foregroundStyle(.secondary)
                Divider()
            }.padding(.vertical, 8)
        }
    }
}
