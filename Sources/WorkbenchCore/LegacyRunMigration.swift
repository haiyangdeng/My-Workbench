import Foundation

extension WorkspaceSnapshot {
    public mutating func migrateLegacyRuns(archive: RunArchive) throws {
        for task in tasks where ![.draft, .queued].contains(task.status) && (task.toolSnapshot != nil || task.employeeSnapshot != nil || task.exitCode != nil) && !runs.contains(where: { $0.taskID == task.id }) {
            guard let employee = task.employeeSnapshot ?? employees.first(where: { $0.id == task.employeeID }),
                  let tool = task.toolSnapshot ?? tools.first(where: { $0.id == employee.toolID }) else { continue }
            let directory = archive.directory(runID: task.id, projectID: task.projectID)
            if !FileManager.default.fileExists(atPath: directory.path) { _ = try archive.prepare(runID: task.id, projectID: task.projectID) }
            var record = TaskRun(id: task.id, task: task, employee: employee, tool: tool, directory: directory)
            record.status = task.status; record.exitCode = task.exitCode; record.startedAt = task.createdAt
            let url = URL(fileURLWithPath: record.logPath)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data(("[system] 从旧版任务迁移；旧版未记录准确开始结束时间。\n" + task.log).utf8).write(to: url, options: .atomic)
            }
            runs.append(record)
        }
    }
}
