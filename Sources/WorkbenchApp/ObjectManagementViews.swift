import SwiftUI

struct ObjectDeletionModifier: ViewModifier {
    @ObservedObject var store: WorkbenchStore
    @ObservedObject var terminals: TerminalWorkspace
    var onDeleted: (DeletionTarget) -> Void
    func body(content: Content) -> some View {
        content.alert("删除「\(store.pendingDeletion.map { store.snapshot.objectName($0) } ?? "")」？", isPresented: Binding(get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } })) {
            Button("取消", role: .cancel) { store.pendingDeletion = nil }
            Button("删除", role: .destructive) {
                guard let target = store.pendingDeletion else { return }
                store.pendingDeletion = nil
                if terminalInUse(target) { store.errorMessage = "相关终端会话仍在运行，请先结束该会话再删除。"; return }
                if store.deleteObject(target) { onDeleted(target) }
            }
        } message: { Text(store.pendingDeletion.map { store.deletionExplanation($0) } ?? "") }
    }
    private func terminalInUse(_ target: DeletionTarget) -> Bool {
        terminals.sessions.contains { session in
            guard !session.ended else { return false }
            switch target.kind {
            case .employee: return session.employeeID == target.objectID
            case .tool: return session.toolID == target.objectID
            case .project:
                guard let project = store.project(target.objectID) else { return false }
                let directory = WorkbenchStore.folderKey(project.directory), terminal = WorkbenchStore.folderKey(session.directory)
                return directory == terminal || terminal.hasPrefix(directory + "/")
            case .conversation:
                guard let conversation = store.conversation(target.objectID), let project = store.project(conversation.projectID) else { return false }
                return WorkbenchStore.folderKey(project.directory) == WorkbenchStore.folderKey(session.directory)
            default: return false
            }
        }
    }
}

struct WorkspaceMemberPicker: View {
    @ObservedObject var store: WorkbenchStore
    var area: WorkArea
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var candidates: [Employee] {
        let members = Set(store.employees(in: area).map(\.id))
        return store.snapshot.employees.current.filter { !members.contains($0.id) && (search.isEmpty || ($0.name + $0.role).localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加已有员工到「\(area.name)」").font(.system(size: 21, weight: .semibold))
            Text("同一位员工可以加入多个工作区，保留原有档案、CLI 和历史记录。").font(.system(size: 12)).foregroundStyle(.secondary)
            StudioSearchField(prompt: "搜索姓名或职位", text: $search)
            ScrollView {
                VStack(spacing: 10) {
                    if candidates.isEmpty { Text("没有可添加的员工。可先在员工目录创建员工。").foregroundStyle(.secondary) }
                    ForEach(candidates) { employee in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) { Text(employee.name); Text(employee.role).font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            Button("添加") { store.addExistingEmployee(employee.id, to: area.id) }.accessibilityLabel("添加员工 \(employee.name) 到 \(area.name)")
                        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520, height: 430)
    }
}
