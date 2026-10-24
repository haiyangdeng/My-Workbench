import AppKit
import SwiftUI

/// Review a director's production plan: parameters, servers, estimates and the budget cap. Nothing is submitted before "启动".
struct ProductionApprovalSheet: View {
    @ObservedObject var store: WorkbenchStore
    let turnID: UUID
    @State var draft: PlanDraft
    @Environment(\.dismiss) private var dismiss
    @State private var budgetMinutes = ""
    @State private var budgetCost = ""
    @State private var directorReview = true
    @State private var maximumReworks = 1
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("审阅制作计划").font(.system(size: 23, weight: .medium))
            TextField("计划名称", text: $draft.title).font(.system(size: 15))
            Text(draft.goal).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(draft.steps.indices, id: \.self) { index in stepEditor(index) }
                }.padding(.trailing, 6)
            }
            let total = store.productionEstimate(draft)
            Text(totalText(total)).font(.system(size: 12, weight: .medium))
            HStack(spacing: 12) {
                TextField("GPU 时间上限（分钟）", text: $budgetMinutes).textFieldStyle(.roundedBorder).frame(width: 200)
                TextField("费用上限（\(currency)）", text: $budgetCost).textFieldStyle(.roundedBorder).frame(width: 180)
                Text("下一个任务预计超出上限时，暂停提交").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Toggle("生成后由导演检查结果（图片看原图，视频看关键帧，音频只看元数据）", isOn: $directorReview)
            Stepper("每个生成步骤最多返工 \(maximumReworks) 次", value: $maximumReworks, in: 0...2)
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Text("估算只供参考；服务端的实际计费由服务商决定。").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("稍后再看") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认并启动") { approve() }.buttonStyle(.borderedProminentPointer).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 760, height: 780)
            .onAppear {
                let total = store.productionEstimate(draft)
                if let seconds = total.seconds { budgetMinutes = String(format: "%.0f", max(1, (seconds * 1.5 / 60).rounded(.up))) }
            }
    }

    private var currency: String { draft.steps.compactMap { store.snapshot.server($0.serverID)?.currency }.first ?? "" }
    private func totalText(_ total: (seconds: Double?, cost: Double?, unknown: Int)) -> String {
        let time = total.seconds.map { String(format: "预计 GPU 时间 %.1f 分钟", $0 / 60) } ?? "\(total.unknown) 个生成步骤的时间未知"
        let cost = total.cost.map { String(format: " · 约 %.2f %@", $0, currency) } ?? " · 费用未知"
        return time + cost + "（估算）"
    }

    @ViewBuilder private func stepEditor(_ index: Int) -> some View {
        let step = draft.steps[index]
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(index + 1). \(step.stepKind.title)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                TextField("步骤名称", text: $draft.steps[index].title).font(.system(size: 13, weight: .medium))
                Text(step.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            switch step.stepKind {
            case .generate:
                HStack {
                    Picker("模板", selection: Binding(get: { draft.steps[index].templateID }, set: { draft.steps[index].templateID = $0 })) { ForEach(store.snapshot.templates.current) { Text($0.name).tag(Optional($0.id)) } }
                    Picker("服务器", selection: Binding(get: { draft.steps[index].serverID }, set: { draft.steps[index].serverID = $0 })) { ForEach(store.enabledServers) { Text($0.name).tag(Optional($0.id)) } }
                }
                ForEach((draft.steps[index].parameters ?? []).indices, id: \.self) { p in
                    HStack {
                        Text(draft.steps[index].parameters![p].name).font(.system(size: 10, design: .monospaced)).frame(width: 120, alignment: .leading)
                        TextField("值", text: Binding(get: { draft.steps[index].parameters![p].value }, set: { draft.steps[index].parameters![p].value = $0 }), axis: .vertical).lineLimit(1...3)
                    }
                }
                ForEach(draft.steps[index].inputs ?? [], id: \.name) { input in
                    Text("文件 \(input.name) ← \(sourceLabel(input.value))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                let estimate = store.estimate(templateID: draft.steps[index].templateID, serverID: draft.steps[index].serverID)
                Stepper("变体 \(draft.steps[index].variants ?? 1) 个（不同种子，由你选用）", value: Binding(get: { draft.steps[index].variants ?? 1 }, set: { draft.steps[index].variants = $0 > 1 ? $0 : nil }), in: 1...8)
                Text(estimate.seconds.map { String(format: "预计每个 %.1f 分钟", $0 / 60) } ?? "时间未知").font(.system(size: 10)).foregroundStyle(.secondary)
                if let template = store.snapshot.template(draft.steps[index].templateID), let serverID = draft.steps[index].serverID {
                    let missing = template.missingNodes(on: store.serverHealth[serverID])
                    if !missing.isEmpty { Label("服务器缺少节点：\(missing.joined(separator: "、"))，提交前会被拒绝", systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange) }
                }
            case .agent:
                Picker("员工", selection: $draft.steps[index].employeeID) { ForEach(store.snapshot.employees.current.filter { $0.enabled != false && store.tool($0.toolID)?.isCLI == true }) { Text($0.name).tag($0.id) } }
                TextField("输入", text: $draft.steps[index].input, axis: .vertical).lineLimit(2...4)
                Picker("权限", selection: Binding(get: { draft.steps[index].access ?? .readOnly }, set: { draft.steps[index].access = $0 })) { ForEach(AccessLevel.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            case .command:
                Picker("命令工具", selection: Binding(get: { draft.steps[index].toolID }, set: { draft.steps[index].toolID = $0 })) { ForEach(store.commandTools) { Text($0.name).tag(Optional($0.id)) } }
                TextField("参数，每行一个", text: Binding(get: { (draft.steps[index].arguments ?? []).joined(separator: "\n") }, set: { draft.steps[index].arguments = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }), axis: .vertical)
                    .font(.system(size: 11, design: .monospaced)).lineLimit(2...6)
            }
            TextField("验收标准", text: $draft.steps[index].acceptance, axis: .vertical).lineLimit(1...3)
            if !step.dependencies.isEmpty { Text("依赖 " + step.dependencies.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.font(.system(size: 11)).padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sourceLabel(_ source: String) -> String {
        if source.hasPrefix("attachment:"), let n = Int(source.dropFirst(11)), let turn = store.message(turnID), let user = store.message(turn.replyToID), let attachments = user.attachments, attachments.indices.contains(n) {
            return "附件 " + (attachments[n] as NSString).lastPathComponent
        }
        if source.hasPrefix("step:") { return "步骤 " + source.dropFirst(5) + " 的结果" }
        return source
    }

    private func approve() {
        let caps: (minutes: Double?, cost: Double?)
        do { caps = try BudgetCap.parse(minutes: budgetMinutes, cost: budgetCost, hasGenerateSteps: draft.steps.contains { $0.stepKind == .generate }) }
        catch { issue = error.localizedDescription; return }
        if store.approveProductionPlan(messageID: turnID, draft: draft, budgetMinutes: caps.minutes, budgetCost: caps.cost, directorReview: directorReview, maximumReworks: maximumReworks) != nil { dismiss() }
        else { issue = store.errorMessage; store.errorMessage = nil }
    }
}

/// A production plan inside the transcript: before approval the steps and estimates; afterwards progress, spend and results.
struct ProductionPlanCard: View {
    @ObservedObject var store: WorkbenchStore
    var turn: ChatMessage
    var accent: Color
    var onOpenTask: (UUID) -> Void
    var onReview: (ChatMessage) -> Void
    @State private var editingBudget = false
    @State private var minutes = ""
    @State private var cost = ""
    private var plan: CollaborationPlan? { turn.planID.flatMap { id in store.snapshot.plans.current.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan { running(plan) } else if turn.planID != nil { Text("计划已删除，历史执行记录保留。").font(.system(size: 11)).foregroundStyle(.secondary) } else if let draft = turn.planDraft { pending(draft) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .alert("调整预算", isPresented: $editingBudget) {
                TextField("GPU 分钟", text: $minutes); TextField("费用", text: $cost)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    guard let plan else { return }
                    do {
                        let caps = try BudgetCap.parse(minutes: minutes, cost: cost, hasGenerateSteps: store.planHasGenerateSteps(plan.id))
                        store.updateBudget(plan.id, minutes: caps.minutes, cost: caps.cost)
                    } catch { store.errorMessage = error.localizedDescription }
                }
            } message: { Text("留空表示不限制这一项。") }
    }

    private func icon(_ kind: StepKind) -> String { kind == .generate ? "wand.and.stars" : (kind == .command ? "terminal" : "person") }

    private func pending(_ draft: PlanDraft) -> some View {
        let total = store.productionEstimate(draft)
        return VStack(alignment: .leading, spacing: 8) {
            Text(draft.title).font(.system(size: 13, weight: .semibold))
            ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(step.stepKind)).foregroundStyle(accent).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(step.title)").font(.system(size: 12))
                        Text(detail(step)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Text((total.seconds.map { String(format: "预计 GPU 时间 %.1f 分钟", $0 / 60) } ?? "\(total.unknown) 个生成步骤时间未知") + (total.cost.map { String(format: " · 约 %.2f", $0) } ?? " · 费用未知") + "（估算）")
                .font(.system(size: 11, weight: .medium))
            HStack {
                Button("审阅参数与预算…") { onReview(turn) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(store.isArchived(projectID: store.conversation(turn.conversationID)?.projectID))
                Text("确认之前不会向服务器提交任何任务。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ step: PlanStep) -> String {
        switch step.stepKind {
        case .generate:
            let template = store.snapshot.template(step.templateID)?.name ?? "未知模板", server = store.snapshot.server(step.serverID)?.name ?? "未知服务器"
            let values = (step.parameters ?? []).map { "\($0.name)=\($0.value.prefix(40))" }.joined(separator: "，")
            return "\(template) @ \(server)" + (values.isEmpty ? "" : " · " + values)
        case .command: return (store.tool(step.toolID ?? UUID())?.name ?? "命令") + " " + (step.arguments ?? []).joined(separator: " ")
        case .agent: return (store.employee(step.employeeID)?.name ?? "员工") + " · " + (step.access ?? .readOnly).title
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
            Text(spendText(plan)).font(.system(size: 10)).foregroundStyle(.secondary)
            if let reason = plan.pauseReason, plan.paused { Label(reason, systemImage: "pause.circle").font(.system(size: 11)).foregroundStyle(.orange) }
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: task.generation != nil ? "wand.and.stars" : (task.command != nil ? "terminal" : "person")).foregroundStyle(accent).frame(width: 14)
                        Text(task.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 0)
                        StatusBadge(status: task.status, compact: true)
                    }
                    if let seed = task.generation?.submittedValues?["seed"], case .number(let value) = seed { Text("种子 \(Int64(value))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary) }
                    let files = latestArtifacts(task)
                    if !files.isEmpty {
                        let variants = (task.generation?.variants ?? 1) > 1
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(files, id: \.artifact.id) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        MediaPreview(url: item.url, compact: true).frame(width: 200)
                                        if variants && task.status == .review {
                                            Toggle("选用", isOn: Binding(get: { item.artifact.accepted }, set: { store.selectVariant(item.artifact.id, selected: $0) })).font(.system(size: 10))
                                        } else if variants && item.artifact.accepted { Text("已选用").font(.system(size: 10)).foregroundStyle(accent) }
                                    }
                                }
                            }
                        }
                        if variants && task.status == .review { Text("选用的结果会交给后续步骤；至少选一个才能验收。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    if let review = store.snapshot.reviews.filter({ $0.sourceTaskID == task.id }).max(by: { $0.createdAt < $1.createdAt }) {
                        Text("导演审核：\(review.decision.decision.rawValue) · \(review.decision.notes)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack(spacing: 10) {
                        if task.status == .review { Button("验收") { store.accept(task.id) } }
                        Button("详情") { onOpenTask(task.id) }
                    }.font(.system(size: 10)).buttonStyle(.linkPointer)
                }.padding(.vertical, 3)
            }
            HStack(spacing: 12) {
                Button(plan.paused ? "继续后续步骤" : "暂停后续步骤") { store.pausePlan(plan.id, paused: !plan.paused) }
                Button("调整预算") { minutes = plan.budgetMinutes.map { String(Int($0)) } ?? ""; cost = plan.budgetCost.map { String($0) } ?? ""; editingBudget = true }
                Button("停止整个计划") { store.stopPlan(plan.id) }.tint(.red)
            }.font(.system(size: 10)).buttonStyle(.linkPointer).disabled(done == tasks.count)
        }
    }

    private func latestArtifacts(_ task: WorkTask) -> [(artifact: WorkArtifact, url: URL)] {
        guard let run = store.runs(for: task.id).first else { return [] }
        return store.artifacts(for: run.id).filter { MediaKind.of(fileExtension: $0.fileType) != .other }.compactMap { artifact in (try? store.archive.url(for: artifact)).map { (artifact, $0) } }
    }

    private func spendText(_ plan: CollaborationPlan) -> String {
        var parts = [String(format: "已用 GPU %.1f 分钟", (plan.spentSeconds ?? 0) / 60)]
        if let minutes = plan.budgetMinutes { parts.append(String(format: "上限 %.0f 分钟", minutes)) }
        if let cost = plan.budgetCost { parts.append(String(format: "费用约 %.2f / 上限 %.2f", plan.spentCost ?? 0, cost)) }
        parts.append(plan.directorReview == true ? "导演审核 · 返工上限 \(plan.maximumReworks) 次" : "人工验收")
        return parts.joined(separator: " · ")
    }
}
