import Darwin
import Foundation

/// An SSH tunnel's state, shown on the server card.
enum TunnelState: Equatable {
    case connecting, open, failed(String)
}

/// One stage of "test connection": SSH login, tunnel, ComfyUI, single-job cancel, installed nodes.
struct ServerTestStep: Equatable, Identifiable {
    var id: String { title }
    var title: String
    var passed: Bool
    var detail: String
}
struct ServerTest: Equatable {
    var running = true
    var steps: [ServerTestStep] = []
    var finishedAt: Date?
}

/// A server's start or stop command (MD-04) and, after Start, the wait until the server answers.
struct ServerCommandState: Equatable {
    var starting: Bool
    var running = true
    var waiting = false
    var succeeded: Bool?
    var output = ""
    var message = ""
}

/// Thread-safe, bounded output of a long-running ssh process.
final class TunnelOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func append(_ text: String) { lock.lock(); value = String((value + text).suffix(8000)); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

// MD-01, MD-02 and MD-04 for cloud GPU servers that are started when needed: SSH by key or Keychain password, tunnels that
// open on their own before a job and reopen while jobs run, a staged connection test, and start and stop commands.
extension WorkbenchStore {
    /// The ssh client. The server checks point this at a fixture.
    nonisolated(unsafe) static var sshExecutable = "/usr/bin/ssh"
    /// Seconds between health refreshes while jobs run. The server checks shorten it.
    nonisolated(unsafe) static var healthRefreshSeconds: Double = 30
    /// SSH passwords, one per server ID. Never written to the workspace or to disk.
    static let sshPasswordVault = CredentialVault(service: "com.ocean.myworkbench.ssh")

    private func sshConnection(_ id: UUID) -> SSHConnection? { tool(id)?.remote?.ssh ?? snapshot.server(id)?.ssh }

    /// For password login, ssh asks SSH_ASKPASS, a helper that prints the password from this ssh process's own environment.
    func sshEnvironment(_ id: UUID, _ ssh: SSHConnection) throws -> [String: String] {
        guard ssh.usesPassword == true else { return [:] }
        guard let password = try Self.sshPasswordVault.read(toolID: id), !password.isEmpty else { throw MediaError.serverUnavailable("请先在服务器设置里填写 SSH 密码。") }
        let helper = archive.root.deletingLastPathComponent().appendingPathComponent("ssh-askpass")
        let script = "#!/bin/sh\n# Workbench: answers ssh's password prompt from this ssh process's environment.\nprintf '%s\\n' \"$WORKBENCH_SSH_PASSWORD\"\n"
        if (try? String(contentsOf: helper, encoding: .utf8)) != script {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            guard chmod(helper.path, 0o700) == 0 else { throw MediaError.serverUnavailable("无法准备 SSH 密码助手。") }
        }
        return ["SSH_ASKPASS": helper.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0", "WORKBENCH_SSH_PASSWORD": password]
    }

    /// Whether something accepts connections on 127.0.0.1:port.
    nonisolated static func portOpen(_ port: Int) async -> Bool {
        await Task.detached {
            let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socket >= 0 else { return false }
            defer { close(socket) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_port = in_port_t(UInt16(port).bigEndian); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
        }.value
    }

    /// Opens the SSH tunnel of a server (or legacy ComfyUI tool) if needed and waits until it forwards, up to 25 seconds.
    /// Returns nil when the tunnel is open, otherwise what went wrong in terms the user can act on.
    @discardableResult func openTunnel(_ id: UUID) async -> String? {
        guard let ssh = sshConnection(id) else { return nil }
        if tunnelIDs[id] != nil {
            for _ in 0..<125 where tunnelStates[id] == .connecting { try? await Task.sleep(nanoseconds: 200_000_000) }
            if tunnelStates[id] == .open, tunnelIDs[id] != nil { return nil }
            if case .failed(let reason)? = tunnelStates[id] { return reason }
        }
        if await Self.portOpen(ssh.localPort) {
            let reason = "本机端口 \(ssh.localPort) 已被其他程序占用。请在服务器设置里换一个本机端口。"
            tunnelStates[id] = .failed(reason); return reason
        }
        let arguments: [String], environment: [String: String]
        do { arguments = try ssh.arguments(); environment = try sshEnvironment(id, ssh) }
        catch { let reason = (error as? LocalizedError)?.errorDescription ?? "SSH 设置无效。"; tunnelStates[id] = .failed(reason); return reason }
        let runID = UUID(), output = TunnelOutput()
        tunnelIDs[id] = runID; tunnelTools.insert(id); tunnelStates[id] = .connecting
        var config = ToolConfig(name: "SSH 隧道", executable: Self.sshExecutable, arguments: arguments); config.timeoutSeconds = 86400
        Task {
            let result = try? await tunnelRunner.run(id: runID, tool: config, input: "", directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: environment, onOutput: { output.append($0.text) })
            guard tunnelIDs[id] == runID else { return }
            tunnelIDs.removeValue(forKey: id); tunnelTools.remove(id)
            if result?.cancelled == true { tunnelStates.removeValue(forKey: id); return }
            tunnelStates[id] = .failed(SSHConnection.diagnose(output.text))
            // A tunnel that drops while jobs run on the server reopens on its own, three times at most.
            let attempt = (tunnelRetries[id] ?? 0) + 1
            if activeGenerations(on: id) > 0 && attempt <= 3 {
                tunnelRetries[id] = attempt
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if tunnelIDs[id] == nil && activeGenerations(on: id) > 0 { await openTunnel(id) }
            }
        }
        for _ in 0..<125 {
            if tunnelIDs[id] != runID { break }
            if await Self.portOpen(ssh.localPort) { tunnelStates[id] = .open; tunnelRetries[id] = 0; return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if tunnelIDs[id] == runID {
            tunnelRunner.cancel(id: runID)
            let reason = "SSH 隧道 25 秒内没有就绪。" + (output.text.isEmpty ? "" : SSHConnection.diagnose(output.text))
            tunnelStates[id] = .failed(reason); return reason
        }
        if case .failed(let reason)? = tunnelStates[id] { return reason }
        return SSHConnection.diagnose(output.text)
    }
    func connectTunnel(_ id: UUID) { Task { if let problem = await openTunnel(id) { errorMessage = problem } } }
    func disconnectTunnel(_ id: UUID) {
        tunnelRetries[id] = 99
        if let runID = tunnelIDs[id] { tunnelRunner.cancel(id: runID) }
    }
    func stopAllTunnels() { for id in tunnelIDs.values { tunnelRunner.cancel(id: id) } }

    /// Generation jobs running on a server now.
    func activeGenerations(on serverID: UUID) -> Int {
        activeRuns.values.filter { runID in snapshot.runs.first { $0.id == runID }?.generation?.serverID == serverID }.count
    }

    /// MD-02: while jobs run on a server, refresh its health (GPU, VRAM, queue) regularly, without re-reading its node list.
    func monitorHealth(_ serverID: UUID) {
        guard !healthMonitors.contains(serverID) else { return }
        healthMonitors.insert(serverID)
        Task {
            defer { healthMonitors.remove(serverID) }
            while activeGenerations(on: serverID) > 0 {
                try? await Task.sleep(nanoseconds: UInt64(Self.healthRefreshSeconds * 1_000_000_000))
                guard let server = snapshot.server(serverID), activeGenerations(on: serverID) > 0, let client = try? serverClient(server) else { break }
                if var health = try? await client.health(includeNodes: false) {
                    health.nodeClasses = serverHealth[serverID]?.nodeClasses
                    serverHealth[serverID] = health
                }
            }
        }
    }

    /// "Test connection": SSH login, tunnel, ComfyUI, single-job cancel and installed nodes, each with its own result.
    func testServer(_ id: UUID) {
        guard let server = snapshot.server(id), serverTests[id]?.running != true else { return }
        serverTests[id] = ServerTest()
        Task {
            var steps: [ServerTestStep] = []
            @MainActor func publish(_ step: ServerTestStep) { steps.append(step); serverTests[id]?.steps = steps }
            if let ssh = server.ssh {
                do {
                    var probe = ToolConfig(name: "SSH 登录检测", executable: Self.sshExecutable, arguments: try ssh.probeArguments()); probe.timeoutSeconds = 30
                    let output = TunnelOutput()
                    let result = try await runner.run(id: UUID(), tool: probe, input: "", directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: try sshEnvironment(id, ssh), onOutput: { output.append($0.text) })
                    let target = [ssh.user.map { $0 + "@" }, ssh.hostAlias, ssh.port.map { ":\($0)" }].compactMap { $0 }.joined()
                    publish(ServerTestStep(title: "SSH 登录", passed: result.status == .review, detail: result.status == .review ? "已登录 \(target)" : SSHConnection.diagnose(output.text)))
                } catch { publish(ServerTestStep(title: "SSH 登录", passed: false, detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)) }
                if steps.last?.passed == true {
                    let problem = await openTunnel(id)
                    publish(ServerTestStep(title: "SSH 隧道", passed: problem == nil, detail: problem ?? "本机 127.0.0.1:\(ssh.localPort) → 服务器 \(ssh.remoteHost ?? "127.0.0.1"):\(ssh.remotePort)"))
                }
            }
            if steps.allSatisfy(\.passed) {
                do {
                    let health = try await serverClient(server).health()
                    serverHealth[id] = health
                    publish(ServerTestStep(title: "ComfyUI", passed: true, detail: [health.version.map { "ComfyUI \($0)" }, health.gpu, health.queueLength.map { "队列 \($0)" }].compactMap { $0 }.joined(separator: " · ")))
                    publish(ServerTestStep(title: "按编号取消单个任务", passed: health.supportsJobCancel, detail: health.supportsJobCancel ? "支持，可以运行任务" : "不支持（缺少 /api/jobs），不能运行任务。请升级 ComfyUI。"))
                    publish(ServerTestStep(title: "已安装节点", passed: health.nodeClasses != nil, detail: health.nodeClasses.map { "\($0.count) 种节点" } ?? "读不到节点列表，提交前无法检查模板缺少的节点"))
                } catch {
                    serverHealth[id] = ServerHealth(error: error.localizedDescription)
                    publish(ServerTestStep(title: "ComfyUI", passed: false, detail: "ComfyUI 没有响应：\(error.localizedDescription)" + (server.ssh != nil ? "。SSH 已连通，ComfyUI 可能还没启动，或端口不对。" : "")))
                }
            }
            serverTests[id]?.running = false; serverTests[id]?.finishedAt = Date()
        }
    }

    /// MD-04: runs the server's Start or Stop command. After Start, waits (by default up to 5 minutes) until the server
    /// answers, opening its tunnel when it has one. After Stop, closes the tunnel.
    func runServerCommand(_ id: UUID, start: Bool) {
        guard let server = snapshot.server(id), let command = start ? server.startCommand : server.stopCommand, let name = command.first,
              serverCommands[id]?.running != true else { return }
        serverCommands[id] = ServerCommandState(starting: start, message: start ? "正在运行启动命令…" : "正在运行停止命令…")
        Task {
            let output = TunnelOutput()
            var succeeded = false
            do {
                let lookup = await resolveExecutable(name)
                guard let executable = lookup.executable else { throw MediaError.serverUnavailable("找不到命令「\(name)」。请填写绝对路径，或确认它在登录 Shell 的 PATH 中。") }
                var tool = ToolConfig(name: start ? "服务器启动命令" : "服务器停止命令", executable: executable, arguments: Array(command.dropFirst()))
                tool.timeoutSeconds = 600; tool.useLoginShellPath = true
                let result = try await runner.run(id: UUID(), tool: tool, input: "", directory: FileManager.default.homeDirectoryForCurrentUser.path, environment: await environmentAfterLookup(for: tool), onOutput: { output.append($0.text) })
                succeeded = result.status == .review
                serverCommands[id]?.message = succeeded ? (start ? "启动命令已完成。" : "停止命令已完成。") : "命令\(result.status.title)，退出码 \(result.exitCode)。"
            } catch { serverCommands[id]?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            serverCommands[id]?.output = output.text; serverCommands[id]?.running = false; serverCommands[id]?.succeeded = succeeded
            if !start {
                if succeeded { disconnectTunnel(id); serverHealth.removeValue(forKey: id) }
                return
            }
            guard succeeded else { return }
            serverCommands[id]?.waiting = true; serverCommands[id]?.message = "启动命令已完成，正在等待服务器就绪…"
            let deadline = Date().addingTimeInterval(min(3600, max(10, server.startupWaitSeconds ?? 300)))
            var ready = false, lastProblem = ""
            while Date() < deadline && serverCommands[id]?.waiting == true {
                if server.ssh != nil, let problem = await openTunnel(id) { lastProblem = problem }
                else if let client = try? serverClient(server), let health = try? await client.health() { serverHealth[id] = health; ready = true; break }
                else { lastProblem = "ComfyUI 还没有响应。" }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            serverCommands[id]?.waiting = false; serverCommands[id]?.succeeded = ready
            serverCommands[id]?.message = ready ? "服务器已就绪。" : "等待超时，服务器还没有就绪：\(lastProblem)"
        }
    }
    func cancelServerWait(_ id: UUID) { serverCommands[id]?.waiting = false }
}
