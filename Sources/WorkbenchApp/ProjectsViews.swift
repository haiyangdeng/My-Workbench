import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// All projects, grouped by category, with filters that work across every project.
struct AllProjectsView: View {
    @ObservedObject var store: WorkbenchStore
    var accent: Color
    var onOpen: (UUID) -> Void
    var onEdit: (WorkProject) -> Void
    var onTask: (UUID) -> Void
    var initialModuleID: UUID? = nil
    var initialCategoryID: UUID? = nil
    @State private var filter = ProjectFilter()
    @State private var showTasks = false
    @State private var collapsed: Set<String> = []

    private var projects: [WorkProject] { store.snapshot.projects(matching: filter) }
    private var narrowed: Bool { !filter.text.trimmingCharacters(in: .whitespaces).isEmpty || filter.moduleID != nil || filter.category != .all || filter.status != .active }
    private var sections: [(key: String, category: ProjectCategory?)] {
        let all: [(key: String, category: ProjectCategory?)] = store.snapshot.sortedCategories.map { ($0.id.uuidString, Optional($0)) } + [("uncategorized", nil)]
        switch filter.category {
        case .all: return all
        case .uncategorized: return all.filter { $0.category == nil }
        case .id(let id): return all.filter { $0.category?.id == id }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            filterBar.onAppear {
                if let initialModuleID { filter.moduleID = initialModuleID }
                if let initialCategoryID { filter.category = .id(initialCategoryID) }
            }
            if store.snapshot.projects.current.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还没有项目").font(.system(size: 16, weight: .semibold))
                    Text("项目把任务、执行记录和产物放在一起。可以按分类整理所有项目。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.vertical, 20)
            } else if showTasks {
                taskList
            } else {
                ForEach(sections, id: \.key) { section in
                    let members = projects.filter { store.snapshot.categoryID(of: $0) == section.category?.id }
                    if !(narrowed && members.isEmpty) { categorySection(section.key, category: section.category, members: members) }
                }
                if projects.isEmpty { Text("没有符合筛选条件的项目。").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            StudioSearchField(prompt: "搜索项目", text: $filter.text).frame(maxWidth: 200)
            Picker("分类", selection: $filter.category) {
                Text("全部分类").tag(ProjectFilter.Category.all)
                ForEach(store.snapshot.sortedCategories) { Text($0.name).tag(ProjectFilter.Category.id($0.id)) }
                Text(ProjectCategory.uncategorizedName).tag(ProjectFilter.Category.uncategorized)
            }.frame(maxWidth: 170)
            Picker("工作区", selection: $filter.moduleID) {
                Text("全部工作区").tag(Optional<UUID>.none)
                ForEach(store.workspaces) { Text($0.name).tag(Optional($0.id)) }
            }.frame(maxWidth: 170)
            Picker("状态", selection: $filter.status) { Text("进行中").tag(ProjectFilter.Status.active); Text("已归档").tag(ProjectFilter.Status.archived); Text("全部").tag(ProjectFilter.Status.all) }.frame(maxWidth: 130)
            Picker("排序", selection: $filter.sort) { Text("最近活动").tag(ProjectFilter.Sort.activity); Text("名称").tag(ProjectFilter.Sort.name); Text("创建时间").tag(ProjectFilter.Sort.created) }.frame(maxWidth: 140)
            Spacer(minLength: 0)
            Picker("显示", selection: $showTasks) { Text("项目").tag(false); Text("任务").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 110)
        }.font(.system(size: 11)).accessibilityIdentifier("projects.filters")
    }

    private func categorySection(_ key: String, category: ProjectCategory?, members: [WorkProject]) -> some View {
        let tint = category.map { Color(hex: $0.color) } ?? .secondary
        let isCollapsed = collapsed.contains(key)
        return VStack(alignment: .leading, spacing: 12) {
            Button { if isCollapsed { collapsed.remove(key) } else { collapsed.insert(key) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 10)).frame(width: 12)
                    Image(systemName: category?.icon ?? "tray").foregroundStyle(tint)
                    Text(category?.name ?? ProjectCategory.uncategorizedName).font(.system(size: 15, weight: .semibold))
                    Text("\(members.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plainPointer).accessibilityLabel("\(category?.name ?? ProjectCategory.uncategorizedName)，\(members.count) 个项目，\(isCollapsed ? "已收起" : "已展开")")
                .dropDestination(for: String.self) { values, _ in
                    guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                    return store.moveProject(id, to: category?.id)
                }
            if !isCollapsed {
                if members.isEmpty {
                    Text("把项目拖到这里，或在项目菜单中选择“移动到分类”。").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 46).background(tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                            return store.moveProject(id, to: category?.id)
                        }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(members) { project in card(project, tint: tint) }
                    }
                }
            }
        }
    }

    private func card(_ project: WorkProject, tint: Color) -> some View {
        let counts = store.counts(for: project)
        let activity = store.snapshot.lastActivity(of: project)
        return Button { onOpen(project.id) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if project.isArchived { Text("已归档").font(.system(size: 9)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.12), in: Capsule()) }
                }
                if !project.goal.isEmpty { Text(project.goal).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 5) {
                    ForEach(store.snapshot.modules(of: project), id: \.self) { id in
                        if let area = store.workspaces.first(where: { $0.id == id }) {
                            Label(area.name, systemImage: area.icon).labelStyle(.iconOnly).font(.system(size: 10)).foregroundStyle(StudioArtwork.tint(for: area))
                                .frame(width: 22, height: 22).background(StudioArtwork.tint(for: area).opacity(0.1), in: Circle()).help(area.name)
                        }
                    }
                }
                HStack(spacing: 10) {
                    stat("任务", counts.tasks); stat("执行中", counts.running); stat("待验收", counts.review, highlight: counts.review > 0); stat("产物", counts.assets)
                }
                Text(activity == .distantPast ? "尚无活动" : "最近活动 " + activity.formatted(.relative(presentation: .named))).font(.system(size: 9)).foregroundStyle(.secondary)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.18)))
                .opacity(project.isArchived ? 0.7 : 1)
        }.buttonStyle(.plainPointer)
            .draggable(project.id.uuidString)
            .contextMenu {
                Button("打开项目") { onOpen(project.id) }
                Button("编辑项目") { onEdit(project) }
                Menu("移动到分类") {
                    ForEach(store.snapshot.sortedCategories) { category in
                        Button(category.name) { store.moveProject(project.id, to: category.id) }.disabled(project.categoryID == category.id)
                    }
                    Button(ProjectCategory.uncategorizedName) { store.moveProject(project.id, to: nil) }.disabled(store.snapshot.categoryID(of: project) == nil)
                }
                Button(project.isArchived ? "取消归档" : "归档项目") { store.setProjectArchived(project.id, !project.isArchived) }
                Button("删除项目", role: .destructive) { store.pendingDeletion = DeletionTarget(.project, project.id) }
            }
            .accessibilityIdentifier("projects.card." + project.id.uuidString)
            .accessibilityHint("打开项目。菜单中可移动到其他分类或归档。")
    }

    private func stat(_ title: String, _ value: Int, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 13, weight: .semibold)).foregroundStyle(highlight ? .orange : .primary)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var taskList: some View {
        let ids = Set(projects.map(\.id))
        let tasks = store.visibleTasks.filter { $0.projectID.map(ids.contains) ?? false }
        return VStack(alignment: .leading, spacing: 4) {
            if tasks.isEmpty { Text("筛选范围内没有任务。").font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(tasks) { task in
                Button { onTask(task.id) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(task.title).font(.system(size: 12)).lineLimit(1)
                            Text([store.project(task.projectID)?.name, store.employee(task.employeeID)?.name].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(); StatusBadge(status: task.status)
                    }.padding(.vertical, 8).contentShape(Rectangle())
                }.buttonStyle(.plainPointer)
                Divider()
            }
        }
    }
}

struct CategoryManagerSheet: View {
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ProjectCategory?
    @State private var pendingDelete: ProjectCategory?
    private let colors = ["658398", "B97255", "8D7D9A", "708A73", "B79758", "9A7B83", "4F7CAC", "C0605F"]
    private let icons = ["folder", "briefcase", "play.rectangle", "person.2", "flask", "star", "book", "megaphone", "camera", "music.note"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("管理分类").font(.system(size: 23, weight: .medium))
            Text("分类用来整理所有项目，与工作区无关。删除分类时，其中的项目会移到“未分类”，任务和记录不受影响。").font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(store.snapshot.sortedCategories.enumerated()), id: \.element.id) { index, category in
                        HStack(spacing: 10) {
                            Image(systemName: category.icon).foregroundStyle(Color(hex: category.color)).frame(width: 20)
                            Text(category.name).font(.system(size: 13))
                            Text("\(store.snapshot.projects.current.filter { $0.categoryID == category.id }.count) 个项目").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button { store.moveCategory(category.id, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("上移 " + category.name)
                            Button { store.moveCategory(category.id, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == store.snapshot.categories.count - 1).accessibilityLabel("下移 " + category.name)
                            Button("编辑") { editing = category }
                            Button("删除", role: .destructive) { pendingDelete = category }
                        }.buttonStyle(.borderlessPointer).font(.system(size: 11)).padding(.vertical, 9)
                        Divider()
                    }
                    HStack { Image(systemName: "tray").foregroundStyle(.secondary).frame(width: 20); Text(ProjectCategory.uncategorizedName).font(.system(size: 13)); Text("内置，不能删除").font(.system(size: 10)).foregroundStyle(.secondary); Spacer() }.padding(.vertical, 9)
                }
            }.frame(maxHeight: 260)
            if let draft = editing {
                CategoryEditor(category: draft, colors: colors, icons: icons) { saved in
                    let ok = store.snapshot.categories.contains { $0.id == saved.id } ? store.updateCategory(saved) : store.addCategory(saved)
                    if ok { editing = nil }
                } onCancel: { editing = nil }.id(draft.id)
            } else {
                Button("添加分类") { editing = ProjectCategory(name: "", color: colors[store.snapshot.categories.count % colors.count]) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable)
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 560, height: 600)
            .alert("删除分类「\(pendingDelete?.name ?? "")」？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) { if let id = pendingDelete?.id { store.deleteCategory(id) }; pendingDelete = nil }
            } message: { Text("其中 \(store.snapshot.projects.current.filter { $0.categoryID == pendingDelete?.id }.count) 个项目会移到“未分类”。") }
    }
}

private struct CategoryEditor: View {
    @State var category: ProjectCategory
    let colors: [String]
    let icons: [String]
    var onSave: (ProjectCategory) -> Void
    var onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("分类名称", text: $category.name).textFieldStyle(.roundedBorder).onSubmit { onSave(category) }
            HStack(spacing: 7) {
                ForEach(colors, id: \.self) { color in
                    Button { category.color = color } label: { Circle().fill(Color(hex: color)).frame(width: 20, height: 20).overlay(Circle().stroke(.primary.opacity(category.color == color ? 0.6 : 0), lineWidth: 2)) }
                        .buttonStyle(.plainPointer).accessibilityLabel("颜色 \(color)").accessibilityValue(category.color == color ? "已选择" : "未选择")
                }
            }
            HStack(spacing: 7) {
                ForEach(icons, id: \.self) { icon in
                    Button { category.icon = icon } label: { Image(systemName: icon).frame(width: 22, height: 22) }
                        .buttonStyle(.borderedPointer).tint(category.icon == icon ? Color(hex: category.color) : .secondary).accessibilityLabel("图标 \(icon)")
                }
            }
            HStack { Spacer(); Button("取消", action: onCancel); Button("保存") { onSave(category) }.buttonStyle(StudioPrimaryButtonStyle()).disabled(category.name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProjectConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    var projectToEdit: WorkProject? = nil
    var onSaved: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory = ""
    @State private var goal = ""
    @State private var categoryID: UUID?
    @State private var modules: Set<UUID> = [WorkArea.defaults[2].id]
    @State private var archived = false
    @State private var autoExport = false
    @State private var issue: String?
    private var codeModule: UUID { WorkArea.defaults[2].id }
    private var needsFolder: Bool { modules.contains(codeModule) || projectToEdit != nil }
    private var folderValid: Bool {
        var isDirectory: ObjCBool = false
        return directory.hasPrefix("/") && FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !modules.isEmpty && store.storageAvailable && (folderValid || (!needsFolder && directory.isEmpty))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(projectToEdit == nil ? "把一个项目放上桌" : "编辑项目").font(.system(size: 24, weight: .medium))
            Text("任务、执行记录与产物分别归属于各自的项目。").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField("项目名称", text: $name)
                Picker("分类", selection: $categoryID) {
                    Text(ProjectCategory.uncategorizedName).tag(Optional<UUID>.none)
                    ForEach(store.snapshot.sortedCategories) { Text($0.name).tag(Optional($0.id)) }
                }
                Section("用到的工作区") {
                    ForEach(store.workspaces) { area in
                        Toggle(isOn: Binding(get: { modules.contains(area.id) }, set: { if $0 { modules.insert(area.id) } else { modules.remove(area.id) } })) { Label(area.name, systemImage: area.icon) }
                    }
                }
                HStack {
                    TextField(needsFolder ? "工作目录" : "工作目录（可选）", text: $directory)
                    Button("选择目录") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                    }
                }
                if !needsFolder && directory.isEmpty { Text("不选择时，会在工作台的数据目录中为这个项目创建文件夹。").font(.system(size: 10)).foregroundStyle(.secondary) }
                TextField("项目目标", text: $goal, axis: .vertical).lineLimit(3...6)
                Toggle("验收后把生成和命令步骤的结果复制到项目文件夹的“Workbench 导出”", isOn: $autoExport)
                if projectToEdit != nil { Toggle("归档（只能查看，不能新建或执行任务）", isOn: $archived) }
            }.formStyle(.grouped)
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button(projectToEdit == nil ? "放上项目桌" : "保存") { save() }.buttonStyle(.borderedProminentPointer).disabled(!valid).keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 580, height: 680)
            .onAppear {
                if let project = projectToEdit {
                    name = project.name; directory = project.directory; goal = project.goal; categoryID = store.snapshot.categoryID(of: project)
                    modules = Set(store.snapshot.modules(of: project)); archived = project.isArchived; autoExport = project.autoExport == true
                } else {
                    modules = Set([store.workspaces.first(where: { $0.icon == "terminal" })?.id ?? store.workspaces.first?.id].compactMap { $0 })
                }
            }
    }
    private func save() {
        var project = projectToEdit ?? WorkProject(name: name, directory: directory, goal: goal)
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines); project.goal = goal; project.categoryID = categoryID
        project.moduleIDs = store.workspaces.map(\.id).filter(modules.contains)
        project.autoExport = autoExport ? true : nil
        do {
            project.directory = directory.isEmpty ? try store.defaultProjectDirectory(for: project.id) : directory
        } catch { issue = error.localizedDescription; return }
        if projectToEdit == nil {
            if store.addProject(project) { onSaved(project.id); dismiss() }
        } else {
            project.archivedAt = archived ? (projectToEdit?.archivedAt ?? Date()) : nil
            if store.updateProject(project) { onSaved(project.id); dismiss() }
        }
    }
}
