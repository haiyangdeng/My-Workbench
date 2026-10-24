import Foundation

extension WorkbenchStore {
    var unassignedEmployees: [Employee] { snapshot.employees.current.filter { $0.workspaceID == nil } }

    @discardableResult func addExistingEmployee(_ employeeID: UUID, to workspaceID: UUID) -> Bool {
        manageObjects { try $0.addEmployee(employeeID, to: workspaceID) }
    }
    @discardableResult func removeEmployee(_ employeeID: UUID, from workspaceID: UUID) -> Bool {
        manageObjects { try $0.removeEmployee(employeeID, from: workspaceID) }
    }
    private func manageObjects(_ body: (inout WorkspaceSnapshot) throws -> Void) -> Bool {
        var candidate = snapshot
        do { try body(&candidate) }
        catch { errorMessage = error.localizedDescription; return false }
        return change { $0 = candidate }
    }

    @discardableResult func deleteObject(_ target: DeletionTarget) -> Bool {
        let downloadingRuns = snapshot.runs.filter { run in (run.remoteArtifacts ?? []).contains { downloadingFiles.contains($0.id) } }
        if downloadingRuns.contains(where: { run in
            switch target.kind {
            case .project: return run.projectID == target.objectID
            case .task: return run.taskID == target.objectID
            case .plan: return snapshot.tasks.contains { $0.id == run.taskID && $0.planID == target.objectID }
            default: return false
            }
        }) { errorMessage = "相关产物仍在下载，请等待下载结束后再删除。"; return false }
        if (target.kind == .tool || target.kind == .server) && (probingTools.contains(target.objectID) || testPrompts[target.objectID]?.running == true || loginChecks[target.objectID]?.state == .checking) {
            errorMessage = "连接正在检测或测试中，请结束后再删除。"; return false
        }
        guard manageObjects({ try $0.deleteObject(target) }) else { return false }
        if target.kind == .project && activeProjectID == target.objectID { activeProjectID = activeProjects.first?.id }
        if target.kind == .server { try? Self.sshPasswordVault.remove(toolID: target.objectID); serverTests.removeValue(forKey: target.objectID); serverCommands.removeValue(forKey: target.objectID) }
        if target.kind == .tool, let deleted = snapshot.tools.first(where: { $0.id == target.objectID }) {
            for name in deleted.secretEnvironmentNames ?? [] { try? CredentialVault.cliEnvironment.remove(account: CredentialVault.account(toolID: deleted.id, name: name)) }
        }
        if target.kind == .tool || target.kind == .server {
            disconnectTunnel(target.objectID)
            serverHealth.removeValue(forKey: target.objectID)
            testPrompts.removeValue(forKey: target.objectID)
            if missingCLIToolID == target.objectID { missingCLIToolID = nil }
        }
        return true
    }

    func deletionExplanation(_ target: DeletionTarget) -> String {
        switch target.kind {
        case .employee: return "员工会从所有工作区和员工目录中删除。历史任务、对话和执行快照保留；未执行任务可重新分配负责人。CLI 自身的账号登录不受影响。"
        case .workspace: return "删除工作区及其成员关系，不删除员工或项目。只属于此工作区的员工会放入“未分配工作区”，项目和模板会移除此工作区标签。"
        case .project: return "项目及其对话、任务、计划、产物会从列表移除。历史执行快照和归档文件保留，不删除项目目录中的文件。"
        case .plan: return "删除计划及其步骤，保留历史执行快照和归档文件。请先停止正在运行或排队的步骤。"
        case .tool: return "删除这项工具连接，保留历史执行快照。仍绑定此工具的员工需先更换 CLI；工具自身的账号登录不受影响。"
        case .server: return "删除服务器连接，保留历史执行快照和已下载文件。不会停止云主机，也不会删除服务器上的文件。"
        case .template: return "删除模板，保留历史执行中的工作流快照和产物。"
        case .artifact: return "从产物列表移除，保留执行归档中的原文件和来源记录。正在被下游任务使用的产物需要先处理关联任务。"
        case .conversation: return "从对话列表移除，保留历史消息和执行快照。已转为任务的工作不受影响。"
        case .task: return "从任务列表移除，保留历史执行快照和归档文件。属于协作计划或被依赖的任务需先处理关联关系。"
        }
    }

    @discardableResult func updateTask(_ edited: WorkTask) -> Bool {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == edited.id && !$0.isDeleted }) else { return false }
        let original = snapshot.tasks[index]
        guard ![.running, .queued].contains(original.status), original.planID == nil,
              original.generation == nil, original.command == nil else { errorMessage = "运行中的任务或计划步骤不能在此编辑，请先停止执行或在计划审批时修改。"; return false }
        guard let employee = employee(edited.employeeID), !employee.isDeleted, employee.enabled != false, !isArchived(projectID: edited.projectID),
              !edited.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !edited.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !edited.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "请填写有效的任务内容，并选择可用的员工和项目。"; return false }
        var directory: ObjCBool = false
        guard edited.workingDirectory.hasPrefix("/"), FileManager.default.fileExists(atPath: edited.workingDirectory, isDirectory: &directory), directory.boolValue else { errorMessage = "请选择有效的工作目录。"; return false }
        var updated = original
        updated.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.input = edited.input; updated.acceptance = edited.acceptance; updated.workingDirectory = edited.workingDirectory
        updated.employeeID = edited.employeeID; updated.projectID = edited.projectID; updated.accessLevel = edited.accessLevel
        let executionChanged = original.input != updated.input || original.acceptance != updated.acceptance || original.employeeID != updated.employeeID || original.projectID != updated.projectID || original.workingDirectory != updated.workingDirectory || original.accessLevel != updated.accessLevel
        if executionChanged {
            updated.status = .draft; updated.log = ""; updated.exitCode = nil; updated.pendingFeedback = nil
            updated.employeeSnapshot = nil; updated.toolSnapshot = nil
        }
        return change { snapshot in
            // Runs created before task editing existed had no separate acceptance snapshot.
            for r in snapshot.runs.indices where snapshot.runs[r].taskID == original.id && snapshot.runs[r].acceptance == nil { snapshot.runs[r].acceptance = original.acceptance }
            snapshot.tasks[index] = updated
        }
    }

    @discardableResult func renameArtifact(_ id: UUID, to title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, let index = snapshot.artifacts.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { errorMessage = "产物名称不能为空，且不能超过 120 字。"; return false }
        return change { $0.artifacts[index].displayName = title }
    }
    @discardableResult func renamePlan(_ id: UUID, to title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, let index = snapshot.plans.firstIndex(where: { $0.id == id && !$0.isDeleted }) else { errorMessage = "计划名称不能为空，且不能超过 120 字。"; return false }
        return change { $0.plans[index].title = title }
    }
}
