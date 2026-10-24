import AppKit
import SwiftUI

/// One form for every CLI. Nothing is pre-filled for any particular product; examples live in docs/PRD_V06.md Appendix A.
struct CLIConfigurationSheet: View {
    @ObservedObject var store: WorkbenchStore
    var toolToEdit: ToolConfig? = nil
    var onSaved: (UUID, Bool) -> Void = { _, _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable = ""
    @State private var resolvedPath: String?
    @State private var resolving = false
    @State private var resolveNote: String?
    @State private var useLoginShellPath = true
    @State private var newTurn = ""
    @State private var resume = ""
    @State private var terminalResume = ""
    @State private var format = CLIOutputFormat.plainText
    @State private var includeInstructions = true
    @State private var modelArguments = ""
    @State private var structuredArguments = ""
    @State private var readOnlyArguments = ""
    @State private var editArguments = ""
    @State private var versionArguments = "--version"
    @State private var loginStatusArguments = ""
    @State private var loggedOutText = ""
    @State private var loginArguments = ""
    @State private var timeout = 1800.0
    @State private var showAdvanced = false
    @State private var commandStep = false
    @State private var limit = ""
    @State private var environmentText = ""
    @State private var secretText = ""
    @State private var useSystemProxy = true

    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).filter { !$0.isEmpty } }
    private func optionalLines(_ text: String) -> [String]? { let value = lines(text); return value.isEmpty ? nil : value }

    private var plainEnvironment: [(name: String, value: String)]? { try? ToolConfig.parseEnvironment(environmentText) }
    private var secretEnvironment: [(name: String, value: String)]? { try? ToolConfig.parseEnvironment(secretText) }
    private var environmentIssue: String? {
        do {
            let plain = try ToolConfig.parseEnvironment(environmentText), secret = try ToolConfig.parseEnvironment(secretText)
            if let both = plain.first(where: { item in secret.contains { $0.name == item.name } }) { return "「\(both.name)」同时出现在普通变量和密钥变量中。" }
            return nil
        } catch { return error.localizedDescription }
    }

    private var draft: ToolConfig {
        var tool = ToolConfig(id: toolToEdit?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), executable: resolvedPath ?? executable, arguments: lines(newTurn))
        tool.adapter = .command; tool.enabled = toolToEdit?.enabled
        tool.timeoutSeconds = min(86400, max(0.1, timeout.isFinite ? timeout : 1800))
        tool.resumeArguments = optionalLines(resume); tool.interactiveResumeArguments = optionalLines(terminalResume); tool.outputFormat = format; tool.includeInstructions = includeInstructions
        tool.modelArguments = optionalLines(modelArguments); tool.structuredOutputArguments = optionalLines(structuredArguments)
        tool.readOnlyArguments = optionalLines(readOnlyArguments); tool.editArguments = optionalLines(editArguments)
        tool.versionArguments = lines(versionArguments); tool.loginStatusArguments = optionalLines(loginStatusArguments)
        let marker = loggedOutText.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.loggedOutText = marker.isEmpty ? nil : marker
        tool.loginArguments = optionalLines(loginArguments); tool.useLoginShellPath = useLoginShellPath
        tool.commandStep = commandStep ? true : nil
        tool.concurrencyLimit = Int(limit.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? min($0, 8) : nil }
        let plain = plainEnvironment ?? [], secret = secretEnvironment ?? []
        tool.environment = plain.isEmpty ? nil : Dictionary(plain.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
        tool.secretEnvironmentNames = secret.isEmpty ? nil : secret.map(\.name)
        tool.useSystemProxy = useSystemProxy ? nil : false
        tool.versionChanged = toolToEdit?.executable == tool.executable ? toolToEdit?.versionChanged : nil
        if let toolToEdit, toolToEdit.executable == tool.executable { tool.detectedVersion = toolToEdit.detectedVersion }
        return tool
    }
    private var valid: Bool {
        store.storageAvailable && !draft.name.isEmpty && resolvedPath != nil && (!lines(newTurn).isEmpty || commandStep) && timeout.isFinite && (0.1...86400).contains(timeout) && environmentIssue == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "terminal").font(.system(size: 20)).foregroundStyle(Theme.blue).frame(width: 45, height: 45).background(Theme.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(toolToEdit == nil ? "添加 CLI" : "编辑 CLI").font(.system(size: 22, weight: .semibold))
                    Text("工作台不内置任何 CLI。填写可执行文件和参数模板，保存不会开始执行。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text("例如 Claude Code"))
                    HStack {
                        TextField("可执行文件", text: $executable, prompt: Text("命令名（如 claude）或绝对路径")).onSubmit(resolve)
                            .onChange(of: executable) { _, value in if value != resolvedPath { resolvedPath = nil; resolveNote = nil } }
                        Button(resolving ? "查找中…" : "查找") { resolve() }.disabled(resolving || executable.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("选择文件…") { chooseExecutable() }
                    }
                    if let resolvedPath { Label(resolvedPath, systemImage: "checkmark.circle.fill").font(.system(size: 10, design: .monospaced)).foregroundStyle(.green).textSelection(.enabled) }
                    else if let note = resolveNote ?? (executable.hasPrefix("/") && !FileManager.default.isExecutableFile(atPath: executable) ? "这个路径不存在或不能执行。" : nil) {
                        Label(note, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    } else if !executable.isEmpty { Text("按回车或点“查找”确认路径。").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Toggle("使用登录 Shell 的 PATH", isOn: $useLoginShellPath)
                    Text("从访达打开的应用只有很短的 PATH。依赖 node 等其他命令的 CLI 需要打开此项。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("参数模板 · 每行一个参数") {
                    argumentEditor("新对话", text: $newTurn, height: 74)
                    argumentEditor("续接会话（可选）", text: $resume, height: 58)
                    argumentEditor("在终端继续会话（可选，交互模式）", text: $terminalResume, height: 34)
                    Picker("输出格式", selection: $format) { ForEach(CLIOutputFormat.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Text("占位符：{prompt} {session_id} {output} {workdir} {model} {instructions} {schema} {schema_file}。每个占位符只替换成一个参数，不经过 shell。单独一行 {flags} 放置权限、模型和结构化输出参数；没有时放在 -- 之前或末尾。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("权限 · 留空表示该权限不可用") {
                    argumentEditor("只读", text: $readOnlyArguments, height: 40)
                    argumentEditor("可编辑项目", text: $editArguments, height: 40)
                    if readOnlyArguments.isEmpty && editArguments.isEmpty {
                        Text("两项都留空时，工作台不管理这个 CLI 的权限，按模板原样运行。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if !draft.bypassWarnings.isEmpty {
                        Label("这些参数会跳过 CLI 自身的审批：\(draft.bypassWarnings.joined(separator: "、"))。工作台不会替你确认这些操作。", systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("更多设置", isExpanded: $showAdvanced) {
                    Toggle("把员工职责放在提示前面", isOn: $includeInstructions)
                    Text("模板里用了 {instructions} 时，职责只放在那里。").font(.system(size: 10)).foregroundStyle(.secondary)
                    argumentEditor("模型参数（员工设置模型时加入）", text: $modelArguments, height: 40)
                    argumentEditor("结构化输出参数（规划与审核时加入）", text: $structuredArguments, height: 40)
                    argumentEditor("版本检测参数", text: $versionArguments, height: 34)
                    argumentEditor("登录检测参数（可选）", text: $loginStatusArguments, height: 34)
                    TextField("表示未登录的文字（可选）", text: $loggedOutText)
                    argumentEditor("登录参数（在终端运行，可选）", text: $loginArguments, height: 34)
                    TextField("超时（秒）", value: $timeout, format: .number)
                    TextField("同时运行上限（可留空，最多 8）", text: $limit)
                    Toggle("可用于制作计划中的命令步骤（例如 ffmpeg）", isOn: $commandStep)
                    Text("命令步骤直接用导演写的参数运行这个程序，不经过 shell，也不加入提示或权限参数。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Section("网络与环境变量") {
                    Toggle("使用系统代理", isOn: $useSystemProxy)
                    Text(SystemProxy.summary().map { "系统代理：\($0)。从访达打开的应用不会继承终端里设置的代理变量，打开此项后 CLI 会通过它联网。" } ?? "系统设置里没有启用 HTTP、HTTPS 或 SOCKS 代理。").font(.system(size: 10)).foregroundStyle(.secondary)
                    argumentEditor("环境变量（每行 NAME=value，可选，随定义导出）", text: $environmentText, height: 46)
                    argumentEditor("密钥环境变量（每行 NAME=value，值存入钥匙串，不会导出；已保存的值显示为空，留空表示保留）", text: $secretText, height: 46)
                    if let environmentIssue { Label(environmentIssue, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange) }
                    else if let secret = secretEnvironment, let toolToEdit, let missing = secret.first(where: { $0.value.isEmpty && !store.hasSecretValue(toolID: toolToEdit.id, name: $0.name) }) {
                        Label("「\(missing.name)」还没有保存值。", systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                Section("预览") { preview }
            }.formStyle(.grouped)
            Text("CLI 以你的用户权限运行。工作目录不是沙箱，权限由 CLI 自身执行。").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 680, height: 780)
        .onAppear(perform: load)
    }

    private func argumentEditor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11))
            TextEditor(text: text).font(.system(size: 11, design: .monospaced)).frame(height: height).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.25)))
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder private var preview: some View {
        let tool = draft
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tool.managesAccess ? AccessLevel.allCases : [.readOnly], id: \.self) { level in
                let call = CLIInvocation(prompt: "你好", instructions: "（员工职责）", outputDirectory: "/归档/output", workingDirectory: "/项目", access: level, sessionID: tool.assignsSessionID ? "（新会话编号）" : nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.managesAccess ? level.title : "运行（未管理权限）").font(.system(size: 10, weight: .medium))
                    Text(commandLine(tool, call)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if tool.supportsResume {
                Text("续接").font(.system(size: 10, weight: .medium))
                Text(commandLine(tool, CLIInvocation(prompt: "继续", outputDirectory: "/归档/output", workingDirectory: "/项目", access: tool.supports(.readOnly) ? .readOnly : .edit, sessionID: "（会话编号）", resume: true))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
    private func commandLine(_ tool: ToolConfig, _ call: CLIInvocation) -> String {
        do { return ([tool.executable.isEmpty ? "（可执行文件）" : tool.executable] + (try tool.invocation(call))).map { $0.contains(where: { $0 == " " || $0 == "\n" || $0 == "\"" }) || $0.isEmpty ? String(reflecting: $0) : $0 }.joined(separator: " ") }
        catch { return error.localizedDescription }
    }

    private func resolve() {
        let text = executable
        resolving = true; resolveNote = nil
        Task {
            let lookup = await store.resolveExecutable(text)
            guard text == executable else { resolving = false; return }
            resolving = false
            if let path = lookup.executable { resolvedPath = path; executable = path }
            else { resolvedPath = nil; resolveNote = text.hasPrefix("/") ? "这个路径不存在或不能执行。" : "登录 Shell 中找不到「\(text)」。请确认已安装，或选择文件。" }
        }
    }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { executable = url.path; resolve() }
    }
    private func load() {
        guard let tool = toolToEdit else { return }
        name = tool.name; resolvedPath = tool.executableAvailable ? tool.executable : nil; executable = tool.executable
        useLoginShellPath = tool.useLoginShellPath ?? false
        newTurn = tool.arguments.joined(separator: "\n"); resume = (tool.resumeArguments ?? []).joined(separator: "\n")
        terminalResume = (tool.interactiveResumeArguments ?? []).joined(separator: "\n")
        format = tool.format; includeInstructions = tool.includeInstructions ?? false
        modelArguments = (tool.modelArguments ?? []).joined(separator: "\n"); structuredArguments = (tool.structuredOutputArguments ?? []).joined(separator: "\n")
        readOnlyArguments = (tool.readOnlyArguments ?? []).joined(separator: "\n"); editArguments = (tool.editArguments ?? []).joined(separator: "\n")
        versionArguments = (tool.versionArguments ?? ["--version"]).joined(separator: "\n")
        loginStatusArguments = (tool.loginStatusArguments ?? []).joined(separator: "\n"); loggedOutText = tool.loggedOutText ?? ""
        loginArguments = (tool.loginArguments ?? []).joined(separator: "\n"); timeout = tool.timeout
        commandStep = tool.commandStep == true
        limit = tool.concurrencyLimit.map(String.init) ?? ""
        environmentText = (tool.environment ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        secretText = (tool.secretEnvironmentNames ?? []).map { $0 + "=" }.joined(separator: "\n")
        useSystemProxy = tool.useSystemProxy != false
        showAdvanced = true
    }
    private func save() {
        let tool = draft
        let saved = toolToEdit == nil ? store.addTool(tool) : store.updateTool(tool)
        guard saved else { return }
        do {
            let secret = secretEnvironment ?? []
            try store.saveSecretEnvironment(toolID: tool.id, names: secret.map(\.name), values: Dictionary(secret.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }), previousNames: toolToEdit?.secretEnvironmentNames ?? [])
        } catch { store.errorMessage = error.localizedDescription }
        dismiss(); onSaved(tool.id, toolToEdit == nil)
    }
}
