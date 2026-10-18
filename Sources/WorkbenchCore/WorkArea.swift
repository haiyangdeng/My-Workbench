import Foundation

public struct WorkArea: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var name: String
    public var icon: String
    public var color: String
    public var description: String
    public var sortIndex: Int

    public init(id: UUID = UUID(), name: String, icon: String = "sparkles", color: String = "708A73", description: String = "", sortIndex: Int = 0) {
        self.id = id; self.name = name; self.icon = icon; self.color = color
        self.description = description; self.sortIndex = sortIndex
    }

    public static let legacyDepartments = ["视频部", "音频音乐部", "开发部", "设计部"]
    public static let defaults: [WorkArea] = {
        zip(["影像工作区", "声音工作区", "开发工作区", "视觉工作区"], ["film", "waveform", "terminal", "paintpalette"]).enumerated().map { index, pair in
            WorkArea(id: UUID(uuidString: "5A510000-0000-4000-8000-00000000000\(index + 1)")!, name: pair.0, icon: pair.1,
                     color: ["B97255", "8D7D9A", "658398", "708A73"][index],
                     description: ["把故事变成影像", "让声音参与表达", "把想法构建出来", "为作品赋予风格"][index], sortIndex: index)
        }
    }()
}

extension WorkspaceSnapshot {
    /// Only current employee records are migrated; archived execution snapshots stay intact.
    public mutating func migrateWorkspaces() {
        for index in employees.indices where !employees[index].isDeleted {
            if employees[index].workspaceID == nil && employees[index].department.isEmpty { continue }
            if let id = employees[index].workspaceID, workspaces.current.contains(where: { $0.id == id }) { continue }
            let department = employees[index].department
            let legacyIndex = WorkArea.legacyDepartments.firstIndex(of: department)
            let defaultID = legacyIndex.map { WorkArea.defaults[$0].id }
            if let existing = workspaces.current.first(where: { $0.id == defaultID || $0.name == department }) {
                employees[index].workspaceID = existing.id
                employees[index].department = existing.name
            } else {
                var area = legacyIndex.map { WorkArea.defaults[$0] } ?? WorkArea(name: department.isEmpty ? "其他工作区" : department)
                area.sortIndex = (workspaces.map(\.sortIndex).max() ?? -1) + 1
                workspaces.append(area); employees[index].workspaceID = area.id; employees[index].department = area.name
            }
        }
    }

    public mutating func updateWorkspace(_ area: WorkArea) {
        guard let index = workspaces.firstIndex(where: { $0.id == area.id }) else { return }
        workspaces[index] = area
        for employeeIndex in employees.indices where employees[employeeIndex].workspaceID == area.id {
            employees[employeeIndex].department = area.name
        }
    }
}
