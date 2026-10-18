import AppKit
import SwiftUI
import SwiftTerm

// M6 chat and M7 team verification. Drives the real WorkbenchStore against an isolated database with two
// fake CLIs (scripts/fixtures): one speaks Claude Code's stream-json, the other Codex's JSONL. No model is called.
@main struct M6M7Verification {
    @MainActor static func wait(_ what: String, timeout: Double = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(condition(), "Timed out waiting for: \(what)")
    }
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) { precondition(condition, message()) }
    static func calls(_ folder: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("state/calls.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    @MainActor static func terminalText(_ session: TerminalSession) -> String {
        let emulator = session.terminal.getTerminal()
        return (0..<emulator.rows).compactMap { row in
            emulator.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true, characterProvider: { emulator.getCharacter(for: $0) })
        }.joined(separator: "\n")
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("work/m6m7-qa")
        let root = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        let limitations = ["Fake CLIs stand in for Claude Code and Codex; real-model runs wait on the user's CLI logins.", "Snapshots are offscreen renders; clicks, keyboard, drag and drop and VoiceOver still need hands-on testing."]

        // Fixtures live in folders with spaces in their paths.
        func install(_ name: String, as folderName: String) throws -> URL {
            let folder = root.appendingPathComponent(folderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name.replacingOccurrences(of: ".py", with: ""))
            try FileManager.default.copyItem(at: project.appendingPathComponent("scripts/fixtures/" + name), to: target)
            check(chmod(target.path, 0o755) == 0, "chmod \(name)")
            return target
        }
        let claudeURL = try install("claude_like.py", as: "claude cli"), codexURL = try install("codex_like.py", as: "codex cli")
        let claudeFolder = claudeURL.deletingLastPathComponent(), codexFolder = codexURL.deletingLastPathComponent()

        // Appendix A values, entered by hand. Nothing here is built into the app.
        var claudeCLI = ToolConfig(name: "Claude Code", executable: claudeURL.path, arguments: ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--session-id", "{session_id}"])
        claudeCLI.resumeArguments = ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--resume", "{session_id}"]
        claudeCLI.interactiveResumeArguments = ["--resume", "{session_id}"]
        claudeCLI.outputFormat = .streamJSON; claudeCLI.includeInstructions = true; claudeCLI.useLoginShellPath = true
        claudeCLI.readOnlyArguments = ["--permission-mode", "plan"]; claudeCLI.editArguments = ["--permission-mode", "acceptEdits"]
        claudeCLI.structuredOutputArguments = ["--json-schema", "{schema}"]; claudeCLI.modelArguments = ["--model", "{model}"]
        claudeCLI.loginStatusArguments = ["auth", "status"]; claudeCLI.loggedOutText = #""loggedIn": false"#; claudeCLI.timeoutSeconds = 60
        var codexCLI = ToolConfig(name: "Codex", executable: codexURL.path, arguments: ["exec", "--json", "--skip-git-repo-check", "{flags}", "--", "{prompt}"])
        codexCLI.resumeArguments = ["exec", "resume", "--json", "{session_id}", "--", "{prompt}"]
        codexCLI.interactiveResumeArguments = ["resume", "{session_id}"]
        codexCLI.outputFormat = .jsonLines; codexCLI.includeInstructions = true; codexCLI.useLoginShellPath = true
        codexCLI.readOnlyArguments = ["--sandbox", "read-only"]; codexCLI.editArguments = ["--sandbox", "workspace-write"]
        codexCLI.structuredOutputArguments = ["--output-schema", "{schema_file}"]; codexCLI.timeoutSeconds = 60
        codexCLI.loginStatusArguments = ["login", "status"]; codexCLI.loggedOutText = "Not logged in"

        let database = root.appendingPathComponent("workspace.sqlite")
        var store = WorkbenchStore(fileURL: database)
        check(store.addTool(claudeCLI) && store.addTool(codexCLI), "Add CLIs")
        var claude = Employee(name: "Claude", role: "负责人", department: "开发工作区", instructions: "Lead carefully.", toolID: claudeCLI.id)
        claude.workspaceID = WorkArea.defaults[2].id; claude.maxAccess = .edit
        var codex = Employee(name: "Codex", role: "工程师", department: "开发工作区", instructions: "Implement.", toolID: codexCLI.id)
        codex.workspaceID = WorkArea.defaults[2].id; codex.maxAccess = .edit
        var reviewer = Employee(name: "Reviewer", role: "审核", department: "开发工作区", instructions: "Review.", toolID: claudeCLI.id)
        reviewer.workspaceID = WorkArea.defaults[2].id; reviewer.maxAccess = .readOnly
        check(store.addEmployee(claude) && store.addEmployee(codex) && store.addEmployee(reviewer), "Add agents")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        var app = WorkProject(name: "Parser fixes", directory: repo.path, goal: "Fix the parser"); app.moduleIDs = [WorkArea.defaults[2].id]
        check(store.addProject(app), "Add project")
        store.concurrencyLimit = 2

        func turns(_ conversation: UUID) -> [ChatMessage] { store.snapshot.messages(in: conversation).filter { $0.role == .agent } }
        func send(_ text: String, to agents: [Employee], conversation: UUID? = nil, mode: ChatMode = .single, access: AccessLevel = .readOnly) -> UUID {
            guard let id = store.sendMessage(text, projectID: app.id, conversationID: conversation, agentIDs: agents.map(\.id), mode: mode, access: access) else { preconditionFailure("send failed: \(store.errorMessage ?? "")") }
            return id
        }
        func settled(_ id: UUID) -> Bool { store.message(id)?.state?.isActive == false }

        // ---- A38 streaming and A39 follow-up turns ----
        let first = send("Remember the codeword PELICAN. STREAM please", to: [claude])
        let firstTurn = turns(first)[0].id
        try await wait("streamed text before exit") { store.message(firstTurn)?.state == .running && (store.liveTurns[firstTurn]?.text.contains("word") ?? false) }
        try await wait("first reply") { settled(firstTurn) }
        let firstReply = store.message(firstTurn)!
        check(firstReply.state == .replied && firstReply.text.contains("turn 1"), "First reply: \(firstReply.text) \(firstReply.detail ?? "")")
        let firstRun = store.snapshot.runs.first { $0.id == firstReply.runID }!
        check(((try? String(contentsOf: URL(fileURLWithPath: firstRun.logPath), encoding: .utf8)) ?? "").contains("\"type\": \"result\""), "Raw event log archived")
        check(firstReply.usage?.costUSD != nil && firstReply.resumed == false, "Usage recorded; first turn is a new session")
        checks.append("A38 reply text streamed into the transcript before the CLI exited; the raw event log was archived with the run")
        _ = send("What was the codeword?", to: [claude], conversation: first)
        let secondTurn = turns(first)[1].id
        try await wait("second reply") { settled(secondTurn) }
        let second = store.message(secondTurn)!
        let session = store.session(for: second)!
        check(second.resumed == true && second.text.contains("turn 2 of \(session.nativeID)") && second.text.contains("PELICAN"), "Follow-up resumed the session and recalled turn 1: \(second.text)")
        let resumeCall = calls(claudeFolder).last!["argv"] as! [String]
        check(resumeCall.contains("--resume") && resumeCall.contains(session.nativeID), "Second call used --resume with the recorded session")
        checks.append("A39 a follow-up resumed the same native session (\(session.nativeID.prefix(8))…) and the agent recalled the codeword from turn 1")

        // ---- A42 queue and A41 stop ----
        let busy = send("SLOW long job", to: [claude])
        let slowTurn = turns(busy)[0].id
        try await wait("slow turn streaming") { store.liveTurns[slowTurn]?.text.contains("tick") ?? false }
        _ = send("second in line", to: [claude], conversation: busy)
        _ = send("third in line", to: [claude], conversation: busy)
        let queued = turns(busy).dropFirst().map(\.id)
        check(queued.allSatisfy { store.message($0)?.state == .queued }, "Messages to a busy agent are queued")
        store.stopTurn(queued[1])
        check(store.message(queued[1])?.state == .cancelled, "A queued message can be cancelled")
        let stopAt = Date()
        store.stopTurn(slowTurn)
        try await wait("stopped", timeout: 6) { settled(slowTurn) }
        let stopped = store.message(slowTurn)!
        check(stopped.state == .stopped && stopped.text.contains("tick") && Date().timeIntervalSince(stopAt) < 4, "Stop ends the turn quickly and keeps partial output")
        try await wait("queued turn runs after stop") { settled(queued[0]) }
        let afterStop = store.message(queued[0])!
        check(afterStop.state == .replied && afterStop.resumed == true && afterStop.text.contains("turn 2"), "The next message resumed the stopped session: \(afterStop.text) \(afterStop.detail ?? "")")
        check(!calls(claudeFolder).contains { ($0["prompt"] as? String)?.contains("third in line") == true }, "The cancelled message never reached the CLI")
        checks.append("A41 stop ended the turn within the process-group limits, kept the partial reply, and the next message resumed the session")
        checks.append("A42 a message to a busy agent queued and ran afterwards; a cancelled queued message never ran")

        // ---- A40 restart: a running turn becomes Interrupted and is not sent again ----
        let restartConversation = send("SLOW restart probe", to: [claude])
        let restartTurn = turns(restartConversation)[0].id
        try await wait("restart probe running") { store.liveTurns[restartTurn]?.text.contains("tick") ?? false }
        let reopened = WorkbenchStore(fileURL: database)
        check(reopened.message(restartTurn)?.state == .interrupted && reopened.activeTurns.isEmpty, "After restart the running turn is Interrupted")
        store.stopTurn(restartTurn)
        try await wait("original turn stopped") { settled(restartTurn) }
        try await Task.sleep(nanoseconds: 300_000_000)
        store = reopened
        store.concurrencyLimit = 2
        _ = store.save()
        let probeCalls = calls(claudeFolder).filter { ($0["prompt"] as? String)?.contains("restart probe") == true }.count
        check(probeCalls <= 1, "The interrupted turn was not sent again (calls: \(probeCalls))")
        _ = send("After the restart, the codeword again?", to: [claude], conversation: first)
        let thirdTurn = turns(first).last!.id
        try await wait("reply after restart") { settled(thirdTurn) }
        check(store.message(thirdTurn)?.text.contains("turn 3") == true && store.message(thirdTurn)?.resumed == true, "Conversation resumed after restart")
        checks.append("A40 after a restart the running turn showed as Interrupted and was not re-sent; the conversation then resumed its session")

        // ---- A43 continue in the terminal, then in chat ----
        let terminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history.json"))
        let lastTurn = store.message(thirdTurn)!
        let nativeID = store.session(for: lastTurn)!.nativeID
        terminals.open(employee: claude, tool: store.tool(claudeCLI.id), directory: repo.path, environment: store.environment(for: claudeCLI), command: claudeCLI.terminalResumeArguments(sessionID: nativeID))
        let terminal = terminals.selected!
        try await wait("interactive resume in terminal") { terminalText(terminal).contains("interactive resume " + nativeID) }
        terminal.send("\n")
        try await wait("terminal session ends") { terminal.ended }
        _ = send("back in chat", to: [claude], conversation: first)
        let fourthTurn = turns(first).last!.id
        try await wait("chat after terminal") { settled(fourthTurn) }
        check(store.message(fourthTurn)?.text.contains("turn 4 of \(nativeID)") == true, "Chat continued the same session after the terminal")
        checks.append("A43 \"在终端继续\" opened the CLI interactively on the same session; the chat then continued that session")

        // ---- A44 failure messages ----
        FileManager.default.createFile(atPath: claudeFolder.appendingPathComponent("state/logged-out").path, contents: nil)
        let loggedOut = send("hello", to: [claude])
        let loggedOutTurn = turns(loggedOut)[0].id
        try await wait("logged-out turn") { settled(loggedOutTurn) }
        check(store.message(loggedOutTurn)?.state == .failed && store.message(loggedOutTurn)?.detail?.contains("没有登录") == true, "Logged-out CLI: \(store.message(loggedOutTurn)?.detail ?? "")")
        try FileManager.default.removeItem(at: claudeFolder.appendingPathComponent("state/logged-out"))
        let denied = send("NEEDS-APPROVAL deploy it", to: [claude])
        let deniedTurn = turns(denied)[0].id
        try await wait("denied turn") { settled(deniedTurn) }
        check(store.message(deniedTurn)?.detail?.contains("拒绝了 1 个") == true, "Denied action: \(store.message(deniedTurn)?.detail ?? "")")
        let moved = codexFolder.appendingPathComponent("codex_like.moved")
        try FileManager.default.moveItem(at: codexURL, to: moved)
        check(store.sendMessage("hi", projectID: app.id, conversationID: nil, agentIDs: [codex.id], mode: .single, access: .readOnly) == nil && store.missingCLIToolID == codexCLI.id, "Missing executable blocks the send with a fix-path prompt")
        store.missingCLIToolID = nil
        try FileManager.default.moveItem(at: moved, to: codexURL)
        checks.append("A44 a logged-out CLI, an action the CLI denied, and a missing executable each produced a different message")

        // ---- CH-09 promote, CH-12 parallel ----
        let taskID = store.promoteToTask(secondTurn)!
        let promoted = store.snapshot.tasks.first { $0.id == taskID }!
        check(promoted.status == .draft && promoted.employeeID == claude.id && promoted.projectID == app.id && store.message(secondTurn)?.promotedTaskID == taskID, "Reply promoted to a draft task")
        checks.append("CH-09 a reply became a draft task for the same agent and project")
        let parallel = send("compare approaches", to: [claude, codex], mode: .parallel, access: .edit)
        let parallelTurns = turns(parallel).map(\.id)
        try await wait("parallel replies") { parallelTurns.allSatisfy(settled) }
        let claudeParallel = calls(claudeFolder).last { ($0["prompt"] as? String)?.contains("compare approaches") == true }!
        let codexParallel = calls(codexFolder).last { ($0["prompt"] as? String)?.contains("compare approaches") == true }!
        check(claudeParallel["mode"] as? String == "plan" && codexParallel["sandbox"] as? String == "read-only", "Parallel turns are forced read-only")
        checks.append("CH-12 a parallel message reached both CLIs as separate sessions, forced read-only")

        // ---- A45 team plan, repair, approval; A46 one writer per folder; TM-09 wrap-up ----
        let codexCallsBefore = calls(codexFolder).count
        let team = send("INVALID-PLAN Build CSV export", to: [claude, codex], mode: .team, access: .edit)
        try await wait("plan after one repair", timeout: 30) { turns(team).contains { $0.planDraft != nil } || turns(team).filter { $0.state == .failed }.count > 1 }
        let teamTurns = turns(team)
        let planning = teamTurns.first { $0.planDraft != nil }!
        check(teamTurns.count == 2 && planning.repairOfID == teamTurns[0].id && teamTurns[0].detail?.contains("已请负责人修正一次") == true, "Invalid plan rejected and repaired once")
        check(calls(codexFolder).count == codexCallsBefore, "Nothing ran before approval")
        var draft = planning.planDraft!
        check(draft.steps.allSatisfy { [claude.id, codex.id].contains($0.employeeID) }, "Plan uses only the selected agents")
        draft.steps[2].title = "Check both parts (edited)"
        let planID = store.approveTeamPlan(messageID: planning.id, draft: draft, reviewerID: nil, maximumReworks: 1)!
        let plan = store.snapshot.plans.first { $0.id == planID }!
        check(plan.conversationID == team && plan.leadID == claude.id && store.snapshot.tasks.contains { $0.title == "Check both parts (edited)" }, "Edited plan approved and linked to the conversation")
        for title in ["Edit part A", "Edit part B"] {
            let task = store.snapshot.tasks.first { $0.planID == planID && $0.title == title }!
            try await wait("\(title) ready for review", timeout: 30) { store.snapshot.tasks.first { $0.id == task.id }?.status == .review }
            store.accept(task.id)
        }
        let editCalls = calls(codexFolder).filter { $0["sandbox"] as? String == "workspace-write" && (($0["prompt"] as? String)?.contains("LOCKTEST edit") ?? false) }
        check(editCalls.count == 2, "Both edit steps ran: \(editCalls.count)")
        let (e1, e2) = (editCalls[0], editCalls[1])
        check((e1["end"] as! Double) <= (e2["start"] as! Double) || (e2["end"] as! Double) <= (e1["start"] as! Double), "Two Edit steps in one folder never overlapped")
        let check3 = store.snapshot.tasks.first { $0.planID == planID && $0.title == "Check both parts (edited)" }!
        try await wait("lead step ready", timeout: 30) { store.snapshot.tasks.first { $0.id == check3.id }?.status == .review }
        store.accept(check3.id)
        try await wait("wrap-up reply", timeout: 30) { turns(team).contains { $0.turnKind == .wrapUp && $0.state == .replied } }
        checks.append("A45 a Claude Code lead planned for Claude Code and Codex; an invalid (cyclic) plan was rejected and repaired once; nothing ran before approval; the edited plan ran")
        checks.append("TM-09 after every step was accepted the lead posted a wrap-up in the conversation")

        let pair = send("READONLY-PAIR survey the code", to: [claude, codex], mode: .team, access: .edit)
        try await wait("read-only pair plan", timeout: 30) { turns(pair).contains { $0.planDraft != nil } }
        let pairTurn = turns(pair).first { $0.planDraft != nil }!
        _ = store.approveTeamPlan(messageID: pairTurn.id, draft: pairTurn.planDraft!, reviewerID: nil, maximumReworks: 0)
        try await wait("read-only pair ran", timeout: 30) { calls(codexFolder).filter { ($0["prompt"] as? String)?.contains("LOCKTEST read") == true }.count == 2 }
        let readCalls = calls(codexFolder).filter { ($0["prompt"] as? String)?.contains("LOCKTEST read") == true }
        let (r1, r2) = (readCalls[0], readCalls[1])
        check((r1["start"] as! Double) < (r2["end"] as! Double) && (r2["start"] as! Double) < (r1["end"] as! Double) && readCalls.allSatisfy { $0["sandbox"] as? String == "read-only" }, "Two Read-only steps overlapped")
        checks.append("A46 two Edit steps on one folder never overlapped, while two Read-only steps ran at the same time")

        // ---- A47 reviewer on a different CLI, with one rework ----
        let reviewed = send("REVIEW-PLAN make the change", to: [claude, codex], mode: .team, access: .edit)
        try await wait("review plan", timeout: 30) { turns(reviewed).contains { $0.planDraft != nil } }
        let reviewedTurn = turns(reviewed).first { $0.planDraft != nil }!
        let reviewedPlan = store.approveTeamPlan(messageID: reviewedTurn.id, draft: reviewedTurn.planDraft!, reviewerID: reviewer.id, maximumReworks: 1)!
        let reviewedTask = store.snapshot.plans.first { $0.id == reviewedPlan }!.taskIDs[0]
        try await wait("review pass after one rework", timeout: 45) { store.snapshot.tasks.first { $0.id == reviewedTask }?.status == .completed }
        let decisions = store.snapshot.reviews.filter { $0.sourceTaskID == reviewedTask }.sorted { $0.createdAt < $1.createdAt }.map(\.decision.decision)
        check(decisions == [.rework, .pass] && store.runs(for: reviewedTask).count == 2, "Reviewer asked for one rework, then passed; both runs kept: \(decisions)")
        checks.append("A47 a reviewer on a different CLI (Claude Code reviewing Codex) asked for one rework then passed; both runs were kept")

        // ---- Restart keeps everything ----
        try await wait("all turns settled", timeout: 30) { store.snapshot.messages.allSatisfy { $0.state?.isActive != true } && store.activeRuns.isEmpty }
        try await Task.sleep(nanoseconds: 300_000_000)
        let restarted = WorkbenchStore(fileURL: database)
        check(restarted.snapshot.conversations.count == store.snapshot.conversations.count && restarted.snapshot.sessions.count == store.snapshot.sessions.count && restarted.snapshot.messages.count == store.snapshot.messages.count, "Chat persists across restart")

        // ---- Snapshots ----
        let suite = "MyWorkbench.M6.QA.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("paper", forKey: "studioThemeV06")
        if let appIcon = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon-512-2x.png")) { _ = appIcon.setName("AppIcon") }
        for name in ["StudioHero", "StudioVideo", "StudioAudio", "StudioCode", "StudioDesign"] {
            if let image = NSImage(contentsOf: project.appendingPathComponent("Assets.xcassets/\(name).imageset/image.png")) { _ = image.setName(name) }
        }
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 1440, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        defer { terminals.endAll(); window.orderOut(nil) }
        let shots = output.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        var screenshots: [String] = []
        func render(_ name: String, _ view: some View, width: CGFloat = 1440, height: CGFloat = 900, dark: Bool = false) async throws {
            hosting.rootView = AnyView(view.defaultAppStorage(preferences).id(name))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); hosting.appearance = window.appearance
            window.setContentSize(NSSize(width: width, height: height)); hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            try await Task.sleep(nanoseconds: 800_000_000)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { preconditionFailure("render \(name)") }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: shots.appendingPathComponent(name + ".png"))
            screenshots.append(name); print("Rendered \(name)")
        }
        let restartedTerminals = TerminalWorkspace(metadataURL: root.appendingPathComponent("terminal-history-2.json"))
        // Most recent conversation first: the review plan; then open the first chat explicitly via the title order.
        try await render("m6-team-conversation", WorkbenchView(terminals: restartedTerminals, initialPage: .projects, initialProjectID: app.id, store: store))
        try await render("m6-team-conversation-compact", WorkbenchView(terminals: restartedTerminals, initialPage: .projects, initialProjectID: app.id, store: store), width: 1100, height: 720)
        try await render("m6-conversation-view", ConversationView(store: store, conversationID: first, accent: Color(red: 88/255, green: 115/255, blue: 94/255), onContinueInTerminal: { _ in }, onOpenTask: { _ in }, onReviewPlan: { _ in }).padding(20).background(Color(hex: "F5F8FA")), width: 900, height: 900)
        try await render("m6-team-plan-steps", ConversationView(store: store, conversationID: team, accent: Color(red: 88/255, green: 115/255, blue: 94/255), onContinueInTerminal: { _ in }, onOpenTask: { _ in }, onReviewPlan: { _ in }).padding(20).background(Color(hex: "F5F8FA")), width: 900, height: 1100)
        try await render("m6-failures", ConversationView(store: store, conversationID: denied, accent: Color(red: 88/255, green: 115/255, blue: 94/255), onContinueInTerminal: { _ in }, onOpenTask: { _ in }, onReviewPlan: { _ in }).padding(20).background(Color(hex: "F5F8FA")), width: 900, height: 400)
        let pending = send("Plan only, review later: new parser", to: [claude, codex], mode: .team, access: .edit)
        try await wait("pending plan", timeout: 30) { turns(pending).contains { $0.planDraft != nil } }
        let pendingTurn = turns(pending).first { $0.planDraft != nil }!
        try await render("m6-plan-card-pending", ConversationView(store: store, conversationID: pending, accent: Color(red: 88/255, green: 115/255, blue: 94/255), onContinueInTerminal: { _ in }, onOpenTask: { _ in }, onReviewPlan: { _ in }).padding(20).background(Color(hex: "F5F8FA")), width: 900, height: 700)
        try await render("m6-plan-approval", PlanApprovalSheet(draft: pendingTurn.planDraft!, planningTaskID: nil, projectID: app.id, store: store, teamMessageID: pendingTurn.id, allowedAgentIDs: [claude.id, codex.id]).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light), width: 690, height: 680)
        try await render("m6-composer-team", ChatComposerView(store: store, accent: Color(red: 88/255, green: 115/255, blue: 94/255), text: .constant("把 CSV 导出拆给你们两位"), agentIDs: .constant([claude.id, codex.id]), mode: .constant(.team), access: .constant(.edit), attachments: .constant([repo.appendingPathComponent("spec.md").path]), projectID: .constant(app.id), lockedProjectID: app.id, conversationTitle: "Build CSV export", onSend: {}, onAttach: {}, onNewTask: {}, onPlanner: {}, onAddWorkspace: {}, onTerminal: {}, onNewProject: {}, onNewConversation: {}).background(Color(hex: "F5F8FA")), width: 900, height: 140)
        try await render("m6-composer-home", ChatComposerView(store: store, accent: Color(red: 88/255, green: 115/255, blue: 94/255), text: .constant(""), agentIDs: .constant([]), mode: .constant(.single), access: .constant(.readOnly), attachments: .constant([]), projectID: .constant(app.id), lockedProjectID: nil, conversationTitle: nil, onSend: {}, onAttach: {}, onNewTask: {}, onPlanner: {}, onAddWorkspace: {}, onTerminal: {}, onNewProject: {}, onNewConversation: {}).background(Color(hex: "F5F8FA")), width: 900, height: 140)
        preferences.set("ink", forKey: "studioThemeV06")
        try await render("m6-team-conversation-dark", WorkbenchView(terminals: restartedTerminals, initialPage: .projects, initialProjectID: app.id, store: store), dark: true)

        let report: [String: Any] = ["passed": true, "workspace": root.path, "checks": checks, "screenshots": screenshots.map { shots.appendingPathComponent($0 + ".png").path }, "limitations": limitations]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("m6m7-verification.json"))
        for line in checks { print("✓ " + line) }
        for line in limitations { print("! " + line) }
        print("M6/M7 verification passed: \(checks.count) checks, \(screenshots.count) snapshots")
        restartedTerminals.endAll()
        exit(0)
    }
}
