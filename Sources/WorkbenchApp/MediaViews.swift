import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Server form (MD-01)

struct ServerSheet: View {
    @ObservedObject var store: WorkbenchStore
    var serverToEdit: ComfyServer?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var baseURL = "http://127.0.0.1:8188"
    @State private var useSSH = false
    @State private var hostAlias = ""
    @State private var sshUser = ""
    @State private var sshPort = ""
    @State private var identityFile = ""
    @State private var usesPassword = false
    @State private var sshPassword = ""
    @State private var hostKeyPolicy = SSHHostKeyPolicy.acceptNew
    @State private var remoteHost = "127.0.0.1"
    @State private var localPort = 8189
    @State private var remotePort = 8188
    @State private var startCommand = ""
    @State private var stopCommand = ""
    @State private var startupWait = 300.0
    @State private var requiresToken = false
    @State private var token = ""
    @State private var price = ""
    @State private var currency = "CNY"
    @State private var downloadMB = 512.0
    @State private var uploadMB = 200.0
    @State private var jobLimit = 1
    @State private var timeout = 3600.0
    @State private var issue: String?

    private func lines(_ text: String) -> [String]? {
        let value = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return value.isEmpty ? nil : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(serverToEdit == nil ? "添加制作服务器" : "编辑制作服务器").font(.system(size: 23, weight: .medium))
            Text("运行 ComfyUI 的服务器，通常是按需开机的云 GPU。工作台只连接你填写的地址；只有点“启动”“停止”时才会运行你填写的开关机命令。").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField("名称", text: $name, prompt: Text("例如 AutoDL 4090"))
                Section("连接") {
                    Toggle("通过 SSH 隧道连接（只在本机 127.0.0.1 开放）", isOn: $useSSH)
                    if useSSH {
                        TextField("主机", text: $hostAlias, prompt: Text("~/.ssh/config 中的别名，或地址，如 connect.example.com"))
                        TextField("用户名", text: $sshUser, prompt: Text("可留空，如 root"))
                        TextField("SSH 端口", text: $sshPort, prompt: Text("可留空，默认 22"))
                        Picker("登录方式", selection: $usesPassword) { Text("私钥或 ssh-agent").tag(false); Text("密码（存入钥匙串）").tag(true) }.pickerStyle(.segmented)
                        if usesPassword {
                            SecureField(serverToEdit?.ssh?.usesPassword == true ? "新密码（留空保留原值）" : "SSH 密码", text: $sshPassword)
                            Text("密码只存在钥匙串里；连接时通过 SSH_ASKPASS 只交给这次的 ssh 进程。能用密钥时建议用密钥。").font(.system(size: 10)).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                TextField("私钥文件", text: $identityFile, prompt: Text("可留空，使用 ssh-agent 或 ~/.ssh/config"))
                                Button("选择…") { chooseKey() }
                            }
                        }
                        Picker("主机密钥", selection: $hostKeyPolicy) { ForEach(SSHHostKeyPolicy.allCases, id: \.self) { Text($0.title).tag($0) } }
                        TextField("本机端口", value: $localPort, format: .number.grouping(.never))
                        TextField("ComfyUI 端口（服务器上）", value: $remotePort, format: .number.grouping(.never))
                        TextField("ComfyUI 地址（从 SSH 主机看）", text: $remoteHost, prompt: Text("127.0.0.1"))
                    } else { TextField("ComfyUI 地址", text: $baseURL) }
                    Toggle("需要 Bearer API 凭证", isOn: $requiresToken)
                    if requiresToken { SecureField(serverToEdit == nil ? "API 凭证（只存入钥匙串）" : "新凭证（留空保留原值）", text: $token) }
                }
                Section("开机与关机（可选）") {
                    commandEditor("启动命令，每行一个参数（例如云厂商 CLI 的开机命令）", text: $startCommand)
                    commandEditor("停止命令，每行一个参数", text: $stopCommand)
                    TextField("启动后等待就绪（秒）", value: $startupWait, format: .number.grouping(.never))
                    Text("命令不经过 shell，第一行可以是命令名（从登录 Shell 的 PATH 查找）或绝对路径。只有点服务器卡片上的“启动”“停止”时才会运行。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("用量") {
                    HStack { TextField("每小时价格（用于估算，可留空）", text: $price); TextField("币种", text: $currency).frame(width: 80) }
                    Stepper("同时运行 \(jobLimit) 个任务", value: $jobLimit, in: 1...8)
                    TextField("下载上限（MB）", value: $downloadMB, format: .number)
                    TextField("上传上限（MB）", value: $uploadMB, format: .number)
                    TextField("单个任务超时（秒）", value: $timeout, format: .number)
                }
            }.formStyle(.grouped)
            Text("服务器需要支持按编号取消单个任务（ComfyUI 的 /api/jobs 接口），否则不能运行任务。价格只用于估算，不是服务端的计费上限。").font(.system(size: 10)).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("保存") { save() }.buttonStyle(.borderedProminentPointer).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(28).frame(width: 680, height: 820)
            .onAppear {
                guard let server = serverToEdit else { return }
                name = server.name; baseURL = server.baseURL; requiresToken = server.requiresToken
                price = server.hourlyPrice.map { String($0) } ?? ""; currency = server.currency ?? "CNY"
                downloadMB = Double(server.maximumDownloadBytes) / 1_048_576; uploadMB = Double(server.maximumUploadBytes) / 1_048_576
                jobLimit = server.jobLimit; timeout = server.timeoutSeconds
                startCommand = (server.startCommand ?? []).joined(separator: "\n"); stopCommand = (server.stopCommand ?? []).joined(separator: "\n")
                startupWait = server.startupWaitSeconds ?? 300
                if let ssh = server.ssh {
                    useSSH = true; hostAlias = ssh.hostAlias; localPort = ssh.localPort; remotePort = ssh.remotePort
                    sshUser = ssh.user ?? ""; sshPort = ssh.port.map(String.init) ?? ""; identityFile = ssh.identityFile ?? ""
                    usesPassword = ssh.usesPassword == true; hostKeyPolicy = ssh.hostKeyPolicy ?? .strict; remoteHost = ssh.remoteHost ?? "127.0.0.1"
                }
            }
    }
    private func commandEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11))
            TextEditor(text: text).font(.system(size: 11, design: .monospaced)).frame(height: 44).padding(4)
        }
    }
    private func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
    }
    private func save() {
        guard downloadMB.isFinite, (1...8192).contains(downloadMB), uploadMB.isFinite, (1...8192).contains(uploadMB), timeout.isFinite, (1...86400).contains(timeout) else { issue = "下载与上传上限应为 1–8192 MB，超时为 1–86400 秒。"; return }
        guard startupWait.isFinite, (10...3600).contains(startupWait) else { issue = "启动后等待时间应为 10–3600 秒。"; return }
        let hourly = price.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Double(price)
        if !price.trimmingCharacters(in: .whitespaces).isEmpty && (hourly == nil || hourly! < 0) { issue = "价格需要是数字。"; return }
        let portText = sshPort.trimmingCharacters(in: .whitespaces)
        if useSSH && !portText.isEmpty && Int(portText) == nil { issue = "SSH 端口需要是数字。"; return }
        func trimmed(_ text: String) -> String? { let value = text.trimmingCharacters(in: .whitespaces); return value.isEmpty ? nil : value }
        var server = serverToEdit ?? ComfyServer(name: name, baseURL: baseURL)
        server.name = name; server.baseURL = useSSH ? "http://127.0.0.1:\(remotePort)" : baseURL
        server.ssh = useSSH ? SSHConnection(hostAlias: hostAlias.trimmingCharacters(in: .whitespaces), localPort: localPort, remotePort: remotePort, user: trimmed(sshUser), port: Int(portText),
                                            identityFile: usesPassword ? nil : trimmed((identityFile as NSString).expandingTildeInPath), usesPassword: usesPassword ? true : nil,
                                            hostKeyPolicy: hostKeyPolicy, remoteHost: trimmed(remoteHost).flatMap { $0 == "127.0.0.1" ? nil : $0 }) : nil
        server.startCommand = lines(startCommand); server.stopCommand = lines(stopCommand); server.startupWaitSeconds = startupWait == 300 ? nil : startupWait
        server.requiresToken = requiresToken; server.hourlyPrice = hourly; server.currency = currency
        server.maximumDownloadBytes = Int64(downloadMB * 1_048_576); server.maximumUploadBytes = Int64(uploadMB * 1_048_576)
        server.jobLimit = jobLimit; server.timeoutSeconds = timeout
        if store.saveServer(server, token: token.isEmpty ? nil : token, sshPassword: usesPassword && !sshPassword.isEmpty ? sshPassword : nil) { dismiss() }
        else { issue = store.errorMessage == RemoteError.invalidConfiguration.errorDescription ? "连接设置无效：请检查主机、用户名、端口（本机端口 1024–65535）和私钥路径。" : store.errorMessage; store.errorMessage = nil }
    }
}

// MARK: Template import and mapping (MD-05–07)

struct TemplateSheet: View {
    @ObservedObject var store: WorkbenchStore
    var templateToEdit: WorkflowTemplate?
    @Environment(\.dismiss) private var dismiss
    @State private var template: WorkflowTemplate?
    @State private var estimate = ""
    @State private var issue: String?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(templateToEdit == nil ? "导入工作流模板" : "编辑工作流模板").font(.system(size: 23, weight: .medium))
            Text("导入 ComfyUI 导出的 API 格式工作流，选择要开放的输入作为参数，并标出产生结果的输出节点。导演只能修改这里开放的参数。").font(.system(size: 12)).foregroundStyle(.secondary)
            if template == nil {
                Button("选择 API 格式 JSON…") { chooseWorkflow() }.buttonStyle(StudioPrimaryButtonStyle())
            }
            if let binding = Binding($template) {
                ScrollView { editor(binding).padding(.trailing, 8) }
            }
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                if template != nil && templateToEdit == nil { Button("重新选择文件") { chooseWorkflow() } }
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(.borderedProminentPointer).keyboardShortcut(.defaultAction).disabled(template == nil)
            }
        }.padding(28).frame(width: 760, height: 780)
            .onAppear { template = templateToEdit; estimate = templateToEdit?.estimatedSeconds.map { String(Int($0)) } ?? "" }
    }

    @ViewBuilder private func editor(_ template: Binding<WorkflowTemplate>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("名称", text: template.name)
                TextField("说明（导演会读到）", text: template.description, axis: .vertical).lineLimit(2...4)
                TextField("预计每次运行秒数（可留空，之后按实际记录估算）", text: $estimate)
                Section("用于这些工作区") {
                    ForEach(store.workspaces) { area in
                        Toggle(area.name, isOn: Binding(get: { template.wrappedValue.moduleIDs.contains(area.id) }, set: { on in
                            if on { template.wrappedValue.moduleIDs.append(area.id) } else { template.wrappedValue.moduleIDs.removeAll { $0 == area.id } }
                        }))
                    }
                }
            }.formStyle(.grouped).frame(height: 470)
            Text("版本 \(WorkflowTemplate.hash(template.wrappedValue.workflow))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Text("参数（\(template.wrappedValue.parameters.count)）").font(.system(size: 14, weight: .semibold))
            ForEach(template.parameters.indices, id: \.self) { index in parameterRow(template, index) }
            Text("可开放的节点输入").font(.system(size: 14, weight: .semibold))
            TextField("筛选节点或输入名", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            let used = Set(template.wrappedValue.parameters.map { $0.nodeID + "." + $0.inputName })
            ForEach(WorkflowTemplate.candidateInputs(of: template.wrappedValue.workflow).filter { !used.contains($0.id) && (filter.isEmpty || ($0.title + $0.classType + $0.inputName).localizedCaseInsensitiveContains(filter)) }) { input in
                HStack {
                    Text("#\(input.nodeID) \(input.title) · \(input.inputName)").font(.system(size: 11)).lineLimit(1)
                    Text(preview(input.value)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("开放为参数") { template.wrappedValue.parameters.append(TemplateParameter(name: suggestedName(input, existing: template.wrappedValue.parameters), nodeID: input.nodeID, inputName: input.inputName, type: guessType(input), defaultValue: input.value)) }.font(.system(size: 10))
                }
            }
            Text("输出节点").font(.system(size: 14, weight: .semibold))
            let nodes = (try? WorkflowTemplate.nodes(of: template.wrappedValue.workflow)) ?? [:]
            ForEach(nodes.keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }, id: \.self) { nodeID in
                let classType = nodes[nodeID]?["class_type"].string ?? ""
                if WorkflowTemplate.outputClasses[classType] != nil || template.wrappedValue.outputs.contains(where: { $0.nodeID == nodeID }) || classType.localizedCaseInsensitiveContains("save") {
                    HStack {
                        Toggle("#\(nodeID) \(classType)", isOn: Binding(get: { template.wrappedValue.outputs.contains { $0.nodeID == nodeID } }, set: { on in
                            if on { template.wrappedValue.outputs.append(TemplateOutput(nodeID: nodeID, kind: WorkflowTemplate.outputClasses[classType] ?? .other)) } else { template.wrappedValue.outputs.removeAll { $0.nodeID == nodeID } }
                        })).font(.system(size: 11))
                        if let index = template.wrappedValue.outputs.firstIndex(where: { $0.nodeID == nodeID }) {
                            Picker("类型", selection: template.outputs[index].kind) { ForEach(MediaKind.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 90)
                        }
                    }
                }
            }
            Text("没有标出的输出节点产生的文件也会下载，但会标注为未声明。").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func parameterRow(_ template: Binding<WorkflowTemplate>, _ index: Int) -> some View {
        let parameter = template.parameters[index]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("参数名", text: parameter.name).textFieldStyle(.roundedBorder).frame(width: 150)
                Picker("类型", selection: parameter.type) { ForEach(ParameterType.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 110)
                Text("#\(parameter.wrappedValue.nodeID) · \(parameter.wrappedValue.inputName)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("移除", role: .destructive) { template.wrappedValue.parameters.remove(at: index) }.font(.system(size: 10)).buttonStyle(.linkPointer)
            }
            HStack {
                TextField("说明", text: parameter.description).textFieldStyle(.roundedBorder)
                if [.integer, .number, .seed].contains(parameter.wrappedValue.type) {
                    TextField("最小", value: parameter.minimum, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                    TextField("最大", value: parameter.maximum, format: .number).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                if parameter.wrappedValue.type == .choice {
                    TextField("选项，用逗号分隔", text: Binding(get: { (parameter.wrappedValue.choices ?? []).joined(separator: ",") }, set: { parameter.wrappedValue.choices = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
        }.font(.system(size: 11)).padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func preview(_ value: JSONValue) -> String {
        switch value { case .string(let text): return "\"\(text.prefix(40))\""; case .number(let number): return String(number); case .bool(let flag): return String(flag); default: return "" }
    }
    private func guessType(_ input: NodeInput) -> ParameterType {
        if ["seed", "noise_seed"].contains(input.inputName) { return .seed }
        if input.inputName == "image" { return .image }
        if input.inputName == "audio" { return .audio }
        if input.inputName == "video" { return .video }
        switch input.value { case .number(let n): return n.rounded() == n ? .integer : .number; case .bool: return .boolean; default: return .text }
    }
    private func suggestedName(_ input: NodeInput, existing: [TemplateParameter]) -> String {
        let base = input.inputName.replacingOccurrences(of: "[^A-Za-z0-9_]", with: "_", options: .regularExpression)
        var name = base.isEmpty ? "param" : base, counter = 2
        while existing.contains(where: { $0.name == name }) { name = "\(base)_\(counter)"; counter += 1 }
        return name
    }
    private func chooseWorkflow() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            _ = try WorkflowTemplate.nodes(of: data)
            let suggestion = WorkflowTemplate.suggest(for: data)
            template = WorkflowTemplate(name: url.deletingPathExtension().lastPathComponent, moduleIDs: [], workflow: data, parameters: suggestion.parameters, outputs: suggestion.outputs)
            issue = nil
        } catch { issue = "请选择 ComfyUI 中“导出（API）”得到的 JSON，大小不超过 5 MB。" }
    }
    private func save() {
        guard var template else { return }
        let trimmed = estimate.trimmingCharacters(in: .whitespaces)
        template.estimatedSeconds = trimmed.isEmpty ? nil : Double(trimmed)
        if store.saveTemplate(template) { dismiss() } else { issue = store.errorMessage; store.errorMessage = nil }
    }
}

// MARK: Manual run (MD-09)

struct ManualRunSheet: View {
    @ObservedObject var store: WorkbenchStore
    var templateID: UUID
    var onSubmitted: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var serverID: UUID?
    @State private var projectID: UUID?
    @State private var title = ""
    @State private var values: [String: String] = [:]
    @State private var files: [String: String] = [:]
    @State private var issue: String?
    @State private var variants = 1
    private var template: WorkflowTemplate? { store.snapshot.template(templateID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("运行模板「\(template?.name ?? "")」").font(.system(size: 22, weight: .medium))
            Form {
                TextField("任务标题（可留空）", text: $title)
                Picker("服务器", selection: $serverID) { ForEach(store.enabledServers) { server in Text(serverLabel(server)).tag(Optional(server.id)) } }
                Picker("项目", selection: $projectID) { Text("未归属项目").tag(Optional<UUID>.none); ForEach(store.activeProjects) { Text($0.name).tag(Optional($0.id)) } }
                Stepper("变体 \(variants) 个（不同种子）", value: $variants, in: 1...8)
                if let template, let serverID, !template.missingNodes(on: store.serverHealth[serverID]).isEmpty {
                    Label("这台服务器缺少节点：\(template.missingNodes(on: store.serverHealth[serverID]).joined(separator: "、"))", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let template {
                    Section("参数") {
                        ForEach(template.parameters) { parameter in field(parameter) }
                    }
                }
            }.formStyle(.grouped)
            Text(estimateText).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("提交后才会上传文件并在服务器上运行；random 种子会在提交前变成具体数字并记录。").font(.system(size: 10)).foregroundStyle(.secondary)
            if let issue { Text(issue).font(.system(size: 11)).foregroundStyle(.red) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("提交") { submit() }.buttonStyle(.borderedProminentPointer).keyboardShortcut(.defaultAction).disabled(serverID == nil) }
        }.padding(28).frame(width: 620, height: 720)
            .onAppear {
                serverID = store.enabledServers.first?.id
                projectID = store.currentProject?.isArchived == false ? store.activeProjectID : nil
                for parameter in template?.parameters ?? [] where !parameter.type.isFile {
                    switch parameter.defaultValue {
                    case .string(let text): values[parameter.name] = text
                    case .number(let number): values[parameter.name] = number.rounded() == number ? String(Int64(number)) : String(number)
                    case .bool(let flag): values[parameter.name] = flag ? "true" : "false"
                    default: values[parameter.name] = parameter.type == .seed ? "random" : ""
                    }
                }
            }
    }

    private func serverLabel(_ server: ComfyServer) -> String {
        store.serverHealth[server.id]?.usable == false ? server.name + "（检测未通过）" : server.name
    }
    private var estimateText: String {
        let estimate = store.estimate(templateID: templateID, serverID: serverID)
        let time: String = estimate.seconds.map { String(format: "%.1f 分钟", $0 * Double(variants) / 60) } ?? "时间未知"
        let currency = store.snapshot.server(serverID)?.currency ?? ""
        let cost: String = estimate.cost.map { String(format: " · 约 %.2f ", $0 * Double(variants)) + currency } ?? " · 费用未知"
        return "预计 " + time + cost + "（估算）"
    }
    @ViewBuilder private func field(_ parameter: TemplateParameter) -> some View {
        let label = parameter.name + (parameter.description.isEmpty ? "" : "（\(parameter.description)）")
        switch parameter.type {
        case .image, .audio, .video:
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                Text(files[parameter.name].map { ($0 as NSString).lastPathComponent } ?? "未选择").foregroundStyle(.secondary).lineLimit(1)
                Button("选择…") { choose(parameter) }
            }
        case .boolean:
            Toggle(label, isOn: Binding(get: { values[parameter.name] == "true" }, set: { values[parameter.name] = $0 ? "true" : "false" }))
        case .choice:
            Picker(label, selection: Binding(get: { values[parameter.name] ?? "" }, set: { values[parameter.name] = $0 })) { ForEach(parameter.choices ?? [], id: \.self) { Text($0).tag($0) } }
        case .text:
            TextField(label, text: Binding(get: { values[parameter.name] ?? "" }, set: { values[parameter.name] = $0 }), axis: .vertical).lineLimit(1...4)
        default:
            TextField(label, text: Binding(get: { values[parameter.name] ?? "" }, set: { values[parameter.name] = $0 }))
        }
    }
    private func choose(_ parameter: TemplateParameter) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = parameter.type == .image ? [.image] : (parameter.type == .audio ? [.audio] : [.movie, .video])
        if panel.runModal() == .OK, let url = panel.url { files[parameter.name] = url.path }
    }
    private func submit() {
        guard let serverID else { return }
        if let id = store.submitGeneration(templateID: templateID, serverID: serverID, projectID: projectID, title: title, values: values, files: files, variants: variants) { dismiss(); onSubmitted(id) }
        else { issue = store.errorMessage; store.errorMessage = nil }
    }
}

// MARK: Previews (MD-11)

struct MediaPreview: View {
    let url: URL
    var compact = false
    var body: some View {
        switch MediaKind.of(fileExtension: url.pathExtension) {
        case .image: ImageFilePreview(url: url, compact: compact)
        case .video: VideoFilePreview(url: url, compact: compact)
        case .audio: AudioFilePreview(url: url)
        case .other: Button("使用系统应用打开") { NSWorkspace.shared.open(url) }.buttonStyle(.borderedPointer)
        }
    }
}

private struct ImageFilePreview: View {
    let url: URL
    var compact: Bool
    @State private var zoomed = false
    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: compact ? 120 : 240).clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { zoomed = true }.pointerCursor().help("点击放大").accessibilityLabel("图片 \(url.lastPathComponent)，点击放大")
                    .sheet(isPresented: $zoomed) {
                        VStack { Image(nsImage: image).resizable().scaledToFit(); HStack { Text("\(Int(image.size.width))×\(Int(image.size.height))").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button("关闭") { zoomed = false }.keyboardShortcut(.cancelAction) } }
                            .padding(20).frame(minWidth: 700, minHeight: 560)
                    }
            } else { Text("图片无法读取").font(.system(size: 10)).foregroundStyle(.red) }
        }
    }
}

private struct VideoFilePreview: View {
    let url: URL
    var compact: Bool
    @State private var player: AVPlayer?
    @State private var info = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NativePlayer(player: player).frame(height: compact ? 140 : 260).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityLabel("视频 \(url.lastPathComponent)")
            Text(info).font(.system(size: 10)).foregroundStyle(.secondary)
        }.task(id: url) {
            player = AVPlayer(url: url)
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            var size = CGSize.zero, fps: Float = 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first { size = (try? await track.load(.naturalSize)) ?? .zero; fps = (try? await track.load(.nominalFrameRate)) ?? 0 }
            info = String(format: "%.1f 秒 · %d×%d · %.0f fps", seconds, Int(size.width), Int(size.height), fps)
        }
    }
}

/// AppKit's player view: native play, scrub and frame-step controls.
private struct NativePlayer: NSViewRepresentable {
    var player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.showsFrameSteppingButtons = true; view.player = player; return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}

private struct AudioFilePreview: View {
    let url: URL
    @State private var levels: [Float] = []
    @State private var duration = 0.0
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    var body: some View {
        HStack(spacing: 10) {
            Button { toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }.buttonStyle(.borderedPointer).accessibilityLabel(playing ? "暂停" : "播放")
            Canvas { context, size in
                guard !levels.isEmpty else { return }
                let width = size.width / CGFloat(levels.count)
                for (index, level) in levels.enumerated() {
                    let height = max(1, CGFloat(level) * size.height)
                    context.fill(Path(CGRect(x: CGFloat(index) * width, y: (size.height - height) / 2, width: max(1, width - 1), height: height)), with: .color(.accentColor.opacity(0.7)))
                }
            }.frame(height: 40).accessibilityLabel("音频波形")
            Text(String(format: "%.1f 秒", duration)).font(.system(size: 10)).foregroundStyle(.secondary)
        }.task(id: url) { (levels, duration) = await MediaAnalysis.waveform(url) }
            .onDisappear { player?.stop() }
    }
    private func toggle() {
        if player == nil { player = try? AVAudioPlayer(contentsOf: url) }
        guard let player else { return }
        if player.isPlaying { player.pause(); playing = false } else { player.play(); playing = true }
    }
}

enum MediaAnalysis {
    /// Peak level per bucket, read with AVAssetReader so any format AVFoundation decodes works.
    static func waveform(_ url: URL, buckets: Int = 120) async -> ([Float], Double) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return ([], duration) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1])
        reader.add(output); reader.startReading()
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &chunk)
            samples += chunk.enumerated().filter { $0.offset % 8 == 0 }.map(\.element)
            if samples.count > 4_000_000 { break }
        }
        guard !samples.isEmpty else { return ([], duration) }
        let size = max(1, samples.count / buckets)
        let peaks = stride(from: 0, to: samples.count, by: size).map { start in Float(samples[start..<min(samples.count, start + size)].map { abs(Int($0)) }.max() ?? 0) / Float(Int16.max) }
        return (peaks, duration)
    }
}

/// Two images side by side (MD-11 compare).
struct ImageCompareSheet: View {
    let left: URL
    let right: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach([left, right], id: \.self) { url in
                    VStack {
                        if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
                        Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(minWidth: 900, minHeight: 560)
    }
}
