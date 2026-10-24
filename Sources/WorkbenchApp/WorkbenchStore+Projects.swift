import Foundation

struct ProjectCounts: Equatable {
    var tasks = 0
    var running = 0
    var review = 0
    var assets = 0
}

extension WorkbenchStore {
    var activeProjects: [WorkProject] { snapshot.projects.current.filter { !$0.isArchived } }
    func project(_ id: UUID?) -> WorkProject? { id.flatMap { id in snapshot.projects.first { $0.id == id } } }
    func isArchived(projectID: UUID?) -> Bool { project(projectID)?.isArchived ?? false }
    func category(_ id: UUID?) -> ProjectCategory? { id.flatMap { id in snapshot.categories.first { $0.id == id } } }

    func counts(for project: WorkProject) -> ProjectCounts {
        var counts = ProjectCounts()
        for task in visibleTasks where task.projectID == project.id {
            counts.tasks += 1
            if task.status == .running || task.status == .queued { counts.running += 1 }
            if task.status == .review { counts.review += 1 }
        }
        counts.assets = snapshot.artifacts.current.filter { $0.projectID == project.id && !$0.isChangeEvidence }.count
        return counts
    }

    @discardableResult func addCategory(_ category: ProjectCategory) -> Bool {
        var added = category
        added.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try snapshot.validate(added) } catch { errorMessage = error.localizedDescription; return false }
        added.sortIndex = (snapshot.categories.map(\.sortIndex).max() ?? -1) + 1
        return change { $0.categories.append(added) }
    }
    @discardableResult func updateCategory(_ category: ProjectCategory) -> Bool {
        guard let index = snapshot.categories.firstIndex(where: { $0.id == category.id }) else { return false }
        var updated = category
        updated.name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try snapshot.validate(updated) } catch { errorMessage = error.localizedDescription; return false }
        return change { $0.categories[index] = updated }
    }
    func deleteCategory(_ id: UUID) { change { $0.deleteCategory(id) } }
    func moveCategory(_ id: UUID, by offset: Int) { change { $0.moveCategory(id, by: offset) } }

    @discardableResult func updateProject(_ project: WorkProject) -> Bool {
        guard let index = snapshot.projects.firstIndex(where: { $0.id == project.id && !$0.isDeleted }) else { return false }
        guard project.categoryID == nil || category(project.categoryID) != nil else { return false }
        return change { $0.projects[index] = project }
    }
    @discardableResult func moveProject(_ id: UUID, to categoryID: UUID?) -> Bool {
        guard var project = project(id), project.categoryID != categoryID else { return false }
        project.categoryID = categoryID
        return updateProject(project)
    }
    func setProjectArchived(_ id: UUID, _ archived: Bool) {
        guard var project = project(id), project.isArchived != archived else { return }
        project.archivedAt = archived ? Date() : nil
        guard updateProject(project) else { return }
        if archived, activeProjectID == id { activeProjectID = activeProjects.first?.id }
        if !archived { schedulePending(); scheduleTurns() }
    }

    /// Media-only projects may skip choosing a folder; they get one inside the app's data folder.
    func defaultProjectDirectory(for id: UUID) throws -> String {
        let folder = archive.root.deletingLastPathComponent().appendingPathComponent("Projects/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }
}
