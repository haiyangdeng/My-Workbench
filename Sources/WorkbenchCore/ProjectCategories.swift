import Foundation

/// A user-defined group of projects. "Uncategorized" is not stored: a project with no categoryID belongs to it.
public struct ProjectCategory: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: String
    public var icon: String
    public var sortIndex: Int
    public init(id: UUID = UUID(), name: String, color: String = "658398", icon: String = "folder", sortIndex: Int = 0) {
        self.id = id; self.name = name; self.color = color; self.icon = icon; self.sortIndex = sortIndex
    }
    public static let uncategorizedName = "未分类"
}

public enum ProjectCategoryError: LocalizedError {
    case invalidName, invalidColor
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "分类名称不能为空、不超过40字，且不能与其他分类或“未分类”重名。"
        case .invalidColor: return "颜色需为有效的六位色值。"
        }
    }
}

public struct ProjectFilter: Equatable, Sendable {
    public enum Category: Hashable, Sendable { case all, uncategorized, id(UUID) }
    public enum Status: String, CaseIterable, Sendable { case active, archived, all }
    public enum Sort: String, CaseIterable, Sendable { case activity, name, created }
    public var category: Category = .all
    public var moduleID: UUID?
    public var status: Status = .active
    public var text = ""
    public var sort: Sort = .activity
    public init() {}
}

extension WorkspaceSnapshot {
    public var sortedCategories: [ProjectCategory] { categories.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) } }

    public func validate(_ category: ProjectCategory) throws {
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, name != ProjectCategory.uncategorizedName,
              !categories.contains(where: { $0.id != category.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == name }) else { throw ProjectCategoryError.invalidName }
        guard category.color.count == 6, UInt32(category.color, radix: 16) != nil else { throw ProjectCategoryError.invalidColor }
    }

    /// Removes the category; its projects move to Uncategorized and keep everything else.
    public mutating func deleteCategory(_ id: UUID) {
        categories.removeAll { $0.id == id }
        for index in projects.indices where projects[index].categoryID == id { projects[index].categoryID = nil }
        for (order, category) in sortedCategories.enumerated() { if let index = categories.firstIndex(where: { $0.id == category.id }) { categories[index].sortIndex = order } }
    }

    public mutating func moveCategory(_ id: UUID, by offset: Int) {
        var ordered = sortedCategories
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let to = min(ordered.count - 1, max(0, from + offset))
        guard to != from else { return }
        ordered.insert(ordered.remove(at: from), at: to)
        for (order, category) in ordered.enumerated() { if let index = categories.firstIndex(where: { $0.id == category.id }) { categories[index].sortIndex = order } }
    }

    /// The category a project shows under; a dangling ID counts as Uncategorized.
    public func categoryID(of project: WorkProject) -> UUID? {
        project.categoryID.flatMap { id in categories.contains { $0.id == id } ? id : nil }
    }

    public func modules(of project: WorkProject) -> [UUID] { project.moduleIDs ?? inferredModules(of: project) }

    /// Modules of the agents that worked on the project, falling back to the default Code module.
    public func inferredModules(of project: WorkProject) -> [UUID] {
        let employeeIDs = Set(tasks.filter { $0.projectID == project.id }.map(\.employeeID))
        var result: [UUID] = []
        for employee in employees where employeeIDs.contains(employee.id) {
            if let area = employee.workspaceID, !result.contains(area) { result.append(area) }
        }
        return result.isEmpty ? [WorkArea.defaults[2].id] : result.sorted { a, b in
            (workspaces.first { $0.id == a }?.sortIndex ?? 0) < (workspaces.first { $0.id == b }?.sortIndex ?? 0)
        }
    }

    public func lastActivity(of project: WorkProject) -> Date {
        var latest = project.createdAt ?? .distantPast
        for task in tasks where task.projectID == project.id { latest = max(latest, task.createdAt) }
        for run in runs where run.projectID == project.id { latest = max(latest, run.endedAt ?? run.startedAt) }
        return latest
    }

    public func projects(matching filter: ProjectFilter) -> [WorkProject] {
        let text = filter.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = projects.current.filter { project in
            switch filter.status {
            case .active: if project.isArchived { return false }
            case .archived: if !project.isArchived { return false }
            case .all: break
            }
            switch filter.category {
            case .all: break
            case .uncategorized: if categoryID(of: project) != nil { return false }
            case .id(let id): if categoryID(of: project) != id { return false }
            }
            if let module = filter.moduleID, !modules(of: project).contains(module) { return false }
            return text.isEmpty || (project.name + "\n" + project.goal + "\n" + project.directory).localizedCaseInsensitiveContains(text)
        }
        switch filter.sort {
        case .activity: return matched.sorted { lastActivity(of: $0) > lastActivity(of: $1) }
        case .name: return matched.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .created: return matched.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
    }

    /// The module an artifact came from: the module of the agent that produced its run.
    public func moduleID(of artifact: WorkArtifact) -> UUID? {
        runs.first { $0.id == artifact.runID }.flatMap { run in employees.first { $0.id == run.employee.id }?.workspaceID ?? run.employee.workspaceID }
    }

    /// v3 → v4: retire the built-in Codex adapter, give agents an access ceiling, and record project modules.
    public mutating func migrateToV4() {
        guard schemaVersion < 4 else { return }
        for index in tools.indices where tools[index].adapter == .codex {
            let writable = tools[index].codexWorkspaceWrite == true
            tools[index] = tools[index].migratingLegacyAdapter()
            for e in employees.indices where employees[e].toolID == tools[index].id && employees[e].maxAccess == nil {
                employees[e].maxAccess = writable ? .edit : .readOnly
            }
        }
        for index in projects.indices where projects[index].moduleIDs == nil {
            projects[index].moduleIDs = inferredModules(of: projects[index])
        }
        schemaVersion = 4
    }
}
