import AppKit
import SwiftUI
import SwiftTerm

// Real Codex acceptance pass. Drives the real WorkbenchStore with the user's installed, logged-in Codex CLI, defined by
// hand from PRD Appendix A, against an isolated database, a scratch git repository and the local ComfyUI fixture server.
// Every scenario is recorded as passed or failed with evidence and the run continues, so one problem does not hide others.
// This calls the real model: roughly 20 short Codex turns.
@main struct RealCodexVerification {
    nonisolated(unsafe) static var results: [[String: Any]] = []
    static func record(_ id: String, _ title: String, _ passed: Bool, _ detail: String) {
        results.append(["id": id, "title": title, "passed": passed, "detail": detail])
        print("\(passed ? "PASS" : "FAIL") \(id) \(title)\n     \(detail.replacingOccurrences(of: "\n", with: "\n     "))")
    }
    @MainActor static func wait(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        return condition()
    }
    static func git(_ directory: URL, _ arguments: [String]) -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try? process.run(); process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    /// Content fingerprint of every file outside .git, to prove a Read-only turn changed nothing.
    static func fingerprint(_ directory: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathComponents.contains(".git") { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result[url.path] = try? Data(contentsOf: url) }
        }
        return result
    }
    static func excerpt(_ text: String?, _ limit: Int = 220) -> String {
        let value = (text ?? "").replacingOccurrences(of: "\n", with: " ⏎ ")
        return value.count > limit ? String(value.prefix(limit)) + "…" : value
    }
    static func startFixture(media: URL) throws -> (Process, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", FileManager.default.currentDirectoryPath + "/scripts/fixtures/comfy_media.py", media.path]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        var line = Data()
        while true { let byte = pipe.fileHandleForReading.readData(ofLength: 1); if byte.isEmpty || byte == Data("\n".utf8) { break }; line.append(byte) }
        return (process, String(decoding: line, as: UTF8.self))
    }
    static func fixtureReport(_ url: String) async -> [String: Any] {
        guard let (data, _) = try? await URLSession.shared.data(from: URL(string: url + "/fixture/report")!) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    @MainActor static func terminalText(_ session: TerminalSession) -> String {
        let emulator = session.terminal.getTerminal()
        return (0..<emulator.rows).compactMap { row in
            emulator.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { emulator.getCharacter(for: $0) })
        }.joined(separator: "\n")
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        let started = Date()
        // --director-only skips the chat and team scenarios and runs just the director against the fixture server.
        let directorOnly = CommandLine.arguments.contains("--director-only")
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/real-codex-qa")
        let root = output.appendingPathComponent(ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-"))
        let repo = root.appendingPathComponent("lighthouse repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "# Lighthouse\n\nProject codename: AMBER-FINCH\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "line 1\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "def beam(hours):\n    \"\"\"Return how many times the light sweeps in the given hours.\"\"\"\n    return hours * 60 * 4\n".write(to: repo.appendingPathComponent("src/app.py"), atomically: true, encoding: .utf8)
        _ = git(repo, ["init", "-q"]); _ = git(repo, ["config", "user.email", "qa@example.invalid"]); _ = git(repo, ["config", "user.name", "Workbench QA"])
        _ = git(repo, ["add", "-A"]); _ = git(repo, ["commit", "-q", "-m", "Initial"])
        let database = root.appendingPathComponent("workspace.sqlite")
        var store = WorkbenchStore(fileURL: database)
        print("QA workspace: \(root.path)")

        // ---- A34 / TL-01: the executable typed as a name resolves through the login shell to an absolute path ----
        let lookup = await store.resolveExecutable("codex")
        guard let codexPath = lookup.executable else {
            record("A34", "Codex typed as a command name resolves to an absolute path", false, "Login-shell lookup found no `codex`; nothing else can run.")
            try finish(root: root, started: started); return
        }
        record("A34", "Codex typed as a command name resolves to an absolute path", codexPath.hasPrefix("/"), "Resolved to \(codexPath); the harness runs with Finder's minimal PATH, so `codex` (a Node script) only runs through the login-shell PATH.")

        // Appendix A values, entered by hand.
        var codex = ToolConfig(name: "Codex", executable: codexPath, arguments: ["exec", "{flags}", "--json", "--skip-git-repo-check", "--", "{prompt}"])
        codex.resumeArguments = ["exec", "{flags}", "resume", "--json", "--skip-git-repo-check", "--", "{session_id}", "{prompt}"]
        codex.interactiveResumeArguments = ["--sandbox", "read-only", "resume", "{session_id}"]
        codex.outputFormat = .jsonLines; codex.includeInstructions = true; codex.useLoginShellPath = true
        codex.readOnlyArguments = ["--sandbox", "read-only"]; codex.editArguments = ["--sandbox", "workspace-write"]
        codex.structuredOutputArguments = ["--output-schema", "{schema_file}"]; codex.modelArguments = ["--model", "{model}"]
        codex.versionArguments = ["--version"]; codex.loginStatusArguments = ["login", "status"]; codex.loginArguments = ["login"]
        codex.loggedOutText = "Not logged in"; codex.timeoutSeconds = 300
        guard store.addTool(codex) else { record("TL-01", "Add the Codex CLI definition", false, store.errorMessage ?? ""); try finish(root: root, started: started); return }

        // ---- A35: version and login checks, no run ----
        store.probeTool(codex.id)
        let versioned = await wait(60) { store.tool(codex.id)?.detectedVersion != nil || store.errorMessage != nil }
        record("TL-05", "Version check", versioned && store.tool(codex.id)?.detectedVersion?.contains("codex") == true, "Detected: \(excerpt(store.tool(codex.id)?.detectedVersion)) \(store.errorMessage ?? "")")
        store.errorMessage = nil
        store.checkLogin(codex.id)
        _ = await wait(60) { [.loggedIn, .loggedOut, .failed].contains(store.loginChecks[codex.id]?.state ?? .unknown) }
        let login = store.loginChecks[codex.id]
        record("A35", "Login check classifies the logged-in Codex", login?.state == .loggedIn && store.snapshot.runs.isEmpty, "State: \(login?.state.rawValue ?? "none"); detail: \(excerpt(login?.detail)); runs created: \(store.snapshot.runs.count)")

        // ---- TL-06 test prompt ----
        store.sendTestPrompt(codex.id)
        _ = await wait(240) { store.testPrompts[codex.id]?.running == false }
        let test = store.testPrompts[codex.id]
        record("TL-06", "Test prompt from the CLI form", test?.succeeded == true, "Succeeded: \(test?.succeeded == true); reply: \(excerpt(test?.reply)); detail: \(excerpt(test?.detail, 400)); session: \(test?.sessionID ?? "none")")
        if test?.detail.localizedCaseInsensitiveContains("usage limit") == true {
            // Every later scenario needs the model; stop instead of recording failures that say nothing about the app.
            record("QUOTA", "Codex account has quota for the run", false, "Codex reported its usage limit; the pass stopped before the model scenarios. Rerun once the limit resets.")
            try finish(root: root, started: started); return
        }

        // ---- Agents and project ----
        let code = WorkArea.defaults[2].id
        func agent(_ name: String, _ role: String, _ instructions: String, access: AccessLevel) -> Employee {
            var employee = Employee(name: name, role: role, department: "开发工作区", instructions: instructions, toolID: codex.id)
            employee.workspaceID = code; employee.maxAccess = access
            return employee
        }
        let nova = agent("Nova", "工程负责人", "Be brief. Follow the user's instructions exactly.", access: .edit)
        let kai = agent("Kai", "工程师", "Be brief. Make only the changes you are asked for.", access: .edit)
        let ada = agent("Ada", "审核", "Review strictly against the acceptance criteria. Be brief.", access: .readOnly)
        guard store.addEmployee(nova) && store.addEmployee(kai) && store.addEmployee(ada) else { record("AG-01", "Add Codex agents", false, store.errorMessage ?? ""); try finish(root: root, started: started); return }
        var project = WorkProject(name: "Lighthouse", directory: repo.path, goal: "Small Python utility for a lighthouse"); project.moduleIDs = [code]
        guard store.addProject(project) else { record("PJ-01", "Add project", false, store.errorMessage ?? ""); try finish(root: root, started: started); return }
        store.concurrencyLimit = 2

        func turns(_ conversation: UUID) -> [ChatMessage] { store.snapshot.messages(in: conversation).filter { $0.role == .agent } }
        func settled(_ id: UUID) -> Bool { store.message(id)?.state?.isActive == false }
        func send(_ text: String, to agents: [Employee], conversation: UUID? = nil, mode: ChatMode = .single, access: AccessLevel = .readOnly) -> UUID? {
            let id = store.sendMessage(text, projectID: project.id, conversationID: conversation, agentIDs: agents.map(\.id), mode: mode, access: access)
            if id == nil { print("     send refused: \(store.errorMessage ?? "")"); store.errorMessage = nil }
            return id
        }
        func run(of turn: ChatMessage?) -> TaskRun? { turn?.runID.flatMap { id in store.snapshot.runs.first { $0.id == id } } }
        func describe(_ turn: ChatMessage?) -> String {
            guard let turn else { return "no turn" }
            return "state \(turn.state?.rawValue ?? "?"); resumed \(turn.resumed.map(String.init) ?? "nil"); reply: \(excerpt(turn.text)); detail: \(excerpt(turn.detail, 300))"
        }

        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history.json"))
        if !directorOnly {
        // ---- A38 / A37 read-only first turn ----
        let before = fingerprint(repo)
        guard let first = send("Read README.md in the current folder and reply with only the project codename. Also remember the number 4721 for later. Do not create or change any files.", to: [nova]) else { try finish(root: root, started: started); return }
        let firstTurnID = turns(first)[0].id
        var sawLiveText = false
        _ = await wait(300) {
            if store.message(firstTurnID)?.state == .running, !(store.liveTurns[firstTurnID]?.text.isEmpty ?? true) || !(store.liveTurns[firstTurnID]?.activities.isEmpty ?? true) { sawLiveText = true }
            return settled(firstTurnID)
        }
        let firstTurn = store.message(firstTurnID)
        let firstRun = run(of: firstTurn)
        let firstLog = firstRun.flatMap { try? String(contentsOf: URL(fileURLWithPath: $0.logPath), encoding: .utf8) } ?? ""
        record("CH-01", "Single-agent Read-only reply in a project", firstTurn?.state == .replied && firstTurn?.text.contains("AMBER-FINCH") == true, describe(firstTurn))
        record("A38", "Reply or activity shows before the CLI exits; raw log archived", sawLiveText && firstLog.contains("thread.started"), "Live text or activity seen while running: \(sawLiveText); archived log has JSONL events: \(firstLog.contains("thread.started")); activities: \(firstTurn?.activities?.map(\.summary).prefix(3).joined(separator: " | ") ?? "none")")
        record("M9-usage", "Token usage recorded on the turn", (firstTurn?.usage?.inputTokens ?? 0) > 0, "input \(firstTurn?.usage?.inputTokens ?? 0), output \(firstTurn?.usage?.outputTokens ?? 0)")
        let sessionID = firstTurn.flatMap { store.session(for: $0)?.nativeID }

        // ---- A39 resume ----
        _ = send("What number did I ask you to remember? Reply with just the number.", to: [nova], conversation: first)
        let secondID = turns(first).last!.id
        _ = await wait(300) { settled(secondID) }
        let second = store.message(secondID)
        let secondArgs = run(of: second)?.arguments ?? []
        record("A39", "Follow-up resumes the same native session", second?.text.contains("4721") == true && second?.resumed == true && secondArgs.contains("resume") && sessionID.map { secondArgs.contains($0) } == true,
               "Session \(sessionID ?? "none"); argv uses resume with it: \(secondArgs.contains("resume") && sessionID.map { secondArgs.contains($0) } == true); \(describe(second))")

        // ---- A37 Read-only blocks writes even when asked ----
        _ = send("Create a file named blocked.txt containing the word x. If you cannot write files, say so in one sentence.", to: [nova], conversation: first)
        let blockedID = turns(first).last!.id
        _ = await wait(300) { settled(blockedID) }
        let after = fingerprint(repo)
        record("A37-read", "Read-only turns leave the project's files unchanged, even when asked to write", before == after && !FileManager.default.fileExists(atPath: repo.appendingPathComponent("blocked.txt").path),
               "Files unchanged across three Read-only turns: \(before == after); blocked.txt exists: \(FileManager.default.fileExists(atPath: repo.appendingPathComponent("blocked.txt").path)); \(describe(store.message(blockedID)))")

        // ---- A37 Edit + CH-11 changed files (including a file the user had already modified) ----
        try "line 1\nuser line\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = send("Create a file hello.txt containing exactly: hello from codex\nThen append a new last line 'edited by codex' to notes.txt. Reply DONE when finished.", to: [nova], conversation: first, access: .edit)
        let editID = turns(first).last!.id
        _ = await wait(300) { settled(editID) }
        let edit = store.message(editID)
        let hello = (try? String(contentsOf: repo.appendingPathComponent("hello.txt"), encoding: .utf8)) ?? ""
        let notes = (try? String(contentsOf: repo.appendingPathComponent("notes.txt"), encoding: .utf8)) ?? ""
        let editArgs = run(of: edit)?.arguments ?? []
        record("A37-edit", "An Edit turn can change files", hello.contains("hello from codex") && notes.contains("edited by codex") && editArgs.contains("workspace-write"),
               "hello.txt: \(excerpt(hello)); notes.txt ends with codex line: \(notes.contains("edited by codex")); sandbox flag: \(editArgs.contains("workspace-write") ? "workspace-write" : "missing"); \(describe(edit))")
        let changed = edit?.changedFiles ?? []
        record("CH-11a", "Changed-file list shows a new file", changed.contains("hello.txt"), "Reported: \(changed)")
        record("CH-11b", "Changed-file list shows a file the user had already modified", changed.contains("notes.txt"), "Reported: \(changed). notes.txt had an uncommitted user edit before the turn (known review issue P2-2).")

        // ---- A42 queue, A40 interrupted on restart, A41 stop ----
        guard let busy = send("Run the shell command `sleep 40` and then reply with the word FINISHED.", to: [kai]) else { try finish(root: root, started: started); return }
        let slowID = turns(busy)[0].id
        _ = await wait(120) { store.message(slowID)?.state == .running && (store.liveTurns[slowID]?.activities.isEmpty == false || store.liveTurns[slowID]?.text.isEmpty == false) }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        _ = send("Reply with the word AFTERSTOP.", to: [kai], conversation: busy)
        let queuedID = turns(busy).last!.id
        let wasQueued = store.message(queuedID)?.state == .queued
        record("A42", "A message to a busy agent is queued", wasQueued, "Second message state while the first runs: \(store.message(queuedID)?.state?.rawValue ?? "?")")
        let reopened = WorkbenchStore(fileURL: database)
        record("A40a", "After a restart, a turn that was running shows as Interrupted", reopened.message(slowID)?.state == .interrupted && reopened.activeTurns.isEmpty, "State in a store reopened mid-turn: \(reopened.message(slowID)?.state?.rawValue ?? "?")")
        let stopAt = Date()
        store.stopTurn(slowID)
        _ = await wait(15) { settled(slowID) }
        let stopSeconds = Date().timeIntervalSince(stopAt)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let leftover = Process(); leftover.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); leftover.arguments = ["-f", "sleep 40"]
        let leftoverPipe = Pipe(); leftover.standardOutput = leftoverPipe; try? leftover.run(); leftover.waitUntilExit()
        let survivors = String(decoding: leftoverPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        record("A41", "Stop ends the turn and its process group quickly", store.message(slowID)?.state == .stopped && stopSeconds < 6 && survivors.isEmpty,
               String(format: "Stopped in %.1f s; state %@; `sleep 40` still running: %@", stopSeconds, store.message(slowID)?.state?.rawValue ?? "?", survivors.isEmpty ? "no" : "yes (pids \(survivors))"))
        _ = await wait(300) { settled(queuedID) }
        let afterStop = store.message(queuedID)
        record("A42b", "The queued message runs after the stop and resumes the session", afterStop?.text.contains("AFTERSTOP") == true, describe(afterStop))

        // ---- A43 continue in the terminal, then in chat ----
        if let sessionID {
            terminals.open(employee: nova, tool: store.tool(codex.id), directory: repo.path, environment: store.environment(for: codex), command: codex.terminalResumeArguments(sessionID: sessionID))
            if let terminal = terminals.selected {
                let shown = await wait(45) { let text = terminalText(terminal); return text.contains("4721") || text.contains("AMBER") || text.contains("hello from codex") || text.contains("DONE") }
                let screen = terminalText(terminal).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(12).joined(separator: " | ")
                terminal.send("\u{3}"); try? await Task.sleep(nanoseconds: 700_000_000); terminal.send("\u{3}")
                let ended = await wait(15) { terminal.ended }
                if !ended { terminals.endAll() }
                record("A43a", "\"Continue in Terminal\" opens the same session interactively", shown, "Earlier turns visible in the terminal: \(shown); closed with Ctrl-C: \(ended). Screen: \(excerpt(screen, 500))")
            }
        }
        _ = send("Reply with the word CONTINUED.", to: [nova], conversation: first)
        let continuedID = turns(first).last!.id
        _ = await wait(300) { settled(continuedID) }
        record("A43b", "Chat continues the session after the terminal", store.message(continuedID)?.text.contains("CONTINUED") == true && store.message(continuedID)?.resumed == true, describe(store.message(continuedID)))

        // ---- A40 the conversation resumes after a restart ----
        try? await Task.sleep(nanoseconds: 500_000_000)
        store = WorkbenchStore(fileURL: database)
        store.concurrencyLimit = 2
        _ = send("What is the project codename? Reply with just the codename.", to: [nova], conversation: first)
        let restartID = turns(first).last!.id
        _ = await wait(300) { settled(restartID) }
        record("A40b", "The conversation resumes its session after a restart", store.message(restartID)?.text.contains("AMBER-FINCH") == true && store.message(restartID)?.resumed == true, describe(store.message(restartID)))

        // ---- A44 logged out and missing executable ----
        let noLoginHome = root.appendingPathComponent("empty-codex-home")
        try FileManager.default.createDirectory(at: noLoginHome, withIntermediateDirectories: true)
        let wrapper = root.appendingPathComponent("codex-no-login")
        try "#!/bin/sh\nCODEX_HOME='\(noLoginHome.path)' exec '\(codexPath)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        _ = chmod(wrapper.path, 0o755)
        var loggedOut = codex; loggedOut.id = UUID(); loggedOut.name = "Codex (signed out)"; loggedOut.executable = wrapper.path
        var missing = codex; missing.id = UUID(); missing.name = "Codex (moved)"; missing.executable = root.appendingPathComponent("not-here/codex").path
        _ = store.addTool(loggedOut); _ = store.addTool(missing)
        store.checkLogin(loggedOut.id)
        _ = await wait(60) { [.loggedIn, .loggedOut, .failed].contains(store.loginChecks[loggedOut.id]?.state ?? .unknown) }
        var outAgent = agent("Lee", "工程师", "Be brief.", access: .readOnly); outAgent.toolID = loggedOut.id
        var movedAgent = agent("Max", "工程师", "Be brief.", access: .readOnly); movedAgent.toolID = missing.id
        _ = store.addEmployee(outAgent); _ = store.addEmployee(movedAgent)
        let outConversation = send("Say hi.", to: [outAgent])
        let outTurnID = outConversation.flatMap { turns($0).first?.id }
        if let outTurnID { _ = await wait(400) { settled(outTurnID) } }
        let outTurn = outTurnID.flatMap { store.message($0) }
        let refused = store.sendMessage("Say hi.", projectID: project.id, conversationID: nil, agentIDs: [movedAgent.id], mode: .single, access: .readOnly) == nil && store.missingCLIToolID == missing.id
        store.missingCLIToolID = nil; store.errorMessage = nil
        record("A44", "Signed-out CLI and missing executable get different messages",
               store.loginChecks[loggedOut.id]?.state == .loggedOut && outTurn?.state == .failed && outTurn?.detail?.contains("没有登录") == true && refused,
               "Login check: \(store.loginChecks[loggedOut.id]?.state.rawValue ?? "?"); turn: \(describe(outTurn)); missing executable blocked with Fix path: \(refused)")

        // ---- CH-09 promote a reply to a task and run it ----
        if let taskID = store.promoteToTask(secondID) {
            store.run(taskID)
            _ = await wait(300) { [.review, .failed, .timedOut, .cancelled].contains(store.snapshot.tasks.first { $0.id == taskID }?.status ?? .draft) }
            let task = store.snapshot.tasks.first { $0.id == taskID }
            if task?.status == .review { store.accept(taskID) }
            let final = store.snapshot.tasks.first { $0.id == taskID }
            record("CH-09", "A reply becomes a draft task that runs with Codex and can be accepted", final?.status == .completed, "Status after run: \(task?.status.rawValue ?? "?"); after accept: \(final?.status.rawValue ?? "?"); runs: \(store.runs(for: taskID).count); log tail: \(excerpt(task?.log.suffix(300).description, 300))")
        } else { record("CH-09", "A reply becomes a draft task that runs with Codex and can be accepted", false, "Promote refused: \(store.errorMessage ?? "")") }

        // ---- CH-12 parallel ----
        if let parallel = send("In one sentence, what does src/app.py do?", to: [nova, kai], mode: .parallel, access: .edit) {
            let ids = turns(parallel).map(\.id)
            _ = await wait(300) { ids.allSatisfy(settled) }
            let replies = ids.compactMap { store.message($0) }
            let forcedReadOnly = replies.allSatisfy { run(of: $0)?.arguments.contains("read-only") == true }
            record("CH-12", "Parallel question to two Codex agents, forced Read-only", replies.count == 2 && replies.allSatisfy { $0.state == .replied } && forcedReadOnly,
                   "Replies: \(replies.map { excerpt($0.text, 120) }); all read-only: \(forcedReadOnly)")
        }

        // ---- A45 / A47 team plan with a Codex lead, worker and reviewer ----
        let runsBeforeTeam = store.snapshot.runs.count
        if let team = send("Add two small files. Step 1 for Nova: create docs/usage.md with a one-line usage example of beam() from src/app.py. Step 2 for Kai: create CHANGELOG.md with a single entry 'Initial version'. Plan exactly these two steps and nothing else.", to: [nova, kai], mode: .team, access: .edit) {
            _ = await wait(400) { turns(team).contains { $0.planDraft != nil } || turns(team).filter { $0.state == .failed }.count > 1 }
            let planning = turns(team).first { $0.planDraft != nil }
            let nothingRan = store.snapshot.runs.count == runsBeforeTeam + turns(team).count
            if let planning, let draft = planning.planDraft {
                record("A45a", "Codex lead returns a valid plan using only the selected agents; nothing runs before approval",
                       draft.steps.allSatisfy { [nova.id, kai.id].contains($0.employeeID) } && nothingRan,
                       "Steps: \(draft.steps.map { "\($0.title) → \(store.employee($0.employeeID)?.name ?? "?")" }); only planning runs so far: \(nothingRan); repaired: \(planning.repairOfID != nil)")
                if let planID = store.approveTeamPlan(messageID: planning.id, draft: draft, reviewerID: ada.id, maximumReworks: 1) {
                    let taskIDs = store.snapshot.plans.first { $0.id == planID }?.taskIDs ?? []
                    var statuses: [String] = []
                    for id in taskIDs {
                        _ = await wait(600) { [.review, .completed, .failed, .timedOut, .cancelled].contains(store.snapshot.tasks.first { $0.id == id }?.status ?? .draft) }
                        if store.snapshot.tasks.first(where: { $0.id == id })?.status == .review { store.accept(id) }
                        _ = await wait(30) { store.snapshot.tasks.first { $0.id == id }?.status == .completed }
                        statuses.append("\(store.snapshot.tasks.first { $0.id == id }?.title ?? "?"): \(store.snapshot.tasks.first { $0.id == id }?.status.rawValue ?? "?")")
                    }
                    let usage = FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/usage.md").path)
                    let changelog = FileManager.default.fileExists(atPath: repo.appendingPathComponent("CHANGELOG.md").path)
                    let reviews = store.snapshot.reviews.filter { review in taskIDs.contains(review.sourceTaskID) }.map { "\($0.decision.decision.rawValue)" }
                    let wrapped = await wait(300) { turns(team).contains { $0.turnKind == .wrapUp && $0.state == .replied } }
                    record("A45b", "The approved plan runs both steps with Codex review and a wrap-up", usage && changelog && taskIDs.allSatisfy { id in store.snapshot.tasks.first { $0.id == id }?.status == .completed } && wrapped,
                           "Steps: \(statuses); docs/usage.md: \(usage); CHANGELOG.md: \(changelog); reviewer decisions: \(reviews); wrap-up posted: \(wrapped)")
                } else { record("A45b", "The approved plan runs both steps with Codex review and a wrap-up", false, "Approve refused: \(store.errorMessage ?? "")") }
            } else {
                record("A45a", "Codex lead returns a valid plan using only the selected agents; nothing runs before approval", false, "No plan: \(turns(team).map { describe($0) })")
            }
        }

        }

        // ---- A51 / A53 Codex as director against the local ComfyUI fixture ----
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<128 { for y in 0..<96 { rep.setColor(NSColor(deviceRed: 0.9, green: CGFloat(x) / 128 * 0.5, blue: 0.3 + CGFloat(y) / 96 * 0.5, alpha: 1), atX: x, y: y) } }
        try rep.representation(using: .png, properties: [:])!.write(to: media.appendingPathComponent("image.png"))
        let (server, url) = try startFixture(media: media)
        defer { server.terminate() }
        let gpu = ComfyServer(name: "Fixture GPU", baseURL: url, hourlyPrice: 3.6, currency: "CNY", jobLimit: 1, timeoutSeconds: 120)
        _ = store.saveServer(gpu, token: nil); store.checkServer(gpu.id)
        _ = await wait(30) { store.serverHealth[gpu.id] != nil }
        let workflow = Data(#"{"3":{"class_type":"KSampler","inputs":{"seed":5,"steps":20}},"6":{"class_type":"CLIPTextEncode","inputs":{"text":"a cat"}},"9":{"class_type":"SaveImage","inputs":{"filename_prefix":"wb"}}}"#.utf8)
        let suggestion = WorkflowTemplate.suggest(for: workflow)
        let t2i = WorkflowTemplate(name: "Keyframe t2i", description: "Text to one still image", moduleIDs: [WorkArea.defaults[0].id, WorkArea.defaults[3].id], workflow: workflow, parameters: suggestion.parameters, outputs: suggestion.outputs, estimatedSeconds: 60)
        _ = store.saveTemplate(t2i)
        var director = agent("Iris", "导演", "You direct image and video production. Keep plans minimal.", access: .readOnly); director.workspaceID = WorkArea.defaults[0].id
        _ = store.addEmployee(director)
        var film = WorkProject(name: "Lighthouse poster", directory: try store.defaultProjectDirectory(for: UUID()), goal: "One poster image"); film.moduleIDs = [WorkArea.defaults[0].id]
        _ = store.addProject(film)
        let submittedBefore = ((await fixtureReport(url))["prompts"] as? [Any])?.count ?? 0
        if let production = store.sendMessage("Make exactly one keyframe image with the Keyframe t2i template: a lighthouse at dusk, cinematic. One generate step only, no other steps.", projectID: film.id, conversationID: nil, agentIDs: [director.id], mode: .director, access: .readOnly) {
            _ = await wait(400) { store.snapshot.messages(in: production).contains { $0.planDraft != nil } || store.snapshot.messages(in: production).filter { $0.role == .agent && $0.state == .failed }.count > 1 }
            let planning = store.snapshot.messages(in: production).first { $0.planDraft != nil }
            let submittedAfterPlan = ((await fixtureReport(url))["prompts"] as? [Any])?.count ?? 0
            if let planning, let draft = planning.planDraft {
                let generate = draft.steps.filter { $0.stepKind == .generate }
                record("A51", "Codex director turns a brief into a production plan; nothing submitted before approval", !generate.isEmpty && submittedAfterPlan == submittedBefore,
                       "Steps: \(draft.steps.map { "\($0.stepKind.rawValue): \($0.title)" }); generate steps: \(generate.count); parameters: \(excerpt(generate.first?.parameters?.map { "\($0.name)=\($0.value)" }.joined(separator: ", "), 200)); submitted before approval: \(submittedAfterPlan - submittedBefore)")
                if let planID = store.approveProductionPlan(messageID: planning.id, draft: draft, budgetMinutes: 5, budgetCost: nil, directorReview: true, maximumReworks: 1) {
                    let taskIDs = store.snapshot.plans.first { $0.id == planID }?.taskIDs ?? []
                    _ = await wait(500) { taskIDs.allSatisfy { id in [.review, .completed, .failed, .timedOut, .cancelled].contains(store.snapshot.tasks.first { $0.id == id }?.status ?? .draft) } }
                    _ = await wait(600) {
                        let reviewTasks = store.snapshot.tasks.filter { $0.reviewSourceTaskID.map(taskIDs.contains) == true }
                        return !store.snapshot.reviews.filter { taskIDs.contains($0.sourceTaskID) }.isEmpty
                            || (!reviewTasks.isEmpty && reviewTasks.allSatisfy { [.completed, .failed, .timedOut, .cancelled].contains($0.status) })
                    }
                    let reviewRuns = store.snapshot.tasks.filter { $0.reviewSourceTaskID.map(taskIDs.contains) == true }.map { "\($0.title): \($0.status.rawValue)" }
                    let reviews = store.snapshot.reviews.filter { taskIDs.contains($0.sourceTaskID) }
                    let statuses = taskIDs.map { id in store.snapshot.tasks.first { $0.id == id }.map { "\($0.title): \($0.status.rawValue)" } ?? "?" }
                    let submitted = ((await fixtureReport(url))["prompts"] as? [Any])?.count ?? 0
                    record("A53", "The image runs on the server and the Codex director reviews it", submitted > submittedBefore && !reviews.isEmpty,
                           "Steps: \(statuses); review tasks: \(reviewRuns); jobs submitted: \(submitted - submittedBefore); director reviews: \(reviews.map { "\($0.decision.decision.rawValue): \(excerpt($0.decision.notes, 140))" })")
                } else { record("A53", "The image runs on the server and the Codex director reviews it", false, "Approve refused: \(store.errorMessage ?? "")") }
            } else {
                record("A51", "Codex director turns a brief into a production plan; nothing submitted before approval", false, "No plan: \(store.snapshot.messages(in: production).filter { $0.role == .agent }.map { describe($0) })")
            }
        }

        try finish(root: root, started: started)
        terminals.endAll()
    }

    static func finish(root: URL, started: Date) throws {
        let passed = results.filter { $0["passed"] as? Bool == true }.count
        let report: [String: Any] = ["workspace": root.path, "started": ISO8601DateFormatter().string(from: started), "seconds": Int(Date().timeIntervalSince(started)),
                                     "passed": passed, "failed": results.count - passed, "results": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("real-codex-report.json"))
        print("Real Codex pass finished: \(passed) passed, \(results.count - passed) failed, \(Int(Date().timeIntervalSince(started))) s. Report: \(root.path)/real-codex-report.json")
    }
}
