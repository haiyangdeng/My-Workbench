import Foundation

/// Removal hides current configuration while preserving the identities used by run snapshots.
public protocol WorkbenchObject: Identifiable {
    var deletedAt: Date? { get set }
}
extension WorkbenchObject {
    public var isDeleted: Bool { deletedAt != nil }
}
extension Array where Element: WorkbenchObject {
    public var current: [Element] { filter { !$0.isDeleted } }
}
extension Employee: WorkbenchObject {}
extension ToolConfig: WorkbenchObject {}
extension WorkArea: WorkbenchObject {}
extension WorkProject: WorkbenchObject {}
extension Conversation: WorkbenchObject {}
extension WorkTask: WorkbenchObject {}
extension CollaborationPlan: WorkbenchObject {}
extension ComfyServer: WorkbenchObject {}
extension WorkflowTemplate: WorkbenchObject {}
extension WorkArtifact: WorkbenchObject {
    public var name: String { displayName ?? URL(fileURLWithPath: relativePath).lastPathComponent }
}

public struct DeletionTarget: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case employee, workspace, tool, project, conversation, task, plan, server, template, artifact }
    public var kind: Kind
    public var objectID: UUID
    public var id: String { kind.rawValue + "/" + objectID.uuidString }
    public init(_ kind: Kind, _ id: UUID) { self.kind = kind; objectID = id }
}

public enum ObjectManagementError: LocalizedError, Equatable {
    case missing, busy, referenced(String)
    public var errorDescription: String? {
        switch self {
        case .missing: return "这个对象已被删除或不存在，请刷新列表。"
        case .busy: return "还有执行中、排队中或状态未确认的工作，请先停止执行或查询远程状态，再删除。"
        case .referenced(let reason): return reason
        }
    }
}

extension WorkspaceSnapshot {
    public func objectName(_ target: DeletionTarget) -> String {
        let id = target.objectID
        switch target.kind {
        case .employee: return employees.first { $0.id == id }?.name ?? "员工"
        case .workspace: return workspaces.first { $0.id == id }?.name ?? "工作区"
        case .tool: return tools.first { $0.id == id }?.name ?? "工具"
        case .project: return projects.first { $0.id == id }?.name ?? "项目"
        case .conversation: return conversations.first { $0.id == id }?.title ?? "对话"
        case .task: return tasks.first { $0.id == id }?.title ?? "任务"
        case .plan: return plans.first { $0.id == id }?.title ?? "计划"
        case .server: return servers.first { $0.id == id }?.name ?? "服务器"
        case .template: return templates.first { $0.id == id }?.name ?? "模板"
        case .artifact: return artifacts.first { $0.id == id }?.name ?? "产物"
        }
    }

    public mutating func addEmployee(_ employeeID: UUID, to workspaceID: UUID) throws {
        guard workspaces.current.contains(where: { $0.id == workspaceID }), let index = employees.firstIndex(where: { $0.id == employeeID && !$0.isDeleted }) else { throw ObjectManagementError.missing }
        if employees[index].workspaceID == workspaceID { return }
        if employees[index].workspaceID == nil {
            employees[index].workspaceID = workspaceID
            employees[index].department = workspaces.first { $0.id == workspaceID }!.name
        } else if !(employees[index].additionalWorkspaceIDs ?? []).contains(workspaceID) {
            employees[index].additionalWorkspaceIDs = (employees[index].additionalWorkspaceIDs ?? []) + [workspaceID]
        }
    }

    public mutating func removeEmployee(_ employeeID: UUID, from workspaceID: UUID) throws {
        guard let index = employees.firstIndex(where: { $0.id == employeeID && !$0.isDeleted }) else { throw ObjectManagementError.missing }
        let validAreas = Set(workspaces.current.map(\.id))
        var extras = (employees[index].additionalWorkspaceIDs ?? []).filter { $0 != workspaceID && validAreas.contains($0) }
        // Keep another membership as primary, or leave the employee in the directory's unassigned group.
        if employees[index].workspaceID == workspaceID {
            employees[index].workspaceID = extras.first
            if !extras.isEmpty { extras.removeFirst() }
            employees[index].department = employees[index].workspaceID.flatMap { id in workspaces.current.first { $0.id == id }?.name } ?? ""
        }
        employees[index].additionalWorkspaceIDs = extras.isEmpty ? nil : extras
    }

    public mutating func deleteObject(_ target: DeletionTarget, at date: Date = Date()) throws {
        let id = target.objectID
        func busy(_ task: WorkTask) -> Bool {
            !task.isDeleted && ([.queued, .running].contains(task.status) || (task.status == .interrupted && runs.contains { $0.taskID == task.id && $0.remotePromptID != nil && $0.status == .interrupted }))
        }
        func protect(_ affected: [WorkTask]) throws {
            if affected.contains(where: busy) { throw ObjectManagementError.busy }
            if affected.contains(where: { $0.worktree?.state == .active || $0.worktree?.state == .conflict }) {
                throw ObjectManagementError.referenced("请先合并或放弃相关步骤的 worktree，再删除。")
            }
        }
        func activeConversation(_ conversationID: UUID) -> Bool { messages.contains { $0.conversationID == conversationID && $0.state?.isActive == true } }
        switch target.kind {
        case .employee:
            guard let index = employees.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            try protect(tasks.current.filter { task in task.employeeID == id || plans.current.contains { $0.reviewerID == id && $0.taskIDs.contains(task.id) } })
            if messages.contains(where: { $0.agentID == id && $0.state?.isActive == true }) { throw ObjectManagementError.busy }
            employees[index].deletedAt = date; employees[index].enabled = false
            for s in sessions.indices where sessions[s].agentID == id { sessions[s].invalid = true }
        case .workspace:
            guard let index = workspaces.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            workspaces[index].deletedAt = date
            for employee in employees.current { try removeEmployee(employee.id, from: id) }
            for p in projects.indices { projects[p].moduleIDs = modules(of: projects[p]).filter { $0 != id } }
            for t in templates.indices { templates[t].moduleIDs.removeAll { $0 == id } }
        case .tool:
            guard let index = tools.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            let members = employees.current.filter { $0.toolID == id }
            if !members.isEmpty { throw ObjectManagementError.referenced("先为这些员工更换 CLI 或删除员工：" + members.map(\.name).joined(separator: "、")) }
            try protect(tasks.current.filter { $0.command?.toolID == id || $0.toolSnapshot?.id == id })
            if runs.contains(where: { $0.tool.id == id && $0.status == .running }) { throw ObjectManagementError.busy }
            tools[index].deletedAt = date; tools[index].enabled = false
            for s in sessions.indices where sessions[s].toolID == id { sessions[s].invalid = true }
        case .server:
            guard let index = servers.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            try protect(tasks.current.filter { $0.generation?.serverID == id })
            servers[index].deletedAt = date; servers[index].enabled = false
        case .template:
            guard let index = templates.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            try protect(tasks.current.filter { $0.generation?.templateID == id })
            templates[index].deletedAt = date
        case .project:
            guard let index = projects.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            let affected = tasks.current.filter { $0.projectID == id }
            try protect(affected)
            if conversations.current.contains(where: { $0.projectID == id && activeConversation($0.id) }) { throw ObjectManagementError.busy }
            projects[index].deletedAt = date
            for c in conversations.indices where conversations[c].projectID == id { conversations[c].deletedAt = date }
            for t in tasks.indices where tasks[t].projectID == id { tasks[t].deletedAt = date }
            for p in plans.indices where plans[p].projectID == id { plans[p].deletedAt = date; plans[p].paused = true }
            for a in artifacts.indices where artifacts[a].projectID == id { artifacts[a].deletedAt = date }
        case .conversation:
            guard let index = conversations.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            if activeConversation(id) { throw ObjectManagementError.busy }
            try protect(tasks.current.filter { task in plans.current.contains { $0.conversationID == id && ($0.id == task.planID || $0.taskIDs.contains(task.id)) } })
            conversations[index].deletedAt = date
        case .task:
            guard let index = tasks.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            try protect([tasks[index]])
            if plans.current.contains(where: { $0.id == tasks[index].planID || $0.taskIDs.contains(id) }) { throw ObjectManagementError.referenced("这个任务属于协作计划，请先在工作流中删除计划。历史执行记录会保留。") }
            if tasks.current.contains(where: { ($0.dependencyIDs ?? []).contains(id) && ![.completed, .cancelled].contains($0.status) }) { throw ObjectManagementError.referenced("还有下游任务依赖这个任务，请先处理或删除下游任务。") }
            tasks[index].deletedAt = date
        case .plan:
            guard let index = plans.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            let ids = Set(plans[index].taskIDs)
            try protect(tasks.current.filter { $0.planID == id || ids.contains($0.id) })
            plans[index].deletedAt = date; plans[index].paused = true
            for t in tasks.indices where tasks[t].planID == id || ids.contains(tasks[t].id) { tasks[t].deletedAt = date }
        case .artifact:
            guard let index = artifacts.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { throw ObjectManagementError.missing }
            let source = artifacts[index].taskID
            try protect(tasks.current.filter { $0.id == source })
            if artifacts[index].accepted && tasks.current.contains(where: { ($0.dependencyIDs ?? []).contains(source) && ![.completed, .cancelled].contains($0.status) }) { throw ObjectManagementError.referenced("下游任务仍需使用这个已验收产物，请先处理下游任务。") }
            artifacts[index].deletedAt = date
        }
    }
}
