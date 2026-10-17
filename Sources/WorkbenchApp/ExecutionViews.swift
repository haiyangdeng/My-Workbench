import AppKit
import SwiftUI
import ImageIO

struct ArtifactList: View {
    @ObservedObject var store: WorkbenchStore
    var runID: UUID?
    @State private var preview: UUID?
    private var items: [WorkArtifact] {
        store.snapshot.artifacts.filter { artifact in
            if let runID { return artifact.runID == runID }
            return artifact.projectID == store.activeProjectID
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if items.isEmpty { Text("尚无归档产物。执行后自动收集产物目录中的文件，也可主动导入。").font(.system(size: 11)).foregroundStyle(.secondary) }
            ForEach(items) { artifact in
                VStack(alignment: .leading, spacing: 8) {
                    Label(URL(fileURLWithPath: artifact.relativePath).lastPathComponent, systemImage: "doc").font(.system(size: 12, weight: .medium))
                    Text("\(ByteCountFormatter.string(fromByteCount: artifact.byteCount, countStyle: .file)) · \(artifact.fileType.uppercased()) · \(artifact.accepted ? "已验收" : "待检查")").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Button("预览") { preview = preview == artifact.id ? nil : artifact.id }.buttonStyle(.link)
                        Button("Finder") { perform { NSWorkspace.shared.activateFileViewerSelecting([try store.archive.url(for: artifact)]) } }.buttonStyle(.link)
                        if !artifact.accepted, store.snapshot.runs.first(where: { $0.id == artifact.runID })?.status == .completed {
                            Button("已检查") { store.acceptArtifact(artifact.id) }.buttonStyle(.link)
                        }
                    }.font(.system(size: 10))
                    if preview == artifact.id { ArtifactPreview(artifact: artifact, archive: store.archive) }
                    Divider()
                }
            }
        }
    }
    private func perform(_ body: () throws -> Void) { do { try body() } catch { store.errorMessage = error.localizedDescription } }
}

private struct ArtifactPreview: View {
    let artifact: WorkArtifact
    let archive: RunArchive
    private var url: URL? { try? archive.url(for: artifact) }
    var body: some View {
        if let url {
            if ["png", "jpg", "jpeg", "webp", "heic", "gif"].contains(artifact.fileType), let image = thumbnail(url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if ["txt", "md", "json", "csv", "swift", "py", "html", "log"].contains(artifact.fileType) {
                ReadOnlyTextView(text: readText(url), pointSize: 10, accessibilityName: "产物文本预览").frame(height: 150)
            } else {
                Button("使用系统应用预览") { NSWorkspace.shared.open(url) }.buttonStyle(.bordered)
            }
        } else { Text("文件已移动或不可访问。").font(.system(size: 10)).foregroundStyle(.red) }
    }
    private func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
    private func readText(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无法读取文件" }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 100000)) ?? Data()
        return String(decoding: bytes, as: UTF8.self) + (artifact.byteCount > 100000 ? "\n…预览显示前100KB" : "")
    }
}

struct ProjectConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory = ""
    @State private var goal = ""
    private var valid: Bool {
        var isDirectory: ObjCBool = false
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && directory.hasPrefix("/") && FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue && store.storageAvailable
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("把一个项目放上桌").font(.system(size: 24, weight: .medium))
            Text("任务、执行记录与产物分别归属于各自的项目。").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField("项目名称", text: $name)
                HStack {
                    TextField("工作目录", text: $directory)
                    Button("选择目录") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                    }
                }
                TextField("项目目标", text: $goal, axis: .vertical).lineLimit(3...6)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("放上项目桌") { if store.addProject(WorkProject(name: name, directory: directory, goal: goal)) { dismiss() } }.buttonStyle(.borderedProminent).disabled(!valid) }
        }.padding(30).frame(width: 560, height: 380)
    }
}

struct HandoffConfigurationSheet: View {
    let task: WorkTask
    let run: TaskRun
    @ObservedObject var store: WorkbenchStore
    @Environment(\.dismiss) private var dismiss
    @State private var target: UUID?
    @State private var selectedArtifacts: Set<UUID> = []
    @State private var goal = ""
    @State private var parameters = ""
    @State private var constraints = "保留来源文件，产物保存为新版本。"
    @State private var checks = ""
    @State private var questions = ""
    @State private var acceptance = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("把成果交给下一位伙伴").font(.system(size: 23, weight: .medium))
            Text("来源：\(task.title) · \(run.employee.name)\nrun \(run.id)").font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            Form {
                Picker("接收员工", selection: $target) {
                    ForEach(store.snapshot.employees.filter { $0.enabled ?? true }) { Text("\($0.name) · \($0.role)").tag(Optional($0.id)) }
                }
                TextField("下游任务目标", text: $goal, axis: .vertical).lineLimit(2...3)
                Section("交接文件 · 只列出此执行已验收的产物") {
                    ForEach(store.artifacts(for: run.id).filter(\.accepted)) { artifact in
                        Toggle(URL(fileURLWithPath: artifact.relativePath).lastPathComponent, isOn: Binding(get: { selectedArtifacts.contains(artifact.id) }, set: { if $0 { selectedArtifacts.insert(artifact.id) } else { selectedArtifacts.remove(artifact.id) } }))
                    }
                }
                TextField("参数", text: $parameters, axis: .vertical)
                TextField("约束", text: $constraints, axis: .vertical)
                TextField("已通过检查", text: $checks, axis: .vertical)
                TextField("待确认事项", text: $questions, axis: .vertical)
                TextField("验收标准", text: $acceptance, axis: .vertical).lineLimit(2...4)
            }.formStyle(.grouped)
            Text("确认后创建下游草稿，执行由你发起。").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("确认交接") { confirm() }.buttonStyle(.borderedProminent).disabled(target == nil || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(30).frame(width: 610, height: 680)
        .onAppear { target = store.snapshot.employees.first(where: { $0.id != task.employeeID && ($0.enabled ?? true) })?.id ?? task.employeeID; selectedArtifacts = Set(store.artifacts(for: run.id).filter(\.accepted).map(\.id)); checks = task.acceptance }
    }
    private func confirm() {
        guard let target else { return }
        let handoff = WorkHandoff(sourceTaskID: task.id, sourceRunID: run.id, targetEmployeeID: target, projectID: task.projectID, artifactIDs: Array(selectedArtifacts), goal: goal, parameters: parameters, constraints: constraints, passedChecks: checks, openQuestions: questions, acceptance: acceptance)
        if store.confirmHandoff(handoff) { dismiss() }
    }
}

struct RemoteToolConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    var toolToEdit: ToolConfig? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = "ComfyUI"
    @State private var baseURL = "http://127.0.0.1:8188"
    @State private var workflow = Data()
    @State private var workflowName = "未选择"
    @State private var budget = "价格未知，执行前检查服务预算"
    @State private var timeout = 3600.0
    @State private var downloadMB = 512.0
    @State private var requiresKey = false
    @State private var token = ""
    @State private var useSSH = false
    @State private var hostAlias = ""
    @State private var localPort = 8189
    @State private var remotePort = 8188
    @State private var issue: String?
    private var connection: ComfyConnection {
        ComfyConnection(baseURL: useSSH ? "http://127.0.0.1:\(localPort)" : baseURL, workflow: workflow, workflowName: workflowName, budgetNote: budget, maximumDownloadBytes: Int64(min(4096, max(1, downloadMB)) * 1024 * 1024), requiresAPIKey: requiresKey, ssh: useSSH ? SSHConnection(hostAlias: hostAlias, localPort: localPort, remotePort: remotePort) : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("给影像员工接入制作工具").font(.system(size: 23, weight: .medium))
            Text("选择服务与 API 工作流。提交会记录服务端编号，文件下载后再验收。").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField("工具名称", text: $name)
                Toggle("通过 SSH 隧道连接", isOn: $useSSH)
                if useSSH {
                    TextField("已有 SSH 配置别名", text: $hostAlias)
                    TextField("本地端口", value: $localPort, format: .number)
                    TextField("服务端口", value: $remotePort, format: .number)
                    Text("使用本机 SSH 配置和密钥，验证主机身份；仅在127.0.0.1开放隧道。").font(.system(size: 10)).foregroundStyle(.secondary)
                } else { TextField("ComfyUI 服务 URL", text: $baseURL) }
                HStack { Text("API 工作流：\(workflowName)").lineLimit(1); Spacer(); Button("选择 JSON") { chooseWorkflow() } }
                Text("从 ComfyUI 导出 API 格式工作流。文本中的 {input} 会替换为任务输入。").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("超时（秒）", value: $timeout, format: .number)
                TextField("下载上限（MB）", value: $downloadMB, format: .number)
                TextField("预算说明", text: $budget, axis: .vertical).lineLimit(2...3)
                Toggle("服务需要 Bearer API 凭证", isOn: $requiresKey)
                if requiresKey { SecureField(toolToEdit == nil ? "API 凭证" : "新凭证（留空保留原值）", text: $token); Text("凭证仅保存于 macOS 钥匙串。").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.formStyle(.grouped)
            Text("支持提供按编号取消接口的 ComfyUI 服务。预算说明用于执行前核对，费用上限由服务自身设置。").font(.system(size: 10)).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存配置") { save() }.buttonStyle(.borderedProminent).disabled(workflow.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.storageAvailable) }
        }.padding(30).frame(width: 640, height: 690)
        .onAppear {
            if let tool = toolToEdit, let remote = tool.remote {
                name = tool.name; baseURL = remote.baseURL; workflow = remote.workflow; workflowName = remote.workflowName
                budget = remote.budgetNote; timeout = tool.timeout; downloadMB = Double(remote.maximumDownloadBytes) / 1024 / 1024; requiresKey = remote.requiresAPIKey
                if let ssh = remote.ssh { useSSH = true; hostAlias = ssh.hostAlias; localPort = ssh.localPort; remotePort = ssh.remotePort }
            }
        }
    }
    private func chooseWorkflow() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5 * 1024 * 1024 else { throw RemoteError.invalidWorkflow }
                let data = try Data(contentsOf: url)
                _ = try ComfyConnection(baseURL: baseURL, workflow: data, workflowName: url.lastPathComponent).workflow(input: "测试输入")
                workflow = data; workflowName = url.lastPathComponent; issue = nil
            } catch { issue = error.localizedDescription }
        }
    }
    private func save() {
        do {
            guard timeout.isFinite, (1...86400).contains(timeout), downloadMB.isFinite, (1...4096).contains(downloadMB) else { issue = "超时应为1至86400秒，下载上限应为1至4096MB。"; return }
            _ = try ComfyClient(connection: connection); _ = try connection.workflow(input: "")
            if let ssh = connection.ssh { _ = try ssh.arguments() }
            var tool = ToolConfig(id: toolToEdit?.id ?? UUID(), name: name, executable: "/usr/bin/true", arguments: [])
            tool.adapter = .comfyUI; tool.timeoutSeconds = min(86400, max(1, timeout)); tool.remote = connection; tool.enabled = toolToEdit?.enabled
            if requiresKey && !token.isEmpty { try CredentialVault().save(token, toolID: tool.id) }
            if requiresKey { let savedToken = try CredentialVault().read(toolID: tool.id); if savedToken == nil { issue = "请先填写 API 凭证。"; return } }
            if toolToEdit == nil ? store.addTool(tool) : store.updateTool(tool) { dismiss() }
        } catch { issue = error.localizedDescription }
    }
}
