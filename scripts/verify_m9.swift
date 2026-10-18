import AppKit
import AVFoundation
import SwiftUI
import SwiftTerm

// M9 (PRD v0.6 P1 items) verification through the real store: CLI duplicate/export/import, per-CLI limits,
// version drift, usage totals, changed files, git worktrees, node checks, variants, export and home counts.
@main struct M9Verification {
    @MainActor static func wait(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        precondition(condition(), "Timed out waiting for: \(what)")
    }
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) { precondition(condition, message()) }
    static func calls(_ folder: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("state/calls.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    static func report(_ url: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: url + "/fixture/report")!)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func overlap(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        (a["start"] as! Double) < (b["end"] as! Double) && (b["start"] as! Double) < (a["end"] as! Double)
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("work/m9-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []

        func install(_ name: String, folder: String) throws -> URL {
            let dir = root.appendingPathComponent(folder); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(name.replacingOccurrences(of: ".py", with: ""))
            try FileManager.default.copyItem(at: project.appendingPathComponent("scripts/fixtures/" + name), to: target); check(chmod(target.path, 0o755) == 0, "chmod")
            return target
        }
        let claudeURL = try install("claude_like.py", folder: "claude cli"), codexURL = try install("codex_like.py", folder: "codex cli")
        let claudeFolder = claudeURL.deletingLastPathComponent(), codexFolder = codexURL.deletingLastPathComponent()
        var claudeCLI = ToolConfig(name: "Claude Code", executable: claudeURL.path, arguments: ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--session-id", "{session_id}"])
        claudeCLI.resumeArguments = ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--resume", "{session_id}"]
        claudeCLI.outputFormat = .streamJSON; claudeCLI.includeInstructions = true; claudeCLI.useLoginShellPath = true; claudeCLI.timeoutSeconds = 60
        claudeCLI.readOnlyArguments = ["--permission-mode", "plan"]; claudeCLI.editArguments = ["--permission-mode", "acceptEdits"]
        claudeCLI.structuredOutputArguments = ["--json-schema", "{schema}"]; claudeCLI.versionArguments = ["--version"]
        claudeCLI.loginStatusArguments = ["auth", "status"]; claudeCLI.loggedOutText = #""loggedIn": false"#
        var codexCLI = ToolConfig(name: "Codex", executable: codexURL.path, arguments: ["exec", "--json", "--skip-git-repo-check", "{flags}", "--", "{prompt}"])
        codexCLI.outputFormat = .jsonLines; codexCLI.readOnlyArguments = ["--sandbox", "read-only"]; codexCLI.editArguments = ["--sandbox", "workspace-write"]; codexCLI.timeoutSeconds = 60

        let store = WorkbenchStore(fileURL: root.appendingPathComponent("workspace.sqlite"))
        check(store.addTool(claudeCLI) && store.addTool(codexCLI), "Add CLIs")
        var claude = Employee(name: "Claude", role: "负责人", department: "", instructions: "", toolID: claudeCLI.id); claude.workspaceID = WorkArea.defaults[2].id; claude.maxAccess = .edit
        var codex = Employee(name: "Codex", role: "工程师", department: "", instructions: "", toolID: codexCLI.id); codex.workspaceID = WorkArea.defaults[2].id; codex.maxAccess = .edit
        check(store.addEmployee(claude) && store.addEmployee(codex), "Add agents")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = GitRepository(directory: repo.path)
        _ = await git.run(["init", "-q", "-b", "main"])
        try "# repo\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "initial")
        var app = WorkProject(name: "Parser fixes", directory: repo.path); app.moduleIDs = [WorkArea.defaults[2].id]
        check(store.addProject(app), "Add git project")
        store.concurrencyLimit = 2

        // ---- TL-10 duplicate, TL-09 export/import ----
        let copyID = store.duplicateTool(claudeCLI.id)!
        let copy = store.tool(copyID)!
        check(copy.id != claudeCLI.id && copy.name == "Claude Code 副本" && copy.arguments == claudeCLI.arguments && copy.detectedVersion == nil, "Duplicate keeps the definition with a new identity")
        let exported = try store.exportedDefinition(claudeCLI.id)
        check(!String(decoding: exported, as: UTF8.self).contains(claudeCLI.id.uuidString), "Export carries no ID")
        let importedID = store.importDefinition(exported)!
        check(importedID != claudeCLI.id && store.tool(importedID)?.executable == claudeCLI.executable && store.tool(importedID)?.readOnlyArguments == claudeCLI.readOnlyArguments, "Import makes a new CLI with the same templates")
        check(store.importDefinition(Data("not json".utf8)) == nil, "Bad files are refused"); store.errorMessage = nil
        checks.append("TL-09 a CLI definition exported without its ID or version and imported as a new CLI; TL-10 duplicating kept the templates under a new identity")

        // ---- TL-12 version drift ----
        let versionFile = claudeFolder.appendingPathComponent("state/version")
        try FileManager.default.createDirectory(at: versionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "claude-like 1.0".write(to: versionFile, atomically: true, encoding: .utf8)
        store.probeTool(claudeCLI.id)
        try await wait("first version") { store.tool(claudeCLI.id)?.detectedVersion == "claude-like 1.0" }
        check(store.tool(claudeCLI.id)?.versionChanged == nil, "First detection is not a change")
        try "claude-like 2.0".write(to: versionFile, atomically: true, encoding: .utf8)
        store.probeTool(claudeCLI.id)
        try await wait("version change flagged") { store.tool(claudeCLI.id)?.versionChanged == true }
        store.checkLogin(claudeCLI.id)
        try await wait("login clears the flag") { store.loginChecks[claudeCLI.id]?.state == .loggedIn && store.tool(claudeCLI.id)?.versionChanged == nil }
        checks.append("TL-12 a new CLI version was flagged \"needs re-check\" and a successful login check cleared it")

        // ---- TL-11 per-CLI limit ----
        var limited = store.tool(claudeCLI.id)!; limited.concurrencyLimit = 1; check(store.updateTool(limited), "Set limit")
        let c1 = store.sendMessage("STREAM first", projectID: app.id, conversationID: nil, agentIDs: [claude.id], mode: .single, access: .readOnly)!
        let c2 = store.sendMessage("STREAM second", projectID: app.id, conversationID: nil, agentIDs: [claude.id], mode: .single, access: .readOnly)!
        func turnState(_ conversation: UUID) -> TurnState? { store.snapshot.messages(in: conversation).last?.state }
        try await wait("both limited turns") { turnState(c1) == .replied && turnState(c2) == .replied }
        let streamCalls = calls(claudeFolder).filter { ($0["prompt"] as? String)?.contains("STREAM") == true }
        check(streamCalls.count == 2 && !overlap(streamCalls[0], streamCalls[1]), "With a limit of 1 the two turns never overlapped")
        limited.concurrencyLimit = nil; check(store.updateTool(limited), "Clear limit")
        checks.append("TL-11 with a per-CLI limit of 1, two turns in different conversations ran one after the other")

        // ---- TL-08 usage totals ----
        let conversationUsage = store.usageTotal { $0.conversationID == c1 }, projectUsage = store.usageTotal { $0.projectID == app.id }
        check(conversationUsage?.costUSD == 0.001 && (projectUsage?.costUSD ?? 0) >= 0.002, "Usage summed per conversation and project")
        checks.append("TL-08 usage was summed per conversation and per project")

        // ---- CH-11 changed files ----
        let editConversation = store.sendMessage("make an edit", projectID: app.id, conversationID: nil, agentIDs: [claude.id], mode: .single, access: .edit)!
        try await wait("edit turn") { turnState(editConversation) == .replied }
        let editTurn = store.snapshot.messages(in: editConversation).last!
        check(editTurn.changedFiles == ["edited-by-claude.txt"], "Changed files listed: \(String(describing: editTurn.changedFiles))")
        let editDiff = await store.diff(directory: repo.path, files: editTurn.changedFiles!)
        check(editDiff.contains("+edit"), "Diff shows the change")
        let readConversation = store.sendMessage("just read", projectID: app.id, conversationID: nil, agentIDs: [claude.id], mode: .single, access: .readOnly)!
        try await wait("read turn") { turnState(readConversation) == .replied }
        check(store.snapshot.messages(in: readConversation).last?.changedFiles == nil, "Read-only turns don't track changes")
        _ = await git.commitAll(message: "keep claude edit")
        checks.append("CH-11 an Edit turn in a git project listed the file it changed, with its diff; a Read-only turn listed nothing")

        // ---- TM-08 worktrees ----
        let team = store.sendMessage("WORKTREE-PAIR split the edits", projectID: app.id, conversationID: nil, agentIDs: [claude.id, codex.id], mode: .team, access: .edit)!
        try await wait("worktree plan") { store.snapshot.messages(in: team).contains { $0.planDraft != nil } }
        let planning = store.snapshot.messages(in: team).first { $0.planDraft != nil }!
        let planID = store.approveTeamPlan(messageID: planning.id, draft: planning.planDraft!, reviewerID: nil, maximumReworks: 0, useWorktrees: true)!
        func step(_ title: String) -> WorkTask { store.snapshot.tasks.first { $0.planID == planID && $0.title == title }! }
        try await wait("worktree steps done", timeout: 40) { step("Edit in worktree 1").status == .review && step("Edit in worktree 2").status == .review }
        let w1 = step("Edit in worktree 1"), w2 = step("Edit in worktree 2")
        check(w1.worktree?.state == .active && w2.worktree?.state == .active && w1.workingDirectory != repo.path && w1.workingDirectory != w2.workingDirectory, "Each Edit step got its own worktree")
        let worktreeCalls = calls(codexFolder).filter { ($0["prompt"] as? String)?.contains("LOCKTEST worktree") == true }
        check(worktreeCalls.count == 2 && overlap(worktreeCalls[0], worktreeCalls[1]), "Edit steps in separate worktrees ran at the same time")
        check(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("edited-by-codex.txt").path), "The project folder is untouched until a merge")
        let w1Diff = await store.worktreeDiff(w1.id)
        check(w1Diff.contains("+LOCKTEST worktree one"), "Worktree diff shows the step's change")
        store.accept(w1.id); store.accept(w2.id)
        await store.mergeWorktree(w1.id)
        let mergedText = (try? String(contentsOf: repo.appendingPathComponent("edited-by-codex.txt"), encoding: .utf8)) ?? ""
        check(step("Edit in worktree 1").worktree?.state == .merged && mergedText.contains("worktree one"), "First step merged into the project")
        await store.mergeWorktree(w2.id)
        check(step("Edit in worktree 2").worktree?.state == .conflict, "Second step conflicts and is left to the user")
        _ = await git.run(["merge", "--abort"])
        await store.discardWorktree(w2.id)
        check(step("Edit in worktree 2").worktree?.state == .discarded, "Conflicting step discarded")
        let branches = await git.run(["branch", "--list", "workbench/*"])
        check(branches.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Worktree branches cleaned up: \(branches.output)")
        checks.append("TM-08 two Edit steps ran at the same time in their own git worktrees; the project stayed untouched until the first merge; the second merge conflicted and was left to the user, then discarded")

        // ---- Media: MD-03 node check, MD-13 variants, MD-15 export ----
        let media = root.appendingPathComponent("media"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<32 { for y in 0..<32 { rep.setColor(NSColor(deviceRed: 0.5, green: CGFloat(x) / 32, blue: CGFloat(y) / 32, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: media.appendingPathComponent("image.png"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", project.appendingPathComponent("scripts/fixtures/comfy_media.py").path, media.path]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run(); defer { process.terminate() }
        var line = Data(); while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data("\n".utf8) { break }; line.append(byte) }
        let url = String(decoding: line, as: UTF8.self)
        let server = ComfyServer(name: "Fixture GPU", baseURL: url, hourlyPrice: 3.6, currency: "CNY", jobLimit: 1, timeoutSeconds: 60)
        check(store.saveServer(server, token: nil), "Server")
        store.checkServer(server.id)
        try await wait("health with nodes") { store.serverHealth[server.id]?.nodeClasses != nil }
        let good = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":5}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a cat"}},"9":{"class_type":"SaveImage","inputs":{}}}"#.utf8)
        let t2i = WorkflowTemplate(name: "Keyframe t2i", moduleIDs: [WorkArea.defaults[3].id], workflow: good, parameters: WorkflowTemplate.suggest(for: good).parameters, outputs: WorkflowTemplate.suggest(for: good).outputs, estimatedSeconds: 10)
        let bad = Data(#"{"1":{"class_type":"MissingNode","inputs":{"text":"x"}},"9":{"class_type":"SaveImage","inputs":{}}}"#.utf8)
        var odd = WorkflowTemplate(name: "Needs a custom node", workflow: bad, outputs: [TemplateOutput(nodeID: "9", kind: .image)])
        odd.parameters = [TemplateParameter(name: "text", nodeID: "1", inputName: "text", type: .text)]
        check(store.saveTemplate(t2i) && store.saveTemplate(odd), "Templates")
        check(odd.missingNodes(on: store.serverHealth[server.id]) == ["MissingNode"], "Missing node listed before running")
        var design = WorkProject(name: "Poster", directory: try store.defaultProjectDirectory(for: UUID())); design.moduleIDs = [WorkArea.defaults[3].id]; design.autoExport = true
        check(store.addProject(design), "Design project")
        let promptsBefore = (try await report(url)["prompts"] as! [[String: Any]]).count
        let refused = store.submitGeneration(templateID: odd.id, serverID: server.id, projectID: design.id, title: "Odd", values: ["text": "x"], files: [:])!
        try await wait("refused for missing node") { store.snapshot.tasks.first { $0.id == refused }?.status == .failed }
        let promptsAfter = (try await report(url)["prompts"] as! [[String: Any]]).count
        check(store.snapshot.tasks.first { $0.id == refused }!.log.contains("缺少节点") && promptsAfter == promptsBefore, "Refused before submission")
        checks.append("MD-03 the server's node list showed a template's missing node, and running it was refused before anything was submitted")

        let variants = store.submitGeneration(templateID: t2i.id, serverID: server.id, projectID: design.id, title: "Poster variants", values: ["prompt": "poster", "seed": "100"], files: [:], variants: 3)!
        try await wait("variants", timeout: 40) { store.snapshot.tasks.first { $0.id == variants }?.status == .review }
        let prompts = (try await report(url)["prompts"] as! [[String: Any]]).suffix(3)
        let seeds = prompts.map { (($0["workflow"] as! [String: [String: Any]])["3"]!["inputs"] as! [String: Any])["seed"] as! Double }
        check(seeds == [100, 101, 102], "Three jobs with seeds 100–102: \(seeds)")
        let variantRun = store.runs(for: variants).first!
        let variantFiles = store.artifacts(for: variantRun.id)
        check(variantFiles.map { URL(fileURLWithPath: $0.relativePath).lastPathComponent }.sorted() == ["v1-image.png", "v2-image.png", "v3-image.png"] && variantRun.remotePromptIDs?.count == 3, "Variant files and prompt IDs recorded")
        store.accept(variants)
        check(store.snapshot.tasks.first { $0.id == variants }?.status == .review && store.errorMessage?.contains("选用") == true, "Accepting needs a picked variant"); store.errorMessage = nil
        let second = variantFiles.first { $0.relativePath.hasSuffix("v2-image.png") }!
        store.selectVariant(second.id, selected: true)
        store.accept(variants)
        check(store.snapshot.tasks.first { $0.id == variants }?.status == .completed && store.acceptedFiles(of: variants).map(\.lastPathComponent) == ["v2-image.png"], "Only the picked variant goes on")
        let exportFolder = URL(fileURLWithPath: design.directory).appendingPathComponent("Workbench 导出/Poster variants")
        check(FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent("v2-image.png").path) && !FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent("v1-image.png").path), "Auto-export copied only the accepted file")
        check(store.exportOutputs(variants) != nil && FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent("v2-image-1.png").path), "Manual export never overwrites")
        checks.append("MD-13 three variants ran with seeds 100, 101, 102; acceptance needed a pick and only the picked file went on")
        checks.append("MD-15 accepting copied the picked file into the project's \"Workbench 导出\" folder; exporting again did not overwrite")

        // ---- PJ-08 home counts ----
        check(store.projectCount(moduleID: WorkArea.defaults[2].id) == 1 && store.projectCount(moduleID: WorkArea.defaults[3].id) == 1 && store.projectCount(moduleID: WorkArea.defaults[1].id) == 0, "Module project counts")
        checks.append("PJ-08 home module cards count the projects that use each module")

        // ---- Snapshots ----
        let suite = "MyWorkbench.M9.QA.\(UUID())"; let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        for name in ["StudioHero", "StudioVideo", "StudioAudio", "StudioCode", "StudioDesign"] {
            if let image = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/\(name).imageset/image.png")) { _ = image.setName(name) }
        }
        if let appIcon = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-512-2x.png")) { _ = appIcon.setName("AppIcon") }
        var drifted = store.tool(copyID)!; drifted.versionChanged = true; drifted.detectedVersion = "claude-like 3.0"; check(store.updateTool(drifted), "Show drift on the copy")
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { window.orderOut(nil) }
        let shots = output.appendingPathComponent("snapshots"); try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        var screenshots: [String] = []
        func render(_ name: String, _ view: some View, width: CGFloat = 1440, height: CGFloat = 900) async throws {
            hosting.rootView = AnyView(view.defaultAppStorage(preferences).id(name))
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 900_000_000); hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png")); screenshots.append(name); print("Rendered \(name)")
        }
        let accent = SwiftUI.Color(red: 88/255, green: 115/255, blue: 94/255), paper = SwiftUI.Color(hex: "F5F8FA")
        try await render("m9-home-counts", WorkbenchView(terminals: terminals, initialPage: .home, store: store))
        try await render("m9-tools", WorkbenchView(terminals: terminals, initialPage: .tools, store: store), height: 1300)
        try await render("m9-changed-files", ConversationView(store: store, conversationID: editConversation, accent: accent, onContinueInTerminal: { _ in }, onOpenTask: { _ in }, onReviewPlan: { _ in }).padding(20).background(paper), width: 900, height: 360)
        try await render("m9-worktree-task", TaskDetail(task: step("Edit in worktree 1"), store: store).padding(20).frame(width: 420).background(paper), width: 460, height: 1100)
        try await render("m9-variants-task", TaskDetail(task: store.snapshot.tasks.first { $0.id == variants }!, store: store).padding(20).frame(width: 420).background(paper), width: 460, height: 1300)

        let report: [String: Any] = ["passed": true, "workspace": root.path, "checks": checks, "screenshots": screenshots.map { shots.appendingPathComponent($0 + ".png").path },
                                     "limitations": ["Fixtures stand in for the real CLIs and ComfyUI; snapshots are offscreen renders without hands-on interaction."]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("m9-verification.json"))
        for line in checks { print("✓ " + line) }
        print("M9 verification passed: \(checks.count) checks, \(screenshots.count) snapshots")
        terminals.endAll(); process.terminate()
        exit(0)
    }
}
