import AppKit
import SwiftUI
import SwiftTerm

// Screenshots for the homepage (site/) and the README. Seeds an isolated workspace with sample projects, agents, a team
// plan, a director's production plan and a GPU server, then renders the real views offscreen in the pixel style.
// Nothing runs and no model is called.
@main struct SiteScreens {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("work/site-screens")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "Workbench.SiteScreens.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))

        // CLIs: Codex is the one installed on the build machine; the card shows its real path and version.
        var codex = ToolConfig(name: "Codex", executable: "/usr/local/bin/codex", arguments: ["exec", "{flags}", "--json", "--skip-git-repo-check", "--", "{prompt}"])
        codex.resumeArguments = ["exec", "{flags}", "resume", "--json", "--skip-git-repo-check", "--", "{session_id}", "{prompt}"]
        codex.outputFormat = .jsonLines; codex.readOnlyArguments = ["--sandbox", "read-only"]; codex.editArguments = ["--sandbox", "workspace-write"]
        codex.detectedVersion = "codex-cli 0.164.0"; codex.useLoginShellPath = true
        precondition(store.addTool(codex))

        let areas = WorkArea.defaults
        func agent(_ name: String, _ role: String, area: Int, symbol: String, access: AccessLevel = .edit) -> Employee {
            var employee = Employee(name: name, role: role, department: areas[area].name, instructions: "Keep changes small and explain them.", toolID: codex.id, avatarSymbol: symbol)
            employee.workspaceID = areas[area].id; employee.maxAccess = access
            precondition(store.addEmployee(employee)); return employee
        }
        let iris = agent("Iris", "Director", area: 0, symbol: "film", access: .readOnly)
        let echo = agent("Echo", "Editor", area: 0, symbol: "scissors")
        let aria = agent("Aria", "Voice", area: 1, symbol: "waveform")
        let finn = agent("Finn", "Sound design", area: 1, symbol: "speaker.wave.2")
        let nova = agent("Nova", "Lead engineer", area: 2, symbol: "terminal")
        let kai = agent("Kai", "Engineer", area: 2, symbol: "hammer")
        let mia = agent("Mia", "Designer", area: 3, symbol: "paintpalette")
        let ash = agent("Ash", "Illustrator", area: 3, symbol: "pencil.and.outline")

        let client = ProjectCategory(name: "Client work", color: "29ADFF", icon: "briefcase"), personal = ProjectCategory(name: "Side projects", color: "FF9A1F", icon: "sparkles")
        precondition(store.addCategory(client) && store.addCategory(personal))
        func makeProject(_ name: String, goal: String, modules: [Int], category: ProjectCategory) throws -> WorkProject {
            // A neutral folder, so the screenshots show no path from the build machine.
            let folder = "/tmp/workbench-demo/" + name.lowercased().replacingOccurrences(of: " ", with: "-")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var made = WorkProject(name: name, directory: folder, goal: goal)
            made.moduleIDs = modules.map { areas[$0].id }; made.categoryID = category.id
            precondition(store.addProject(made)); return made
        }
        let app = try makeProject("Lighthouse app", goal: "Ship the CSV export and its tests", modules: [2], category: client)
        let teaser = try makeProject("Launch teaser", goal: "A 20-second teaser for the launch", modules: [0, 1], category: client)
        let poster = try makeProject("Poster series", goal: "Three posters in one visual style", modules: [3], category: personal)

        func task(_ title: String, _ employee: Employee, _ project: WorkProject, _ status: WorkStatus) {
            var made = WorkTask(title: title, employeeID: employee.id, input: title, workingDirectory: project.directory, acceptance: "Reviewed by me")
            made.projectID = project.id; made.status = status
            precondition(store.addTask(made))
        }
        task("Storyboard the teaser", iris, teaser, .review); task("Cut the 20-second edit", echo, teaser, .draft)
        task("Voiceover take 2", aria, teaser, .review); task("Ocean ambience bed", finn, teaser, .draft)
        task("CSV export", nova, app, .review); task("Tests for the export", kai, app, .draft)
        task("Poster key art", mia, poster, .review); task("Type layout", ash, poster, .draft)

        // Media: a rented GPU over SSH with three templates; health as after "Test connection".
        var gpu = ComfyServer(name: "Rented RTX 4090", baseURL: "http://127.0.0.1:8188", hourlyPrice: 2.4, currency: "CNY", jobLimit: 2, timeoutSeconds: 1800)
        gpu.ssh = SSHConnection(hostAlias: "gpu.example.com", localPort: 8189, remotePort: 8188, user: "root", port: 41022, hostKeyPolicy: .acceptNew)
        gpu.startCommand = ["gpu-cloud", "start", "instance-42"]; gpu.stopCommand = ["gpu-cloud", "stop", "instance-42"]
        precondition(store.saveServer(gpu, token: nil))
        var health = ServerHealth(version: "0.3.62", gpu: "cuda:0 NVIDIA GeForce RTX 4090", vramTotal: 25_757_220_864, vramFree: 23_100_000_000, queueLength: 0, supportsJobCancel: true)
        health.nodeClasses = ["KSampler", "CLIPTextEncode", "SaveImage", "WanImageToVideo", "VHS_VideoCombine", "SaveAudio"]
        store.serverHealth[gpu.id] = health
        store.serverTests[gpu.id] = ServerTest(running: false, steps: [
            ServerTestStep(title: "SSH 登录", passed: true, detail: "已登录 root@gpu.example.com:41022"),
            ServerTestStep(title: "SSH 隧道", passed: true, detail: "本机 127.0.0.1:8189 → 服务器 127.0.0.1:8188"),
            ServerTestStep(title: "ComfyUI", passed: true, detail: "ComfyUI 0.3.62 · cuda:0 NVIDIA GeForce RTX 4090 · 队列 0"),
            ServerTestStep(title: "按编号取消单个任务", passed: true, detail: "支持，可以运行任务"),
            ServerTestStep(title: "已安装节点", passed: true, detail: "1,284 种节点")], finishedAt: Date())
        func template(_ name: String, _ json: String, _ description: String, modules: [Int], seconds: Double) -> WorkflowTemplate {
            let data = Data(json.utf8), suggestion = WorkflowTemplate.suggest(for: data)
            let made = WorkflowTemplate(name: name, description: description, moduleIDs: modules.map { areas[$0].id }, workflow: data, parameters: suggestion.parameters, outputs: suggestion.outputs, estimatedSeconds: seconds)
            precondition(store.saveTemplate(made)); return made
        }
        let keyframe = template("Keyframe · SDXL", #"{"3":{"class_type":"KSampler","inputs":{"seed":5,"steps":28}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a lighthouse"}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"wb"}}}"#, "One still image from a text prompt.", modules: [0, 3], seconds: 40)
        let animate = template("Animate · Wan 2.2 i2v", #"{"1":{"class_type":"LoadImage","inputs":{"image":"in.png"}},"2":{"class_type":"WanImageToVideo","inputs":{"length":49,"width":832}},"3":{"class_type":"KSampler","inputs":{"seed":1}},"4":{"class_type":"VHS_VideoCombine","inputs":{"frame_rate":24}}}"#, "Turns a keyframe into a 2-second shot.", modules: [0], seconds: 150)

        // A team conversation: an earlier single-agent edit, then a team request with the lead's plan waiting for approval.
        func conversation(_ project: WorkProject, _ title: String, minutesAgo: Double) -> Conversation {
            let made = Conversation(projectID: project.id, title: title, createdAt: Date().addingTimeInterval(-minutesAgo * 60))
            store.snapshot.conversations.append(made); return made
        }
        func user(_ conversation: Conversation, _ text: String, agents: [Employee], mode: ChatMode, access: AccessLevel = .edit, minutesAgo: Double) -> ChatMessage {
            var message = ChatMessage(conversationID: conversation.id, role: .user, text: text, createdAt: Date().addingTimeInterval(-minutesAgo * 60))
            message.targetIDs = agents.map(\.id); message.mode = mode; message.access = access; message.leadID = mode == .single || mode == .parallel ? nil : agents.first?.id
            store.snapshot.messages.append(message); return message
        }
        func reply(_ to: ChatMessage, _ agent: Employee, _ text: String, kind: TurnKind = .reply, activities: [(String, String)] = [], changed: [String]? = nil, seconds: Double, tokens: (Int, Int), plan: PlanDraft? = nil) {
            var message = ChatMessage(conversationID: to.conversationID, role: .agent, text: text, createdAt: to.createdAt.addingTimeInterval(1))
            message.agentID = agent.id; message.replyToID = to.id; message.kind = kind; message.state = .replied; message.resumed = false
            message.startedAt = to.createdAt.addingTimeInterval(1); message.endedAt = to.createdAt.addingTimeInterval(1 + seconds)
            message.activities = activities.map { CLIActivity(kind: $0.0, summary: $0.1) }; message.changedFiles = changed
            message.usage = CLIUsage(inputTokens: tokens.0, outputTokens: tokens.1); message.planDraft = plan
            store.snapshot.messages.append(message)
        }
        let team = conversation(app, "CSV export with tests", minutesAgo: 20)
        let ask = user(team, "Totals in the CSV don't match the report screen. Find out why and fix it.", agents: [kai], mode: .single, minutesAgo: 18)
        reply(ask, kai, "Found it: the report rounds each row before summing, the CSV sums first. I made both sum first, then round, and added a test that compares them.",
              activities: [("command", "rg -n \"round(\" src/"), ("command", "pytest tests/test_totals.py"), ("file_change", "src/report.py, tests/test_totals.py")], changed: ["src/report.py", "tests/test_totals.py"], seconds: 24, tokens: (18_420, 312))
        let request = user(team, "Now add a CSV export for the monthly report: Nova leads, Kai helps. Split it and let me review the plan first.", agents: [nova, kai], mode: .team, minutesAgo: 4)
        var steps = [PlanStep(id: "a", title: "Export endpoint and file format", employeeID: nova.id, input: "Add /export/monthly.csv with the report's columns.", acceptance: "Downloads a CSV whose totals match the report", access: .edit),
                     PlanStep(id: "b", title: "Tests for edge cases", employeeID: kai.id, input: "Empty months, unicode names, very large totals.", acceptance: "All new tests pass", dependencies: ["a"], access: .edit),
                     PlanStep(id: "c", title: "Review and docs", employeeID: nova.id, input: "Check both parts and update docs/usage.md.", acceptance: "Docs show one example", dependencies: ["a", "b"], access: .readOnly)]
        steps[0].kind = .agent; steps[1].kind = .agent; steps[2].kind = .agent
        reply(request, nova, "I split this into 3 steps. Nothing runs until you approve.", kind: .planning, activities: [("command", "rg -n \"monthly\" src/"), ("command", "cat src/report.py")], seconds: 19, tokens: (22_310, 640),
              plan: PlanDraft(title: "Monthly CSV export", goal: "CSV export for the monthly report, with tests", steps: steps))

        // A director's production plan in the video project, waiting for approval with its estimate.
        let film = conversation(teaser, "Launch teaser", minutesAgo: 2)
        let brief = user(film, "Make a 3-shot teaser for the launch: a lighthouse at dusk, the beam sweeping over the sea, the app logo in the light.", agents: [iris], mode: .director, access: .readOnly, minutesAgo: 1)
        var shots: [PlanStep] = []
        for (index, prompt) in ["lighthouse on a cliff at dusk, cinematic, wide shot", "the beam sweeping over a dark sea, long exposure", "app logo glowing in the lighthouse light, close-up"].enumerated() {
            var still = PlanStep(id: "k\(index + 1)", title: "Keyframe for shot \(index + 1)", employeeID: iris.id, input: prompt, acceptance: "Matches the shot description")
            still.kind = .generate; still.templateID = keyframe.id; still.serverID = gpu.id; still.parameters = [NamedValue(name: keyframe.parameters.first { $0.type == .text }?.name ?? "prompt", value: prompt), NamedValue(name: "seed", value: "random")]
            var motion = PlanStep(id: "m\(index + 1)", title: "Animate shot \(index + 1)", employeeID: iris.id, input: "2-second move", acceptance: "Smooth, no flicker", dependencies: ["k\(index + 1)"])
            motion.kind = .generate; motion.templateID = animate.id; motion.serverID = gpu.id; motion.inputs = [NamedValue(name: animate.parameters.first { $0.type.isFile }?.name ?? "image", value: "step:k\(index + 1)")]
            shots += [still, motion]
        }
        var plan = PlanDraft(title: "Launch teaser", goal: "3 shots, about 20 seconds", steps: shots)
        plan.steps.append({ var cut = PlanStep(id: "edit", title: "Cut and sound", employeeID: echo.id, input: "Join the 3 shots, add the ocean ambience.", acceptance: "20 seconds, no jump cuts", dependencies: ["m1", "m2", "m3"], access: .edit); cut.kind = .agent; return cut }())
        reply(brief, iris, "制作计划共 7 步，其中 6 个生成任务。请审阅参数和预算后再启动。", kind: .production, activities: [("command", "ls templates")], seconds: 21, tokens: (9_870, 1_204), plan: plan)
        precondition(store.save())

        // Render.
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.appearance = NSAppearance(named: .darkAqua); window.orderBack(nil)
        func render(_ name: String, style: StudioStyle = .pixel, page: StudioPage = .home, projectID: UUID? = nil, width: CGFloat = 1440, height: CGFloat = 900) async throws {
            preferences.set(style.rawValue, forKey: "studioThemeV06")
            window.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua); hosting.appearance = window.appearance
            store.activeProjectID = projectID ?? app.id
            hosting.rootView = AnyView(WorkbenchView(terminals: terminals, initialPage: page, initialProjectID: projectID, store: store).defaultAppStorage(preferences).id(name))
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 1_400_000_000); hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png")); print("Rendered \(name)")
        }
        try await render("home-pixel")
        try await render("home-ink", style: .ink)
        try await render("home-paper", style: .paper)
        try await render("team-plan", page: .projects, projectID: app.id)
        try await render("director-plan", page: .projects, projectID: teaser.id)
        try await render("tools", page: .tools, height: 1100)
        try await render("projects", page: .projects)
        _ = poster
        window.orderOut(nil)
        print("Site screens rendered to \(output.path)")
        exit(0)
    }
}
