import AppKit
import SwiftUI

/// Connections page: every CLI the user added, plus ComfyUI services. Empty until the user adds one.
struct ToolShelfView: View {
    @ObservedObject var store: WorkbenchStore
    var accent: Color
    var onAddCLI: () -> Void
    var onEditCLI: (ToolConfig) -> Void
    var onAddRemote: () -> Void
    var onEditRemote: (ToolConfig) -> Void
    var onAddEmployee: () -> Void
    var onLogin: (ToolConfig) -> Void
    var onAddServer: () -> Void = {}
    var onEditServer: (ComfyServer) -> Void = { _ in }
    var onAddTemplate: () -> Void = {}
    var onEditTemplate: (WorkflowTemplate) -> Void = { _ in }
    var onRunTemplate: (WorkflowTemplate) -> Void = { _ in }
    var onImportCLI: () -> Void = {}
    var onExportCLI: (ToolConfig) -> Void = { _ in }
    @State private var confirmStopServer: ComfyServer?

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            Text("趁手的工具，\n放在一起。").font(.system(size: 24, weight: .medium))
            if !store.hasCLI {
                VStack(alignment: .leading, spacing: 12) {
                    Label("还没有添加 CLI", systemImage: "terminal").font(.system(size: 15, weight: .semibold))
                    Text("工作台不内置任何 CLI。每个 CLI（例如 Claude Code、Codex）都由你手动添加：填写可执行文件和参数模板。添加后即可安排 AI 员工。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    Button("添加 CLI", action: onAddCLI).buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable).accessibilityIdentifier("tools.add-cli.empty")
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            } else {
                Text("每个 CLI 可被多位员工使用。保存配置不会开始执行；版本与登录检测不调用模型。").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(store.cliTools) { tool in cliCard(tool) }
            HStack {
                if store.hasCLI { Button("添加 CLI", action: onAddCLI).buttonStyle(StudioPrimaryButtonStyle()).disabled(!store.storageAvailable).accessibilityIdentifier("tools.add-cli") }
                Button("导入 CLI 定义…", action: onImportCLI).buttonStyle(.borderedPointer).disabled(!store.storageAvailable)
                Button("安排新员工", action: onAddEmployee).buttonStyle(.borderedPointer).disabled(store.snapshot.tools.current.isEmpty || !store.storageAvailable)
            }
            Divider().padding(.vertical, 6)
            Text("制作服务器").font(.system(size: 18, weight: .semibold))
            Text("运行 ComfyUI 的服务器（影像、声音、视觉工作区使用）。导演只能使用这里启用、并通过检测的服务器。").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(store.snapshot.servers.current) { server in serverCard(server) }
            Button("添加服务器", action: onAddServer).buttonStyle(.borderedPointer).disabled(!store.storageAvailable).accessibilityIdentifier("tools.add-server")
            Text("工作流模板").font(.system(size: 18, weight: .semibold)).padding(.top, 8)
            Text("从 ComfyUI 导出的 API 格式工作流，开放的参数可以手动填写，也可以交给导演。").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(store.snapshot.templates.current) { template in templateCard(template) }
            Button("导入工作流模板", action: onAddTemplate).buttonStyle(.borderedPointer).disabled(!store.storageAvailable).accessibilityIdentifier("tools.add-template")
            if store.snapshot.tools.current.contains(where: { !$0.isCLI }) {
                Text("旧版 ComfyUI 工具").font(.system(size: 13, weight: .semibold)).padding(.top, 6)
                Text("已自动转换为上面的服务器和模板；旧的员工和任务仍按原方式运行。").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(store.snapshot.tools.current.filter { !$0.isCLI }) { tool in remoteCard(tool) }
            }
        }
        .confirmationDialog("服务器上还有任务在运行", isPresented: Binding(get: { confirmStopServer != nil }, set: { if !$0 { confirmStopServer = nil } }), titleVisibility: .visible) {
            Button("仍然停止服务器", role: .destructive) { if let server = confirmStopServer { store.runServerCommand(server.id, start: false) }; confirmStopServer = nil }
            Button("取消", role: .cancel) { confirmStopServer = nil }
        } message: { Text("停止后正在运行的生成任务会中断，已提交的任务不会自动重新提交。") }
    }

    private func cliCard(_ tool: ToolConfig) -> some View {
        let missing = !tool.executableAvailable
        let check = store.loginCheck(for: tool)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(tool.name, systemImage: "terminal").font(.system(size: 13, weight: .medium))
                Spacer()
                if tool.versionChanged == true { chip("版本已变化，请重新检测登录并测试", color: .orange) }
                chip(missing ? "缺失" : (tool.isEnabled ? "可执行" : "已停用"), color: missing ? .orange : (tool.isEnabled ? accent : .secondary))
            }
            Text(tool.executable).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(missing ? .orange : .primary)
            Text([tool.format.title, tool.managesAccess ? "权限：" + AccessLevel.allCases.filter(tool.supports).map(\.title).joined(separator: "、") : "权限：未由工作台管理", tool.supportsResume ? "可续接会话" : "不续接会话", tool.concurrencyLimit.map { "同时最多 \($0) 个" }, tool.commandStep == true ? "可用于命令步骤" : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let version = tool.detectedVersion { Text(version).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
            if tool.authenticationStatusArguments != nil {
                HStack(spacing: 6) {
                    Circle().fill(check.state == .loggedIn ? accent : (check.state == .loggedOut || check.state == .failed ? .orange : .gray)).frame(width: 6, height: 6)
                    Text("登录：" + check.state.title).font(.system(size: 10))
                    if let date = check.checkedAt { Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if check.state == .failed || check.state == .loggedOut { Text(check.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
            }
            if !tool.bypassWarnings.isEmpty {
                Label("参数会跳过 CLI 自身的审批：\(tool.bypassWarnings.joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack {
                if missing { Button("修正路径") { onEditCLI(tool) }.buttonStyle(StudioPrimaryButtonStyle()) }
                else { Button("编辑") { onEditCLI(tool) } }
                Button(store.probingTools.contains(tool.id) ? "检测中…" : "检测版本") { store.probeTool(tool.id) }.disabled(missing || store.probingTools.contains(tool.id))
                if tool.authenticationStatusArguments != nil { Button("检测登录") { store.checkLogin(tool.id) }.disabled(missing || check.state == .checking) }
                if tool.authenticationLoginArguments != nil { Button("在终端登录") { onLogin(tool) }.disabled(missing) }
                Button(store.testPrompts[tool.id]?.running == true ? "测试中…" : "发送测试提示") { store.sendTestPrompt(tool.id) }
                    .disabled(missing || store.testPrompts[tool.id]?.running == true).help("会使用这个 CLI 账号的额度")
                Button(tool.isEnabled ? "停用" : "启用") { var updated = tool; updated.enabled = !tool.isEnabled; store.updateTool(updated) }
                Button("删除", role: .destructive) { store.pendingDeletion = DeletionTarget(.tool, tool.id) }
                Menu("更多") {
                    Button("复制为新 CLI") { if let id = store.duplicateTool(tool.id), let copy = store.tool(id) { onEditCLI(copy) } }
                    Button("导出定义…") { onExportCLI(tool) }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 10))
            if let usage = store.usageTotal({ $0.tool.id == tool.id }) { Text("累计用量：" + WorkbenchStore.describe(usage)).font(.system(size: 10)).foregroundStyle(.secondary) }
            if let test = store.testPrompts[tool.id] { testResult(test) }
            Divider()
        }.accessibilityElement(children: .contain).accessibilityIdentifier("tools.cli." + tool.id.uuidString)
    }

    @ViewBuilder private func testResult(_ test: TestPromptResult) -> some View {
        if test.running { HStack { ProgressView().controlSize(.small); Text("正在等待回复…").font(.system(size: 10)).foregroundStyle(.secondary) } }
        else {
            VStack(alignment: .leading, spacing: 5) {
                Label(test.succeeded ? "测试提示已回复" : "测试提示未成功", systemImage: test.succeeded ? "checkmark.circle" : "xmark.circle").font(.system(size: 10, weight: .medium)).foregroundStyle(test.succeeded ? accent : .orange)
                if !test.reply.isEmpty && (test.succeeded || !test.detail.contains(test.reply)) { Text(test.reply).font(.system(size: 11)).lineLimit(4).textSelection(.enabled) }
                if let session = test.sessionID { Text("会话 \(session)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
                if !test.succeeded { Text(test.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled) }
            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func remoteCard(_ tool: ToolConfig) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(tool.name, systemImage: "server.rack").font(.system(size: 13, weight: .medium))
            Text(tool.remote?.baseURL ?? "").font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            Text(store.remoteChecks[tool.id] ?? "服务待检测").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack {
                Button("配置") { onEditRemote(tool) }
                Button(store.probingTools.contains(tool.id) ? "检测中…" : "检测连接") { store.checkRemote(tool.id) }.disabled(store.probingTools.contains(tool.id))
                Button(tool.isEnabled ? "停用" : "启用") { var updated = tool; updated.enabled = !tool.isEnabled; store.updateTool(updated) }
                Button("删除", role: .destructive) { store.pendingDeletion = DeletionTarget(.tool, tool.id) }
                if tool.remote?.ssh != nil {
                    Button(store.tunnelTools.contains(tool.id) ? "断开 SSH 隧道" : "连接 SSH 隧道") { if store.tunnelTools.contains(tool.id) { store.disconnectTunnel(tool.id) } else { store.connectTunnel(tool.id) } }
                }
            }.font(.system(size: 10))
            Divider()
        }
    }

    private func serverCard(_ server: ComfyServer) -> some View {
        let health = store.serverHealth[server.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(server.name, systemImage: "server.rack").font(.system(size: 13, weight: .medium))
                Spacer()
                if let health { chip(health.error != nil ? "无法连接" : (health.supportsJobCancel ? "可用" : "缺少单任务取消"), color: health.usable ? accent : .orange) }
                else { chip(server.enabled ? "待检测" : "已停用", color: .secondary) }
            }
            Text(server.ssh.map { ssh in "SSH " + [ssh.user.map { $0 + "@" }, ssh.hostAlias, ssh.port.map { ":\($0)" }].compactMap { $0 }.joined() + " → 本机 \(ssh.localPort)" + (ssh.usesPassword == true ? " · 密码登录" : "") } ?? server.baseURL)
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            if server.ssh != nil, let state = store.tunnelStates[server.id] {
                switch state {
                case .connecting: Label("SSH 隧道连接中…", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(.secondary)
                case .open: Label("SSH 隧道已连接", systemImage: "lock.fill").font(.system(size: 10)).foregroundStyle(accent)
                case .failed(let reason): Label(reason, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3)
                }
            }
            if let command = store.serverCommands[server.id] {
                HStack(spacing: 6) {
                    if command.running || command.waiting { ProgressView().controlSize(.mini) }
                    Text((command.running || command.waiting ? "" : "上次操作：") + command.message).font(.system(size: 10)).foregroundStyle(command.succeeded == false ? .orange : .secondary)
                    if command.waiting { Button("不再等待") { store.cancelServerWait(server.id) }.buttonStyle(.linkPointer).font(.system(size: 10)) }
                }
                if !command.output.isEmpty && command.succeeded == false { Text(String(command.output.suffix(600))).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled) }
            }
            if let test = store.serverTests[server.id] {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(test.steps) { step in
                        Label(step.title + "：" + step.detail, systemImage: step.passed ? "checkmark.circle.fill" : "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(step.passed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                    if test.running { Label("正在测试…", systemImage: "hourglass").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.accessibilityIdentifier("tools.server.test." + server.id.uuidString)
            }
            Text([server.hourlyPrice.map { "约 \($0) \(server.currency ?? "") / 小时" } ?? "价格未知", "同时 \(server.jobLimit) 个任务", "下载上限 \(server.maximumDownloadBytes / 1_048_576) MB"].joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
            if let health {
                if let error = health.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(3) }
                else {
                    Text([health.version.map { "ComfyUI \($0)" }, health.gpu, health.vramTotal.map { String(format: "显存 %.1f / %.1f GB 可用", Double(health.vramFree ?? 0) / 1e9, Double($0) / 1e9) }, health.queueLength.map { "队列 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("检测于 " + health.checkedAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            HStack {
                Button("编辑") { onEditServer(server) }
                Button(store.serverTests[server.id]?.running == true ? "测试中…" : "测试连接") { store.testServer(server.id) }.disabled(store.serverTests[server.id]?.running == true)
                if server.ssh != nil { Button(store.tunnelTools.contains(server.id) ? "断开 SSH 隧道" : "连接 SSH 隧道") { if store.tunnelTools.contains(server.id) { store.disconnectTunnel(server.id) } else { store.connectTunnel(server.id) } } }
                if server.startCommand != nil { Button("启动") { store.runServerCommand(server.id, start: true) }.disabled(store.serverCommands[server.id]?.running == true || store.serverCommands[server.id]?.waiting == true) }
                if server.stopCommand != nil {
                    Button("停止") { if store.activeGenerations(on: server.id) > 0 { confirmStopServer = server } else { store.runServerCommand(server.id, start: false) } }
                        .disabled(store.serverCommands[server.id]?.running == true)
                }
                Button(server.enabled ? "停用" : "启用") { var updated = server; updated.enabled.toggle(); store.saveServer(updated, token: nil) }
                Button("删除", role: .destructive) { store.pendingDeletion = DeletionTarget(.server, server.id) }
            }.font(.system(size: 10))
            Divider()
        }.accessibilityElement(children: .contain).accessibilityIdentifier("tools.server." + server.id.uuidString)
    }

    private func templateCard(_ template: WorkflowTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(template.name, systemImage: "square.stack.3d.up").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(template.versionHash).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            if !template.description.isEmpty { Text(template.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
            Text([template.moduleIDs.compactMap { id in store.workspaces.first { $0.id == id }?.name }.joined(separator: "、").nonEmptyOr("未指定工作区"), "参数 " + (template.parameters.map(\.name).joined(separator: ", ").nonEmptyOr("无")), "输出 " + (template.outputs.map(\.kind.title).joined(separator: "、").nonEmptyOr("未声明"))].joined(separator: " · "))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            ForEach(store.enabledServers) { server in
                let missing = template.missingNodes(on: store.serverHealth[server.id])
                if !missing.isEmpty { Label("「\(server.name)」缺少节点：\(missing.joined(separator: "、"))", systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            HStack {
                Button("编辑") { onEditTemplate(template) }
                Button("删除", role: .destructive) { store.pendingDeletion = DeletionTarget(.template, template.id) }
                Button("手动运行") { onRunTemplate(template) }.disabled(store.enabledServers.isEmpty)
            }.font(.system(size: 10))
            Divider()
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.1), in: Capsule())
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}
