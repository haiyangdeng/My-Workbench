import AppKit
import SwiftUI
import SwiftTerm

// On-demand GPU server checks (MD-01, MD-02, MD-04, MD-18). Drives the real WorkbenchStore against a stand-in ssh
// (scripts/fixtures/ssh_like.py) that forwards to the local ComfyUI fixture, so key and password login, host keys,
// tunnels, start and stop commands, drops during a job and an offline server are all exercised without a cloud server.
// With --real-codex, the user's Codex CLI then directs one image through the SSH server (about two model turns).
@main struct ServerVerification {
    nonisolated(unsafe) static var checks: [String] = []
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) { precondition(condition, message()) }
    @MainActor static func wait(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(condition(), "Timed out waiting for: \(what)")
    }
    static func startFixture(media: URL) throws -> (Process, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", FileManager.default.currentDirectoryPath + "/scripts/fixtures/comfy_media.py", media.path]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        var line = Data()
        while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data("\n".utf8) { break }; line.append(byte) }
        return (process, String(decoding: line, as: UTF8.self))
    }
    static func report(_ url: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url + "/fixture/report")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func calls(_ state: URL) -> [[String: Any]] {
        ((try? String(contentsOf: state.appendingPathComponent("calls.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { close(socket) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let realCodex = CommandLine.arguments.contains("--real-codex")
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = project.appendingPathComponent("work/servers-qa/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Fixtures: ComfyUI on a random local port, and ssh in a folder with a space in its path.
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<64 { for y in 0..<48 { rep.setColor(NSColor(deviceRed: 0.2, green: CGFloat(x) / 64, blue: CGFloat(y) / 48, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: media.appendingPathComponent("image.png"))
        let (comfy, comfyURL) = try startFixture(media: media)
        defer { comfy.terminate() }
        let sshFolder = root.appendingPathComponent("ssh client")
        try FileManager.default.createDirectory(at: sshFolder.appendingPathComponent("state"), withIntermediateDirectories: true)
        let ssh = sshFolder.appendingPathComponent("ssh")
        try FileManager.default.copyItem(at: project.appendingPathComponent("scripts/fixtures/ssh_like.py"), to: ssh)
        check(chmod(ssh.path, 0o755) == 0, "chmod ssh fixture")
        let state = sshFolder.appendingPathComponent("state")
        func setState(_ name: String, _ value: String?) throws {
            let url = state.appendingPathComponent(name)
            if let value { try value.write(to: url, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: url) }
        }
        try setState("target", String(URL(string: comfyURL)!.port!))
        WorkbenchStore.sshExecutable = ssh.path
        WorkbenchStore.healthRefreshSeconds = 1

        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        let key = root.appendingPathComponent("keys/id_gpu")
        try FileManager.default.createDirectory(at: key.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "fixture key\n".write(to: key, atomically: true, encoding: .utf8)

        // ---- MD-01 SSH by key: user, port, key file, trust a new host; every stage of "test connection" ----
        let keyPort = freePort()
        var gpu = ComfyServer(name: "Rented 4090", baseURL: "http://127.0.0.1:8188", hourlyPrice: 2.4, currency: "CNY", jobLimit: 1, timeoutSeconds: 300)
        gpu.ssh = SSHConnection(hostAlias: "connect.gpu.example", localPort: keyPort, remotePort: 8188, user: "root", port: 23456, identityFile: key.path, hostKeyPolicy: .acceptNew)
        check(store.saveServer(gpu, token: nil), "Save key server: \(store.errorMessage ?? "")")
        store.testServer(gpu.id)
        try await wait("key server test") { store.serverTests[gpu.id]?.running == false }
        let keySteps = store.serverTests[gpu.id]!.steps
        check(keySteps.map(\.title) == ["SSH 登录", "SSH 隧道", "ComfyUI", "按编号取消单个任务", "已安装节点"] && keySteps.allSatisfy(\.passed), "Key server test: \(keySteps)")
        let tunnelCall = calls(state).last { $0["result"] as? String == "tunnel" }!
        let tunnelArgs = tunnelCall["argv"] as! [String]
        for expected in [["-p", "23456"], ["-l", "root"], ["-i", key.path], ["-L", "127.0.0.1:\(keyPort):127.0.0.1:8188"], ["-o", "StrictHostKeyChecking=accept-new"], ["-o", "BatchMode=yes"], ["-o", "ExitOnForwardFailure=yes"], ["-o", "IdentitiesOnly=yes"]] {
            check(tunnelArgs.indices.contains { tunnelArgs[$0] == expected[0] && $0 + 1 < tunnelArgs.count && tunnelArgs[$0 + 1] == expected[1] }, "Tunnel argv has \(expected): \(tunnelArgs)")
        }
        check(tunnelArgs.last == "connect.gpu.example" && store.tunnelStates[gpu.id] == .open, "Tunnel to the host is open")
        checks.append("MD-01 key login: user root, port 23456, key file and “trust a new host”; test connection passed SSH login, tunnel 127.0.0.1:\(keyPort) → 8188, ComfyUI, single-job cancel and installed nodes")

        // ---- Password login through the Keychain and SSH_ASKPASS; the password is in no argv and not in the workspace ----
        let password = "s3cret pass ;$(no)"
        try setState("password", password)
        var rented = gpu; rented.id = UUID(); rented.name = "Password GPU"
        rented.ssh = SSHConnection(hostAlias: "203.0.113.7", localPort: freePort(), remotePort: 8188, user: "root", port: 41022, usesPassword: true, hostKeyPolicy: .acceptNew)
        check(!store.saveServer(rented, token: nil), "Password login without a password is refused"); store.errorMessage = nil
        check(store.saveServer(rented, token: nil, sshPassword: password), "Save password server: \(store.errorMessage ?? "")")
        store.testServer(rented.id)
        try await wait("password server test") { store.serverTests[rented.id]?.running == false }
        check(store.serverTests[rented.id]!.steps.allSatisfy(\.passed), "Password server test: \(store.serverTests[rented.id]!.steps)")
        check(calls(state).filter { ($0["argv"] as! [String]).contains("203.0.113.7") }.allSatisfy { $0["password_ok"] as? Bool == true && !($0["argv"] as! [String]).joined().contains("s3cret") }, "ssh got the password only through askpass")
        let workspaceBytes = try Data(contentsOf: root.appendingPathComponent("workspace.sqlite")) + ((try? Data(contentsOf: root.appendingPathComponent("workspace.sqlite-wal"))) ?? Data())
        let storedPassword = try WorkbenchStore.sshPasswordVault.read(toolID: rented.id)
        check(workspaceBytes.range(of: Data("s3cret".utf8)) == nil && storedPassword == password, "Password kept in the Keychain only")
        store.disconnectTunnel(rented.id)
        try setState("password", nil)
        checks.append("Password login: kept in the Keychain, handed to ssh only through SSH_ASKPASS (BatchMode=no), never in argv or the workspace database; saving without a password is refused")

        // ---- Failures explained: authentication, changed host key, local port in use ----
        store.disconnectTunnel(gpu.id)
        try await wait("tunnel closed") { !store.tunnelTools.contains(gpu.id) }
        try setState("mode", "auth-fail")
        store.testServer(gpu.id)
        try await wait("auth failure test") { store.serverTests[gpu.id]?.running == false }
        let authStep = store.serverTests[gpu.id]!.steps
        check(authStep.count == 1 && !authStep[0].passed && authStep[0].detail.contains("认证失败"), "Auth failure: \(authStep)")
        try setState("mode", "hostkey-changed")
        let hostKeyProblem = await store.openTunnel(gpu.id) ?? ""
        check(hostKeyProblem.contains("主机密钥变了"), "Changed host key: \(hostKeyProblem)")
        try setState("mode", "ok")
        let blocker = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(blocker, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = in_port_t(UInt16(keyPort).bigEndian)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(blocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        check(bound == 0 && listen(blocker, 1) == 0, "Another program holds the local port")
        let portProblem = await store.openTunnel(gpu.id) ?? ""
        close(blocker)
        check(portProblem.contains("已被其他程序占用"), "Port in use: \(portProblem)")
        checks.append("Failures explained in plain terms: authentication failed, the host key changed, the local port is taken")

        // ---- MD-04 start and stop commands: the server answers only after Start; Stop closes the tunnel ----
        let commands = root.appendingPathComponent("provider cli")
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        let startScript = commands.appendingPathComponent("gpu-start"), stopScript = commands.appendingPathComponent("gpu-stop")
        // Like a provider API: returns at once, and the instance answers a few seconds later.
        try "#!/bin/sh\necho \"starting instance $1\"\nprintf \"booting:$(( $(date +%s) + 4 ))\" > '\(state.appendingPathComponent("mode").path)'\n".write(to: startScript, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho \"stopping instance $1\"\nprintf down > '\(state.appendingPathComponent("mode").path)'\n".write(to: stopScript, atomically: true, encoding: .utf8)
        _ = chmod(startScript.path, 0o755); _ = chmod(stopScript.path, 0o755)
        gpu.startCommand = [startScript.path, "instance-42"]; gpu.stopCommand = [stopScript.path, "instance-42"]; gpu.startupWaitSeconds = 60
        check(store.saveServer(gpu, token: nil), "Save start and stop commands")
        try setState("mode", "down")
        store.runServerCommand(gpu.id, start: true)
        try await wait("server ready after Start", timeout: 90) { store.serverCommands[gpu.id]?.running == false && store.serverCommands[gpu.id]?.waiting == false }
        let started = store.serverCommands[gpu.id]!
        check(started.succeeded == true && started.output.contains("starting instance instance-42") && store.tunnelStates[gpu.id] == .open && store.serverHealth[gpu.id]?.usable == true, "Start then ready: \(started)")
        store.runServerCommand(gpu.id, start: false)
        try await wait("Stop finished") { store.serverCommands[gpu.id]?.running == false }
        try await wait("tunnel closed after Stop") { !store.tunnelTools.contains(gpu.id) }
        check(store.serverCommands[gpu.id]?.output.contains("stopping instance instance-42") == true && store.serverHealth[gpu.id] == nil, "Stop ran and closed the tunnel")
        checks.append("MD-04 Start ran the provider command, waited until SSH and ComfyUI answered, and opened the tunnel; Stop ran its command and closed the tunnel")

        // ---- Offline: a job on a stopped server submits nothing and says to start the server ----
        let workflow = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":5,"steps":20}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a cat"}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"wb"}}}"#.utf8)
        let suggestion = WorkflowTemplate.suggest(for: workflow)
        let t2i = WorkflowTemplate(name: "Keyframe t2i", description: "Text to one still image", moduleIDs: [WorkArea.defaults[0].id, WorkArea.defaults[3].id], workflow: workflow, parameters: suggestion.parameters, outputs: suggestion.outputs, estimatedSeconds: 30)
        check(store.saveTemplate(t2i), "Save template")
        let textName = t2i.parameters.first { $0.type == .text }!.name
        var film = WorkProject(name: "Poster", directory: try store.defaultProjectDirectory(for: UUID()), goal: "One poster"); film.moduleIDs = [WorkArea.defaults[0].id]
        check(store.addProject(film), "Add project")
        let promptsBefore = (try await report(comfyURL)["prompts"] as! [[String: Any]]).count
        let offline = store.submitGeneration(templateID: t2i.id, serverID: gpu.id, projectID: film.id, title: "Offline try", values: [textName: "a lighthouse"], files: [:])!
        try await wait("offline job settles") { [.failed, .interrupted].contains(store.snapshot.tasks.first { $0.id == offline }?.status ?? .queued) }
        let offlineTask = store.snapshot.tasks.first { $0.id == offline }!
        let promptsAfterOffline = (try await report(comfyURL)["prompts"] as! [[String: Any]]).count
        check(offlineTask.status == .failed && offlineTask.log.contains("服务器可能还没启动") && promptsAfterOffline == promptsBefore, "Offline server: \(offlineTask.status) \(offlineTask.log.suffix(300))")
        checks.append("A job on a stopped server failed before submitting anything, with “start the server, then retry this step”")

        // ---- Auto-connect before a job; a dropped tunnel during the job reopens; health refreshes while it runs ----
        try setState("mode", "ok")
        try setState("drop", "4")
        let healthBefore = store.serverHealth[gpu.id]?.checkedAt ?? .distantPast
        let slow = store.submitGeneration(templateID: t2i.id, serverID: gpu.id, projectID: film.id, title: "Slow job", values: [textName: "SLOW lighthouse at dusk"], files: [:])!
        var refreshedDuringJob = false
        try await wait("slow job through a dropped tunnel", timeout: 120) {
            if store.activeRuns[slow] != nil, let checked = store.serverHealth[gpu.id]?.checkedAt, checked > healthBefore { refreshedDuringJob = true }
            return [.review, .failed, .interrupted, .timedOut].contains(store.snapshot.tasks.first { $0.id == slow }?.status ?? .queued)
        }
        let slowTask = store.snapshot.tasks.first { $0.id == slow }!
        let tunnelCalls = calls(state).filter { ($0["argv"] as! [String]).contains("connect.gpu.example") }
        check(slowTask.status == .review, "Job finished through the drop: \(slowTask.status) \(slowTask.log.suffix(600))")
        check(tunnelCalls.contains { $0["result"] as? String == "dropped" } && tunnelCalls.filter { $0["result"] as? String == "tunnel" }.count >= 3 && slowTask.log.contains("连接中断，正在重试"), "Tunnel dropped and reopened: \(tunnelCalls.map { $0["result"] ?? "" })")
        check(store.runs(for: slow).first?.remoteArtifacts?.contains { $0.localArtifactID != nil } == true, "Output downloaded through the tunnel")
        check(refreshedDuringJob, "Server health refreshed while the job ran")
        checks.append("The tunnel opened on its own before the job; it dropped mid-job and reopened, polling rode through and the image downloaded; server health refreshed while the job ran (MD-02)")

        // ---- MD-18 on a server: zero budget refused ----
        check((try? BudgetCap.validate(minutes: 0, cost: nil, hasGenerateSteps: true)) == nil, "Zero budget refused")

        // ---- Optional: the user's Codex directs one image through the SSH server ----
        if realCodex {
            let lookup = await store.resolveExecutable("codex")
            guard let codexPath = lookup.executable else { preconditionFailure("codex not installed") }
            var codex = ToolConfig(name: "Codex", executable: codexPath, arguments: ["exec", "{flags}", "--json", "--skip-git-repo-check", "--", "{prompt}"])
            codex.resumeArguments = ["exec", "{flags}", "resume", "--json", "--skip-git-repo-check", "--", "{session_id}", "{prompt}"]
            codex.outputFormat = .jsonLines; codex.includeInstructions = true; codex.useLoginShellPath = true
            codex.readOnlyArguments = ["--sandbox", "read-only"]; codex.editArguments = ["--sandbox", "workspace-write"]
            codex.structuredOutputArguments = ["--output-schema", "{schema_file}"]; codex.loginStatusArguments = ["login", "status"]; codex.loggedOutText = "Not logged in"; codex.timeoutSeconds = 300
            check(store.addTool(codex), "Add Codex")
            var director = Employee(name: "Iris", role: "导演", department: "影像工作区", instructions: "You direct image production. Keep plans minimal.", toolID: codex.id)
            director.workspaceID = WorkArea.defaults[0].id; director.maxAccess = .readOnly
            check(store.addEmployee(director), "Add director")
            let started = Date()
            guard let conversation = store.sendMessage("Make exactly one keyframe image with the Keyframe t2i template on Rented 4090: a lighthouse at dusk, cinematic. One generate step only.", projectID: film.id, conversationID: nil, agentIDs: [director.id], mode: .director, access: .readOnly) else { preconditionFailure("send: \(store.errorMessage ?? "")") }
            try await wait("Codex production plan", timeout: 400) { store.snapshot.messages(in: conversation).contains { $0.planDraft != nil } || store.snapshot.messages(in: conversation).contains { $0.state == .failed } }
            let planning = store.snapshot.messages(in: conversation).first { $0.planDraft != nil }
            check(planning != nil, "Codex returned a plan: \(store.snapshot.messages(in: conversation).compactMap(\.detail))")
            let draft = planning!.planDraft!
            check(draft.steps.contains { $0.stepKind == .generate && $0.serverID == gpu.id }, "The generate step uses the SSH server")
            store.disconnectTunnel(gpu.id)
            try await wait("tunnel closed before approval") { !store.tunnelTools.contains(gpu.id) }
            let planID = store.approveProductionPlan(messageID: planning!.id, draft: draft, budgetMinutes: 5, budgetCost: nil, directorReview: true, maximumReworks: 0)!
            let taskIDs = store.snapshot.plans.first { $0.id == planID }!.taskIDs
            try await wait("director review", timeout: 500) { !store.snapshot.reviews.filter { taskIDs.contains($0.sourceTaskID) }.isEmpty }
            let review = store.snapshot.reviews.first { taskIDs.contains($0.sourceTaskID) }!
            checks.append(String(format: "Real Codex %@ directed one image through the SSH server: plan, automatic tunnel, generation and a %@ review (\"%@\") in %.0f s", store.tool(codex.id)?.detectedVersion ?? "CLI", review.decision.decision.rawValue, String(review.decision.notes.prefix(90)), Date().timeIntervalSince(started)))
        }

        // ---- Screens: the server form with password login and start/stop commands, and the tools page after a test ----
        store.testServer(gpu.id)
        try await wait("test for the screenshot") { store.serverTests[gpu.id]?.running == false }
        let suite = "Workbench.ServerQA.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("ink", forKey: "studioThemeV06")
        let shots = project.appendingPathComponent("work/servers-qa/snapshots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil); window.appearance = NSAppearance(named: .darkAqua)
        func render(_ name: String, _ view: some View, width: CGFloat, height: CGFloat) async throws {
            hosting.rootView = AnyView(view.defaultAppStorage(preferences).id(name))
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 1_200_000_000); hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png")); print("Rendered \(name)")
        }
        try await render("servers-sheet-password", ServerSheet(store: store, serverToEdit: store.snapshot.server(rented.id)).background(Theme.paper).preferredColorScheme(.dark), width: 680, height: 820)
        try await render("servers-sheet-key", ServerSheet(store: store, serverToEdit: store.snapshot.server(gpu.id)).background(Theme.paper).preferredColorScheme(.dark), width: 680, height: 820)
        try await render("servers-tools", WorkbenchView(terminals: terminals, initialPage: .tools, store: store), width: 1440, height: 1300)
        window.orderOut(nil)
        checks.append("Rendered the server form (key and password) and the tools page with the tested server card")

        // ---- Deleting a server removes its SSH password from the Keychain ----
        let deleted = store.deleteObject(DeletionTarget(.server, rented.id))
        let leftover = try WorkbenchStore.sshPasswordVault.read(toolID: rented.id)
        check(deleted && leftover == nil, "Delete removes the SSH password")
        store.stopAllTunnels()
        checks.append("Deleting a server removed its SSH password from the Keychain")

        let output = project.appendingPathComponent("work/servers-qa/servers-verification.json")
        let result: [String: Any] = ["passed": true, "workspace": root.path, "checks": checks, "realCodex": realCodex,
                                     "limitations": ["ssh is a stand-in that forwards to a local ComfyUI fixture; a real cloud GPU, its provider CLI and real network drops still need a live run."]]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        for line in checks { print("✓ " + line) }
        print("Server verification passed: \(checks.count) checks")
        exit(0)
    }
}
