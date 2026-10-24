import AppKit
import SwiftUI
import SwiftTerm

/// Regression checks for the six findings in the 2026-10-24 review and theme-dependent icons.
/// Uses isolated SQLite databases, local shell fixtures and offscreen views. No model or GPU requests.
@main struct ReviewFixesVerification {
    @MainActor static func pixels(_ image: NSImage) -> [UInt8] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: 64 * 64 * 4))
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(condition(), "Regression fixture timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/review-fixes-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        func fixture(_ name: String) -> (WorkbenchStore, Employee, WorkProject) {
            let store = WorkbenchStore(fileURL: root.appendingPathComponent(name + "/workspace.sqlite"))
            var tool = ToolConfig(name: "local shell", executable: "/bin/sh", arguments: ["-c", "{prompt}"])
            tool.versionArguments = []
            precondition(store.addTool(tool))
            let employee = Employee(name: "Local", role: "Fixture", department: "", instructions: "", toolID: tool.id)
            precondition(store.addEmployee(employee))
            let project = WorkProject(name: name, directory: root.path)
            precondition(store.addProject(project))
            return (store, employee, project)
        }
        do {
            let (store, employee, project) = fixture("archived-task")
            let other = WorkProject(name: "other", directory: root.path); precondition(store.addProject(other))
            var blocker = WorkTask(title: "hold slot", employeeID: employee.id, input: "sleep 0.5", workingDirectory: root.path, acceptance: "done")
            blocker.projectID = other.id; precondition(store.addTask(blocker)); store.run(blocker.id)
            var queued = WorkTask(title: "must wait", employeeID: employee.id, input: "printf yes > resumed-marker", workingDirectory: root.path, acceptance: "done")
            queued.projectID = project.id; precondition(store.addTask(queued)); store.run(queued.id)
            store.setProjectArchived(project.id, true)
            try await wait { store.activeRuns.isEmpty }
            precondition(store.snapshot.tasks.first { $0.id == queued.id }?.status == .queued)
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("resumed-marker").path))
            store.setProjectArchived(project.id, false)
            try await wait { store.snapshot.tasks.first { $0.id == queued.id }?.status == .review }
            precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("resumed-marker").path))
            checks.append("Archived queued tasks stayed frozen; unarchiving resumed them")
        }
        do {
            let (store, _, project) = fixture("archived-generation")
            let server = ComfyServer(name: "never connect", baseURL: "http://127.0.0.1:1")
            let template = WorkflowTemplate(name: "image", workflow: Data(#"{"9":{"class_type":"SaveImage","inputs":{}}}"#.utf8))
            precondition(store.saveServer(server, token: nil) && store.saveTemplate(template))
            var task = WorkTask(title: "queued image", employeeID: WorkbenchStore.manualOwnerID, input: "image", workingDirectory: root.path, acceptance: "image")
            task.projectID = project.id; task.status = .queued
            task.generation = GenerationSpec(templateID: template.id, serverID: server.id, versionHash: template.versionHash)
            precondition(store.addTask(task)); store.setProjectArchived(project.id, true)
            precondition(!store.canStartGeneration(task)); store.startGeneration(task.id); store.schedulePending()
            precondition(store.activeRuns.isEmpty && store.snapshot.runs.isEmpty)
            precondition(store.snapshot.tasks.first?.status == .queued)
            checks.append("Archived queued generation was refused at both scheduling and launch without contacting its server")
        }
        do {
            let (store, owner, project) = fixture("command-limit")
            store.concurrencyLimit = 2
            var tool = ToolConfig(name: "limited command", executable: "/bin/sh", arguments: ["-c", "{prompt}"])
            tool.commandStep = true; tool.concurrencyLimit = 1; tool.versionArguments = []
            precondition(store.addTool(tool))
            let agent = Employee(name: "same CLI", role: "local", department: "", instructions: "", toolID: tool.id)
            precondition(store.addEmployee(agent))
            var ids: [UUID] = []
            for i in 1...2 {
                var task = WorkTask(title: "command \(i)", employeeID: owner.id, input: "local", workingDirectory: root.path, acceptance: "done")
                task.projectID = project.id; task.command = CommandSpec(toolID: tool.id, arguments: ["-c", "sleep 0.5"])
                precondition(store.addTask(task)); store.run(task.id); ids.append(task.id)
            }
            precondition(store.activeRunCount(toolID: tool.id) == 1)
            let conversationID = store.sendMessage("sleep 0.3; printf done", projectID: project.id, conversationID: nil, agentIDs: [agent.id], mode: .single, access: .readOnly)!
            precondition(store.activeTurns.isEmpty)
            try await wait {
                precondition(store.activeRunCount(toolID: tool.id) <= 1, "Command and chat share their actual CLI limit")
                return ids.allSatisfy { id in store.snapshot.tasks.contains { $0.id == id && $0.status == .review } } && store.snapshot.messages(in: conversationID).last?.state == .replied
            }
            checks.append("Commands used their executable CLI's concurrency limit, including competition with chat turns")
        }
        do {
            let (store, agent, project) = fixture("archived-chat")
            var cli = store.tool(agent.toolID)!; cli.concurrencyLimit = 1; precondition(store.updateTool(cli))
            let first = store.sendMessage("sleep 0.4; printf first", projectID: project.id, conversationID: nil, agentIDs: [agent.id], mode: .single, access: .readOnly)!
            let second = store.sendMessage("printf second", projectID: project.id, conversationID: nil, agentIDs: [agent.id], mode: .single, access: .readOnly)!
            store.setProjectArchived(project.id, true)
            try await wait { store.activeTurns.isEmpty }
            precondition(store.snapshot.messages(in: first).last?.state == .replied)
            precondition(store.snapshot.messages(in: second).last?.state == .queued)
            store.setProjectArchived(project.id, false)
            try await wait { store.snapshot.messages(in: second).last?.state == .replied }
            checks.append("Archived chat queues froze and resumed; an already-started turn could finish")
        }
        do {
            let (store, agent, project) = fixture("director-scope")
            let allowedServer = ComfyServer(name: "allowed", baseURL: "http://127.0.0.1:1"), excludedServer = ComfyServer(name: "excluded", baseURL: "http://127.0.0.1:2")
            let workflow = Data(#"{"9":{"class_type":"SaveImage","inputs":{}}}"#.utf8)
            let allowedTemplate = WorkflowTemplate(name: "allowed", workflow: workflow), excludedTemplate = WorkflowTemplate(name: "excluded", workflow: workflow)
            precondition(store.saveServer(allowedServer, token: nil) && store.saveServer(excludedServer, token: nil) && store.saveTemplate(allowedTemplate) && store.saveTemplate(excludedTemplate))
            let conversation = Conversation(projectID: project.id, title: "scope")
            var user = ChatMessage(conversationID: conversation.id, role: .user, text: "image")
            user.mode = .director; user.directorTemplateIDs = [allowedTemplate.id]; user.directorServerIDs = [allowedServer.id]
            precondition(store.change { $0.conversations.append(conversation); $0.messages.append(user) })
            for (template, server) in [(excludedTemplate, allowedServer), (allowedTemplate, excludedServer), (allowedTemplate, allowedServer)] {
                var turn = ChatMessage(conversationID: conversation.id, role: .agent, text: "")
                turn.agentID = agent.id; turn.replyToID = user.id; turn.kind = .production; turn.state = .replied
                precondition(store.change { $0.messages.append(turn) })
                let data = try JSONSerialization.data(withJSONObject: ["title":"scoped", "goal":"image", "steps":[["id":"one", "title":"image", "kind":"generate", "employeeID":"", "input":"image", "acceptance":"visible", "dependencies":[], "access":"readOnly", "templateID":template.id.uuidString, "serverID":server.id.uuidString, "parameters":[], "inputs":[], "toolID":"", "arguments":[]]]])
                let draft = try JSONDecoder().decode(ProductionPlanDTO.self, from: data).toDraft(directorID: agent.id)
                var summary = CLIOutputSummary(); summary.structuredJSON = data
                store.handleProductionResult(store.snapshot.messages.firstIndex { $0.id == turn.id }!, summary: summary)
                let allowed = template.id == allowedTemplate.id && server.id == allowedServer.id
                precondition((store.message(turn.id)?.planDraft != nil) == allowed)
                if !allowed {
                    let count = store.snapshot.tasks.count
                    let approved = store.approveProductionPlan(messageID: turn.id, draft: draft, budgetMinutes: 1, budgetCost: nil, directorReview: false, maximumReworks: 0)
                    precondition(approved == nil && store.snapshot.tasks.count == count && store.activeRuns.isEmpty)
                    precondition(store.errorMessage?.contains("请改选本次需求范围内的") == true, "Approval errors address the user, not the director")
                }
            }
            precondition(store.directorScope(for: user).templates.map(\.id) == [allowedTemplate.id] && store.directorScope(for: user).servers.map(\.id) == [allowedServer.id])
            checks.append("Excluded templates and servers were refused on response and approval; the approval pickers only offer the recorded scope")
        }
        do {
            let (store, _, _) = fixture("saved-git-evidence")
            let repository = root.appendingPathComponent("git"); try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let git = GitRepository(directory: repository.path)
            _ = await git.run(["init", "-q"])
            let file = repository.appendingPathComponent("中文.md")
            try "original\n".write(to: file, atomically: true, encoding: .utf8); _ = await git.commitAll(message: "initial")
            try "original\nuser\n".write(to: file, atomically: true, encoding: .utf8)
            let baseline = await store.changeBaseline(repository.path)!
            try "original\nuser\nagent\n".write(to: file, atomically: true, encoding: .utf8); _ = await git.commitAll(message: "agent")
            let changed = await store.changedFiles(since: baseline, directory: repository.path)
            precondition(changed == ["中文.md"])
            let evidenceFolder = root.appendingPathComponent("evidence"); try FileManager.default.createDirectory(at: evidenceFolder, withIntermediateDirectories: true)
            let log = try RunLog(url: root.appendingPathComponent("evidence.log"))
            await store.writeChangeEvidence(files: changed, directory: repository.path, outputDirectory: evidenceFolder.path, log: log, baseline: baseline); try log.close()
            let text = try String(contentsOf: evidenceFolder.appendingPathComponent(RunArchive.changeEvidencePath), encoding: .utf8)
            precondition(text.contains("+agent") && !text.contains("+user"))
            checks.append("Unicode committed edits produced changes.diff against the actual starting contents")
        }
        do {
            let (store, agent, _) = fixture("theme-icons")
            let suite = "Workbench.ReviewFixes.\(UUID())", preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminals.json"))
            let hosting = NSHostingView(rootView: AnyView(EmptyView()))
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting; window.orderBack(nil)
            var task = WorkTask(title: "Theme preview", employeeID: agent.id, input: "", workingDirectory: root.path, acceptance: "look")
            task.status = .draft; precondition(store.addTask(task))
            for style in [StudioStyle.pixel, .ink, .paper, .pixel] {
                preferences.set(style.rawValue, forKey: Theme.preferenceKey)
                hosting.rootView = AnyView(WorkbenchView(terminals: terminals, store: store).defaultAppStorage(preferences).id(UUID()))
                window.appearance = NSAppearance(named: style.isDark ? .darkAqua : .aqua); hosting.appearance = window.appearance
                hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
                try await Task.sleep(nanoseconds: 500_000_000); hosting.layoutSubtreeIfNeeded()
                guard let expected = style.icon, let actual = NSApp.applicationIconImage else { preconditionFailure("Missing app icon") }
                // AppKit rasterizes the Dock image and drops the source's other TIFF representations.
                let differences = zip(pixels(expected), pixels(actual)).map { abs(Int($0) - Int($1)) }
                let meanError = Double(differences.reduce(0, +)) / Double(differences.count)
                precondition(meanError < 1, "Dock follows the persisted style: \(style.rawValue), mean channel error \(meanError)")
                let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!; hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("home-\(style.rawValue).png"))
            }
            precondition(StudioStyle.pixel.iconName != StudioStyle.ink.iconName && StudioStyle.ink.iconName == StudioStyle.paper.iconName)
            precondition(store.snapshot.runs.isEmpty && store.activeTurns.isEmpty)
            window.orderOut(nil); terminals.endAll()
            checks.append("Pixel, Ink, Paper, and Pixel again rendered with matching sidebar assets and Dock icons from saved preferences")
        }
        let report: [String: Any] = ["passed":true, "checks":checks, "workspace":root.path, "modelCalls":0, "gpuRequests":0]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: output.appendingPathComponent("verification.json")); print(String(decoding:data,as:UTF8.self))
        exit(0)
    }
}
