import AppKit
import SwiftUI
import SQLite3

// M5 Foundations verification. Uses an isolated database, a fake CLI written to this run's folder,
// and the real `claude` binary only for its version and login-status commands (no model call is made
// unless the standalone CLI reports that it is logged in, in which case the real test prompt is skipped too).
@main struct M5Verification {
    @MainActor static func wait(_ what: String, timeout: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(condition(), "Timed out waiting for: \(what)")
    }
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

    static let fixture = #"""
    #!/usr/bin/python3 -I
    import json, os, sys
    here = os.path.dirname(os.path.abspath(__file__))
    state = os.path.join(here, "state")
    os.makedirs(state, exist_ok=True)
    args = sys.argv[1:]
    if args[:1] == ["--version"]:
        print("fake-cli 1.0.0 (fixture)"); sys.exit(0)
    if args[:2] == ["auth", "status"]:
        if os.path.exists(os.path.join(state, "broken")):
            print("network unreachable", file=sys.stderr); sys.exit(2)
        ok = os.path.exists(os.path.join(state, "logged-in"))
        print(json.dumps({"loggedIn": ok, "authMethod": "fixture"}, indent=2)); sys.exit(0 if ok else 1)
    if args[:2] == ["auth", "login"]:
        open(os.path.join(state, "logged-in"), "w").close(); print("logged in"); sys.exit(0)
    count = len([f for f in os.listdir(state) if f.startswith("argv-")])
    with open(os.path.join(state, "argv-%03d.json" % count), "w") as f:
        json.dump({"argv": args, "cwd": os.getcwd(), "path": os.environ.get("PATH", "")}, f)
    def opt(name):
        return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None
    prompt = opt("-p") or ""
    session = opt("--session-id") or opt("--resume") or "fixture-session"
    emit = lambda value: print(json.dumps(value), flush=True)
    emit({"type": "system", "subtype": "init", "session_id": session})
    emit({"type": "assistant", "message": {"content": [{"type": "text", "text": "working"}]}, "session_id": session})
    if opt("--permission-mode") == "acceptEdits":
        target = os.path.join(os.getcwd(), "edited-by-fixture.txt")
        with open(target, "a") as f: f.write("edit\n")
        emit({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {"file_path": target}}]}, "session_id": session})
    result = {"type": "result", "subtype": "success", "is_error": False, "result": "echo: " + prompt, "session_id": session,
              "total_cost_usd": 0.0, "usage": {"input_tokens": len(prompt), "output_tokens": 3}}
    schema = opt("--json-schema")
    if schema:
        properties = json.loads(schema).get("properties", {})
        if "steps" in properties:
            worker = properties["steps"]["items"]["properties"]["employeeID"]["enum"][-1]
            result["structured_output"] = {"title": "Fixture plan", "goal": "verify planning with any CLI", "steps": [
                {"id": "a", "title": "Step A", "employeeID": worker, "input": "do A", "acceptance": "A done", "dependencies": []},
                {"id": "b", "title": "Step B", "employeeID": worker, "input": "do B", "acceptance": "B done", "dependencies": ["a"]}]}
        elif "decision" in properties:
            result["structured_output"] = {"decision": "pass", "notes": "fixture checked the archived text"}
    emit(result)
    """#

    static func definition(name: String, executable: String) -> ToolConfig {
        // Appendix A "Claude Code" example values, entered the way a user would in the Add CLI form.
        var tool = ToolConfig(name: name, executable: executable, arguments: ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--session-id", "{session_id}"])
        tool.resumeArguments = ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--resume", "{session_id}"]
        tool.outputFormat = .streamJSON; tool.includeInstructions = true
        tool.readOnlyArguments = ["--permission-mode", "plan"]; tool.editArguments = ["--permission-mode", "acceptEdits"]
        tool.modelArguments = ["--model", "{model}"]; tool.structuredOutputArguments = ["--json-schema", "{schema}"]
        tool.versionArguments = ["--version"]; tool.loginStatusArguments = ["auth", "status"]; tool.loggedOutText = #""loggedIn": false"#
        tool.loginArguments = ["auth", "login"]; tool.useLoginShellPath = true; tool.timeoutSeconds = 60
        return tool
    }
    static func argvRecords(_ state: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(atPath: state.path).filter { $0.hasPrefix("argv-") }.sorted().map {
            try JSONSerialization.jsonObject(with: Data(contentsOf: state.appendingPathComponent($0))) as! [String: Any]
        }
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("work/m5-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        var limitations: [String] = ["Snapshots are offscreen renders of owned SwiftUI views; clicks, keyboard, drag and drop, alerts and VoiceOver still need hands-on testing."]
        let environmentPATH = ProcessInfo.processInfo.environment["PATH"] ?? ""
        check(environmentPATH == "/usr/bin:/bin:/usr/sbin:/sbin", "Run through verify_m5.sh so the harness has Finder's minimal PATH")

        // ---- A34: nothing built in; empty state prompts to add a CLI ----
        let empty = WorkbenchStore(fileURL: root.appendingPathComponent("empty/workspace.sqlite"))
        check(empty.storageAvailable && !empty.hasCLI && empty.snapshot.tools.isEmpty && empty.snapshot.employees.isEmpty, "A fresh workbench ships no CLI, agent or demo data")
        checks.append("A34 fresh store has no built-in CLI, agent or demo task")

        // Real binary resolved by command name through the user's login shell, saved as an absolute path.
        let resolved = await empty.resolveExecutable("claude")
        if let path = resolved.executable {
            check(path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path), "Command name resolves to an absolute executable")
            check(resolved.searchPath?.isEmpty == false && resolved.searchPath != environmentPATH, "Login shell PATH replaces Finder's minimal PATH")
            checks.append("A34 `claude` resolved through the login shell to \(path)")
        } else { limitations.append("`claude` is not installed on this Mac; command-name resolution checked only with the fixture.") }

        // ---- Fake CLI with a space in its path ----
        let cliFolder = root.appendingPathComponent("fake cli")
        try FileManager.default.createDirectory(at: cliFolder, withIntermediateDirectories: true)
        let cliURL = cliFolder.appendingPathComponent("claude-like")
        try fixture.write(to: cliURL, atomically: true, encoding: .utf8)
        check(chmod(cliURL.path, 0o755) == 0, "chmod fixture")
        let state = cliFolder.appendingPathComponent("state")

        let databaseURL = root.appendingPathComponent("workspace.sqlite")
        let store = WorkbenchStore(fileURL: databaseURL)
        check(store.storageAvailable, "Isolated store opens")
        let fake = definition(name: "Fixture CLI", executable: cliURL.path)
        check(store.addTool(fake), "Add CLI definition")
        let projectFolder = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        try "original\n".write(to: projectFolder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        // ---- A35: version and login checks cost nothing and create no run ----
        store.probeTool(fake.id)
        try await wait("version check") { store.tool(fake.id)?.detectedVersion?.contains("fake-cli 1.0.0") == true }
        store.checkLogin(fake.id)
        try await wait("logged-out check") { store.loginChecks[fake.id]?.state == .loggedOut }
        FileManager.default.createFile(atPath: state.appendingPathComponent("broken").path, contents: nil)
        store.checkLogin(fake.id)
        try await wait("failed check") { store.loginChecks[fake.id]?.state == .failed }
        try FileManager.default.removeItem(at: state.appendingPathComponent("broken"))
        FileManager.default.createFile(atPath: state.appendingPathComponent("logged-in").path, contents: nil)
        store.checkLogin(fake.id)
        try await wait("logged-in check") { store.loginChecks[fake.id]?.state == .loggedIn }
        let promptsSoFar = try argvRecords(state)
        check(store.snapshot.runs.isEmpty && store.snapshot.tasks.isEmpty && promptsSoFar.isEmpty, "Checks create no run and send no prompt")
        checks.append("A35 fixture login check distinguishes logged out, failed and logged in; version and login checks created no run")

        if let path = resolved.executable {
            let real = definition(name: "Claude Code", executable: path)
            check(store.addTool(real), "Add real Claude Code definition")
            store.probeTool(real.id)
            try await wait("real version", timeout: 30) { store.tool(real.id)?.detectedVersion != nil || store.errorMessage != nil }
            check(store.errorMessage == nil, "Real claude --version: \(store.errorMessage ?? "")")
            store.checkLogin(real.id)
            try await wait("real login status", timeout: 30) { [.loggedIn, .loggedOut, .failed].contains(store.loginChecks[real.id]?.state ?? .unknown) }
            let state = store.loginChecks[real.id]!.state
            check(state != .failed, "Real `claude auth status` should be classified, got failed: \(store.loginChecks[real.id]!.detail.prefix(200))")
            checks.append("A35 real Claude Code \(store.tool(real.id)!.detectedVersion!.trimmingCharacters(in: .whitespacesAndNewlines)): login status classified as \(state.rawValue) under Finder's PATH")
            if state == .loggedOut {
                store.sendTestPrompt(real.id)
                try await wait("real test prompt", timeout: 120) { store.testPrompts[real.id]?.running == false }
                let result = store.testPrompts[real.id]!
                check(!result.succeeded, "A logged-out CLI must not report a successful test prompt")
                checks.append("Real Claude Code test prompt while logged out: reported as not successful (\(result.detail.split(separator: "\n").first ?? ""))")
                limitations.append("The standalone `claude` CLI is not logged in on this Mac, so real Claude Code runs (test prompt reply, A37 with the real model) are pending until the user signs in with `claude auth login`.")
            } else { limitations.append("Real Claude Code is logged in; real prompts were not sent by this harness to avoid using quota.") }
        }

        // ---- Test prompt through the fake CLI ----
        store.sendTestPrompt(fake.id)
        try await wait("fixture test prompt") { store.testPrompts[fake.id]?.running == false }
        let test = store.testPrompts[fake.id]!
        check(test.succeeded && test.reply.contains("ok") && test.sessionID != nil, "Fixture test prompt: \(test.detail)")
        check(store.snapshot.runs.isEmpty, "A test prompt creates no run")
        checks.append("Test prompt reply read from stream-json with a workbench-assigned session; no run created")

        // ---- Agents, projects and categories ----
        let client = ProjectCategory(name: "Client", color: "B97255", icon: "briefcase")
        let channel = ProjectCategory(name: "Channel", color: "8D7D9A", icon: "play.rectangle")
        check(store.addCategory(client) && store.addCategory(channel), "Add categories")
        check(!store.addCategory(ProjectCategory(name: "Client")), "Duplicate category names are rejected"); store.errorMessage = nil
        check(!store.addCategory(ProjectCategory(name: ProjectCategory.uncategorizedName)), "Uncategorized is reserved"); store.errorMessage = nil
        let experiments = ProjectCategory(name: "Experiments", color: "708A73", icon: "flask")
        check(store.addCategory(experiments), "Add third category")
        store.moveCategory(experiments.id, by: -2)
        check(store.snapshot.sortedCategories.map(\.name) == ["Experiments", "Client", "Channel"], "Reorder categories")
        var renamed = store.category(channel.id)!; renamed.name = "YouTube Channel"
        check(store.updateCategory(renamed), "Rename category")

        var app = WorkProject(name: "Parser fixes", directory: projectFolder.path, goal: "Fix the crash in the parser"); app.categoryID = client.id; app.moduleIDs = [WorkArea.defaults[2].id]
        check(store.addProject(app), "Add code project")
        var video = WorkProject(name: "Launch teaser", directory: try store.defaultProjectDirectory(for: UUID()), goal: "20-second teaser"); video.categoryID = channel.id; video.moduleIDs = [WorkArea.defaults[0].id, WorkArea.defaults[1].id]
        check(store.addProject(video), "Add media project with an app-created folder")
        var sketch = WorkProject(name: "Old sketch", directory: projectFolder.path); sketch.categoryID = experiments.id
        check(store.addProject(sketch), "Add project to delete category from")

        var coder = Employee(name: "Claude", role: "开发工程师", department: "开发工作区", instructions: "Keep changes small.", toolID: fake.id)
        coder.workspaceID = WorkArea.defaults[2].id; coder.maxAccess = .edit; coder.model = "haiku"
        var reader = Employee(name: "Reviewer", role: "只读顾问", department: "开发工作区", instructions: "Read only.", toolID: fake.id)
        reader.workspaceID = WorkArea.defaults[2].id; reader.maxAccess = .readOnly; reader.additionalWorkspaceIDs = [WorkArea.defaults[3].id]
        check(store.addEmployee(coder) && store.addEmployee(reader), "Add agents")
        check(store.employees(in: store.workspaces[3]).contains { $0.id == reader.id }, "An agent can appear in an extra module")

        // ---- A36 + A37 with the fixture: literal prompt, access levels, model, session, result.md ----
        let tricky = "fix it; $(touch /tmp/pwned) `id` \"quoted\"\nsecond line {output}"
        func runTask(_ title: String, employee: Employee, access: AccessLevel?) async throws -> WorkTask {
            var task = WorkTask(title: title, employeeID: employee.id, input: tricky, workingDirectory: projectFolder.path, acceptance: "checked")
            task.projectID = app.id; task.accessLevel = access
            check(store.addTask(task), "Add task \(title)")
            store.run(task.id)
            try await wait("run \(title)") { [.review, .failed].contains(store.snapshot.tasks.first { $0.id == task.id }?.status ?? .draft) }
            return store.snapshot.tasks.first { $0.id == task.id }!
        }
        let before = try Data(contentsOf: projectFolder.appendingPathComponent("README.md"))
        let readTask = try await runTask("Read-only turn", employee: coder, access: .readOnly)
        check(readTask.status == .review, "Read-only run succeeds: \(readTask.log.suffix(400))")
        let after = try Data(contentsOf: projectFolder.appendingPathComponent("README.md"))
        check(!FileManager.default.fileExists(atPath: projectFolder.appendingPathComponent("edited-by-fixture.txt").path) && after == before, "Read-only turn leaves project files unchanged")
        let editTask = try await runTask("Edit turn", employee: coder, access: .edit)
        check(editTask.status == .review && FileManager.default.fileExists(atPath: projectFolder.appendingPathComponent("edited-by-fixture.txt").path), "Edit turn may change files")
        let cappedTask = try await runTask("Capped turn", employee: reader, access: .edit)
        check(cappedTask.status == .review, "Capped run succeeds")
        let records = try argvRecords(state)
        check(records.count == 4, "Exactly three task runs plus one test prompt reached the CLI, got \(records.count)")
        let readArgv = records[1]["argv"] as! [String], editArgv = records[2]["argv"] as! [String], cappedArgv = records[3]["argv"] as! [String]
        let promptIndex = readArgv.firstIndex(of: "-p")! + 1
        check(readArgv[promptIndex] == "职责：\nKeep changes small.\n\n任务：\n" + tricky, "Prompt with quotes, ;, $(…), newline and {output} arrives as one literal argument")
        check(!FileManager.default.fileExists(atPath: "/tmp/pwned"), "No shell expansion happened")
        check(readArgv.suffix(4) == ["--permission-mode", "plan", "--model", "haiku"], "Read-only flags and model appended: \(readArgv)")
        check(editArgv.contains("acceptEdits") && !editArgv.contains("plan"), "Edit flags used for the edit turn")
        check(cappedArgv.contains("plan") && !cappedArgv.contains("acceptEdits"), "A task cannot exceed the agent's maximum access")
        check((records[1]["path"] as! String) != environmentPATH, "Runs use the login shell PATH, not Finder's")
        let readRun = store.runs(for: readTask.id).first!
        check(readRun.accessLevel == .readOnly && readRun.model == "haiku" && readRun.sessionID != nil && readArgv.contains(readRun.sessionID!), "Run records access, model and the assigned session")
        let resultURL = URL(fileURLWithPath: readRun.outputDirectory).appendingPathComponent("result.md")
        let savedReply = try String(contentsOf: resultURL, encoding: .utf8)
        check(savedReply.hasPrefix("echo: "), "Reply saved as result.md")
        check(store.artifacts(for: readRun.id).contains { $0.relativePath.hasSuffix("/result.md") }, "result.md archived as an artifact")
        checks.append("A36 prompt with quotes, ;, $(…), newline and {output} reached the CLI as one literal argv element; no shell expansion")
        checks.append("A37 (fixture) read-only run passed `--permission-mode plan` and left project files unchanged; edit run passed `acceptEdits` and changed a file; a read-only agent was capped at read-only")

        // A CLI without edit flags blocks edit runs instead of running with the wrong access.
        var readOnlyCLI = fake; readOnlyCLI.id = UUID(); readOnlyCLI.name = "Read-only CLI"; readOnlyCLI.editArguments = nil
        check(store.addTool(readOnlyCLI), "Add read-only CLI")
        var limited = coder; limited.id = UUID(); limited.name = "Limited"; limited.toolID = readOnlyCLI.id
        check(store.addEmployee(limited), "Add limited agent")
        var blocked = WorkTask(title: "Blocked edit", employeeID: limited.id, input: "x", workingDirectory: projectFolder.path, acceptance: "x")
        blocked.projectID = app.id; blocked.accessLevel = .edit
        check(store.addTask(blocked), "Add blocked task"); store.run(blocked.id)
        check(store.errorMessage?.contains("可编辑项目") == true && store.snapshot.tasks.first { $0.id == blocked.id }?.status == .draft, "Edit access without edit flags is refused before launch")
        store.errorMessage = nil
        var bypass = fake; bypass.editArguments = ["--permission-mode", "bypassPermissions"]
        check(bypass.bypassWarnings == ["bypassPermissions"], "Bypass flags are flagged")
        checks.append("TL-07 an access level with no flags is refused before launch; bypass flags are flagged")

        // ---- Planning and review with a non-Codex CLI (structured output via --json-schema) ----
        let planTaskID = try XCTUnwrapOrFail(store.generatePlan(goal: "Split the fix into two steps", managerID: coder.id, projectID: app.id), "Plan generation starts")
        try await wait("plan run") { [.review, .failed].contains(store.snapshot.tasks.first { $0.id == planTaskID }?.status ?? .draft) }
        let planRecord = try argvRecords(state).last!["argv"] as! [String]
        check(planRecord.contains("--json-schema") && planRecord.contains("plan"), "Planner ran read-only with the schema flag")
        let draft = try store.planDraft(for: planTaskID)
        check(draft.steps.count == 2 && draft.steps.allSatisfy { $0.employeeID == limited.id || store.employee($0.employeeID) != nil }, "Plan decoded from structured_output")
        checks.append("TM-02 planning works with a non-Codex CLI: schema passed via the user's structured-output flag and the plan decoded from result.json")

        // ---- A34: missing executable blocks the run with a fix-path prompt ----
        let moved = cliFolder.appendingPathComponent("claude-like.moved")
        try FileManager.default.moveItem(at: cliURL, to: moved)
        var later = WorkTask(title: "After move", employeeID: coder.id, input: "x", workingDirectory: projectFolder.path, acceptance: "x"); later.projectID = app.id
        check(store.addTask(later), "Add task after move"); store.run(later.id)
        check(store.missingCLIToolID == fake.id && store.snapshot.tasks.first { $0.id == later.id }?.status == .draft, "Missing CLI blocks the run and asks to fix the path")
        let runCount = store.snapshot.runs.count
        var fixed = store.tool(fake.id)!; fixed.executable = moved.path
        check(store.updateTool(fixed) && store.missingCLIToolID == nil, "Fixing the path clears the prompt")
        check(store.snapshot.runs.count == runCount, "Nothing ran while the CLI was missing")
        try FileManager.default.moveItem(at: moved, to: cliURL); fixed.executable = cliURL.path; check(store.updateTool(fixed), "Restore path")
        checks.append("A34 a CLI whose executable moved shows as missing; the run is blocked with a fix-path prompt and nothing launches")

        // ---- A56–A59: categories, archive, filters ----
        store.deleteCategory(experiments.id)
        check(store.project(sketch.id)?.categoryID == nil && store.snapshot.categories.count == 2, "Deleting a category moves its projects to Uncategorized")
        store.setProjectArchived(sketch.id, true)
        var archivedTask = WorkTask(title: "On archived", employeeID: coder.id, input: "x", workingDirectory: projectFolder.path, acceptance: "x"); archivedTask.projectID = sketch.id
        check(!store.addTask(archivedTask) && store.errorMessage == WorkbenchStore.archivedProjectMessage, "Archived projects are read-only"); store.errorMessage = nil
        var filter = ProjectFilter()
        check(Set(store.snapshot.projects(matching: filter).map(\.name)) == ["Parser fixes", "Launch teaser"], "Archived projects hidden by default")
        filter.category = .id(channel.id); check(store.snapshot.projects(matching: filter).map(\.name) == ["Launch teaser"], "Filter by category")
        filter = ProjectFilter(); filter.moduleID = WorkArea.defaults[1].id; check(store.snapshot.projects(matching: filter).map(\.name) == ["Launch teaser"], "Filter by module")
        filter = ProjectFilter(); filter.status = .archived; check(store.snapshot.projects(matching: filter).map(\.name) == ["Old sketch"], "Archived filter")
        let clientAssets = store.snapshot.artifacts.filter { artifact in store.project(artifact.projectID).map { store.snapshot.categoryID(of: $0) == client.id } ?? false }
        check(!clientAssets.isEmpty && clientAssets.allSatisfy { $0.projectID == app.id }, "Asset filter by category returns only that category's projects")
        check(store.moveProject(video.id, to: client.id) && store.project(video.id)?.categoryID == client.id && store.moveProject(video.id, to: channel.id), "Move project between categories")
        checks.append("A56 categories add/rename/reorder/delete; duplicates and the reserved name rejected; delete moves projects to Uncategorized")
        checks.append("A58 filters by category, module and status; archived projects hidden and read-only")
        checks.append("A59 assets filtered by category come only from that category's projects")

        // ---- Restart: everything persists ----
        let reopened = WorkbenchStore(fileURL: databaseURL)
        check(reopened.storageAvailable && reopened.snapshot == store.snapshot, "Restart restores the same snapshot")
        check(reopened.tool(fake.id)?.format == .streamJSON && reopened.employee(reader.id)?.additionalWorkspaceIDs == [WorkArea.defaults[3].id], "CLI definitions and agent fields persist")

        // ---- A57: v3 database migrates with a backup ----
        let legacyURL = root.appendingPathComponent("legacy/workspace.sqlite")
        var legacyTool = ToolConfig(name: "Codex", executable: "/usr/bin/true", arguments: []); legacyTool.adapter = .codex
        var legacyAgent = Employee(name: "Old Codex", role: "dev", department: "开发部", instructions: "", toolID: legacyTool.id); legacyAgent.workspaceID = WorkArea.defaults[2].id
        let legacyProject = WorkProject(name: "Legacy", directory: projectFolder.path)
        var v3 = WorkspaceSnapshot(); v3.tools = [legacyTool]; v3.employees = [legacyAgent]; v3.projects = [legacyProject]
        try WorkspacePersistence(fileURL: legacyURL).save(v3)
        var db: OpaquePointer?; check(sqlite3_open(legacyURL.path, &db) == SQLITE_OK && sqlite3_exec(db, "PRAGMA user_version=3", nil, nil, nil) == SQLITE_OK, "Mark as v3"); sqlite3_close(db)
        let migrated = WorkbenchStore(fileURL: legacyURL)
        check(migrated.storageAvailable && migrated.tool(legacyTool.id)?.adapterKind == .command && migrated.tool(legacyTool.id)?.format == .jsonLines, "Codex tool became an ordinary CLI definition")
        check(migrated.project(legacyProject.id)?.categoryID == nil && migrated.project(legacyProject.id)?.moduleIDs == [WorkArea.defaults[2].id], "Legacy project in Uncategorized with inferred module")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("legacy/workspace.pre-v06.sqlite").path), "pre-v06 backup written")
        checks.append("A57 v3 database migrated through the app store: backup written, Codex adapter retired, project in Uncategorized with an inferred module")

        // ---- Snapshots ----
        let suite = "MyWorkbench.M5.QA.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        if let appIcon = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-512-2x.png")) { _ = appIcon.setName("AppIcon") }
        for name in ["StudioHero", "StudioVideo", "StudioAudio", "StudioCode", "StudioDesign"] {
            if let image = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/\(name).imageset/image.png")) { _ = image.setName(name) }
        }
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history.json"))
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { terminals.endAll(); window.orderOut(nil) }
        var screenshots: [String] = []
        let shots = output.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        func render(_ name: String, _ view: some View, width: CGFloat = 1440, height: CGFloat = 900, dark: Bool = false) async throws {
            let runsBefore = store.snapshot.runs.count
            hosting.rootView = AnyView(view.defaultAppStorage(preferences).id(name))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); hosting.appearance = window.appearance
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 700_000_000)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { preconditionFailure("render \(name)") }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png"))
            check(store.snapshot.runs.count == runsBefore, "Rendering \(name) must not run anything")
            screenshots.append(name); print("Rendered \(name)")
        }
        let sheetBackground = Color(nsColor: .windowBackgroundColor)
        try await render("m5-home-no-cli", WorkbenchView(terminals: terminals, initialPage: .home, store: empty))
        try await render("m5-tools-empty", WorkbenchView(terminals: terminals, initialPage: .tools, store: empty))
        try await render("m5-agent-form-no-cli", ConfigurationSheet(kind: .employee, store: empty).background(sheetBackground).preferredColorScheme(.light), width: 600, height: 520)
        try await render("m5-cli-form-new", CLIConfigurationSheet(store: empty).background(sheetBackground).preferredColorScheme(.light), width: 680, height: 780)
        try await render("m5-cli-form-edit", CLIConfigurationSheet(store: store, toolToEdit: store.tool(fake.id)).background(sheetBackground).preferredColorScheme(.light), width: 680, height: 780)
        var missingShown = store.tool(readOnlyCLI.id)!; missingShown.executable = root.appendingPathComponent("gone/cli").path; check(store.updateTool(missingShown), "Show a missing CLI")
        try await render("m5-tools-list", WorkbenchView(terminals: terminals, initialPage: .tools, store: store), height: 1100)
        try await render("m5-agent-form", ConfigurationSheet(kind: .employee, store: store, employeeToEdit: store.employee(coder.id)).background(sheetBackground).preferredColorScheme(.light), width: 600, height: 760)
        try await render("m5-task-form", ConfigurationSheet(kind: .task, store: store, preferredEmployeeID: coder.id, initialTaskInput: "Fix the crash in the parser").background(sheetBackground).preferredColorScheme(.light), width: 600, height: 700)
        try await render("m5-projects", WorkbenchView(terminals: terminals, initialPage: .projects, store: store))
        try await render("m5-projects-compact", WorkbenchView(terminals: terminals, initialPage: .projects, store: store), width: 1100, height: 720)
        preferences.set("ink", forKey: "studioThemeV06")
        try await render("m5-projects-dark", WorkbenchView(terminals: terminals, initialPage: .projects, store: store), dark: true)
        preferences.set("paper", forKey: "studioThemeV06")
        try await render("m5-project-detail", WorkbenchView(terminals: terminals, initialPage: .projects, initialProjectID: app.id, store: store))
        try await render("m5-category-sheet", CategoryManagerSheet(store: store).background(sheetBackground).preferredColorScheme(.light), width: 560, height: 600)
        try await render("m5-project-sheet", ProjectConfigurationSheet(store: store, projectToEdit: store.project(video.id)).background(sheetBackground).preferredColorScheme(.light), width: 580, height: 680)
        try await render("m5-assets", WorkbenchView(terminals: terminals, initialPage: .assets, store: store))
        try await render("m5-home", WorkbenchView(terminals: terminals, initialPage: .home, store: store))

        let report: [String: Any] = ["passed": true, "workspace": root.path, "checks": checks, "screenshots": screenshots.map { shots.appendingPathComponent($0 + ".png").path }, "limitations": limitations]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("m5-verification.json"))
        for line in checks { print("✓ " + line) }
        for line in limitations { print("! " + line) }
        print("M5 verification passed: \(checks.count) checks, \(screenshots.count) snapshots")
        exit(0)
    }

    static func XCTUnwrapOrFail<T>(_ value: T?, _ message: String) throws -> T { guard let value else { preconditionFailure(message) }; return value }
}
