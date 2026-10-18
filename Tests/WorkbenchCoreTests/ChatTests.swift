import XCTest
@testable import WorkbenchCore

final class ChatTests: XCTestCase {
    func testConversationTitleAndTurnStateMapping() {
        XCTAssertEqual(Conversation.title(from: "  修复解析器崩溃 \n第二行"), "修复解析器崩溃")
        XCTAssertEqual(Conversation.title(from: "\n\n"), "新对话")
        XCTAssertEqual(Conversation.title(from: String(repeating: "长", count: 60)).count, 40)
        XCTAssertEqual(TurnState(.review), .replied); XCTAssertEqual(TurnState(.cancelled), .stopped)
        XCTAssertEqual(TurnState(.timedOut), .timedOut); XCTAssertEqual(TurnState(.failed), .failed)
        XCTAssertTrue(TurnState.queued.isActive && TurnState.running.isActive && !TurnState.replied.isActive)
    }

    func testSessionsAreRecordedPerConversationAgentAndCLI() {
        var snapshot = WorkspaceSnapshot()
        let conversation = UUID(), agent = UUID(), tool = UUID()
        snapshot.recordSession(conversationID: conversation, agentID: agent, toolID: tool, nativeID: "s-1")
        snapshot.recordSession(conversationID: conversation, agentID: agent, toolID: tool, nativeID: "s-2")
        XCTAssertEqual(snapshot.sessions.count, 1); XCTAssertEqual(snapshot.usableSession(conversationID: conversation, agentID: agent, toolID: tool)?.nativeID, "s-2")
        XCTAssertNil(snapshot.usableSession(conversationID: conversation, agentID: agent, toolID: UUID()), "Switching the agent's CLI starts a new session")
        snapshot.sessions[0].invalid = true
        XCTAssertNil(snapshot.usableSession(conversationID: conversation, agentID: agent, toolID: tool))
        snapshot.recordSession(conversationID: conversation, agentID: agent, toolID: tool, nativeID: "s-3")
        XCTAssertEqual(snapshot.sessions.count, 2); XCTAssertEqual(snapshot.usableSession(conversationID: conversation, agentID: agent, toolID: tool)?.nativeID, "s-3")
    }

    func testTranscriptContextIsBoundedAndSkipsUnfinishedTurns() {
        var snapshot = WorkspaceSnapshot()
        let agent = Employee(name: "Claude", role: "dev", department: "", instructions: "", toolID: UUID()); snapshot.employees = [agent]
        let conversation = UUID(), start = Date()
        for index in 0..<30 {
            var user = ChatMessage(conversationID: conversation, role: .user, text: "question \(index) " + String(repeating: "x", count: 900), createdAt: start.addingTimeInterval(Double(index * 2)))
            user.targetIDs = [agent.id]
            var reply = ChatMessage(conversationID: conversation, role: .agent, text: "answer \(index)", createdAt: start.addingTimeInterval(Double(index * 2 + 1)))
            reply.agentID = agent.id; reply.state = index == 29 ? .failed : .replied
            snapshot.messages += [user, reply]
        }
        let context = snapshot.transcriptContext(conversationID: conversation, before: start.addingTimeInterval(1000), limit: 5000)
        XCTAssertLessThanOrEqual(context.count, 5000); XCTAssertTrue(context.contains("question 29")); XCTAssertFalse(context.contains("answer 29"))
        XCTAssertTrue(context.contains("Claude：answer 28")); XCTAssertFalse(context.contains("question 0 "))
    }

    func testRestartInterruptsActiveTurnsAndPersistsChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = WorkspaceSnapshot()
        let conversation = Conversation(projectID: UUID(), title: "对话")
        var running = ChatMessage(conversationID: conversation.id, role: .agent, text: "partial"); running.state = .running
        var queued = ChatMessage(conversationID: conversation.id, role: .agent, text: ""); queued.state = .queued
        var done = ChatMessage(conversationID: conversation.id, role: .agent, text: "ok"); done.state = .replied
        snapshot.conversations = [conversation]; snapshot.messages = [running, queued, done]
        snapshot.sessions = [AgentSession(conversationID: conversation.id, agentID: UUID(), toolID: UUID(), nativeID: "abc")]
        let persistence = WorkspacePersistence(fileURL: root.appendingPathComponent("workspace.sqlite"))
        try persistence.save(snapshot)
        let loaded = try persistence.load()
        XCTAssertEqual(loaded.conversations, [conversation]); XCTAssertEqual(loaded.sessions, snapshot.sessions)
        XCTAssertEqual(loaded.messages.map(\.state), [.interrupted, .interrupted, .replied])
        XCTAssertEqual(loaded.messages[0].text, "partial", "Partial output survives a restart")
    }

    func testDiagnosisNamesLoginDenialTimeoutAndExitCode() {
        var tool = ToolConfig(name: "cli", executable: "/usr/bin/true", arguments: []); tool.loggedOutText = "Not logged in"; tool.timeoutSeconds = 30
        var summary = CLIOutputSummary()
        XCTAssertNil(TurnDiagnosis.explain(status: .review, exitCode: 0, summary: summary, tool: tool, outputTail: ""))
        XCTAssertTrue(TurnDiagnosis.explain(status: .failed, exitCode: 1, summary: summary, tool: tool, outputTail: "Not logged in · Please run /login")!.contains("没有登录"))
        XCTAssertTrue(TurnDiagnosis.explain(status: .timedOut, exitCode: nil, summary: summary, tool: tool, outputTail: "")!.contains("30 秒"))
        XCTAssertTrue(TurnDiagnosis.explain(status: .failed, exitCode: 7, summary: summary, tool: tool, outputTail: "boom\n")!.contains("退出码 7：boom"))
        summary.permissionDenials = ["Bash", "Write", "Bash"]
        let denied = TurnDiagnosis.explain(status: .review, exitCode: 0, summary: summary, tool: tool, outputTail: "")!
        XCTAssertTrue(denied.contains("拒绝了 3 个") && denied.contains("Bash、Write"))
    }

    func testPermissionDenialsParsedFromStreamJSON() {
        let collector = CLIOutputCollector(format: .streamJSON)
        collector.consume(#"{"type":"result","subtype":"success","result":"done","session_id":"s","permission_denials":[{"tool_name":"Bash","tool_use_id":"x","tool_input":{}}]}"# + "\n")
        XCTAssertEqual(collector.finish().permissionDenials, ["Bash"])
    }

    func testPlanSchemaCarriesAccessAndStepsDecodeIt() throws {
        let schema = try JSONDecoder().decode(JSONValue.self, from: CollaborationSchema.plan(employeeIDs: [UUID()]))
        XCTAssertEqual(schema["properties"]["steps"]["items"]["properties"]["access"]["enum"].array?.compactMap(\.string), ["readOnly", "edit"])
        let step = try JSONDecoder().decode(PlanStep.self, from: Data(#"{"id":"a","title":"t","employeeID":"\#(UUID().uuidString)","input":"i","acceptance":"x","dependencies":[],"access":"edit"}"#.utf8))
        XCTAssertEqual(step.access, .edit)
        let legacy = try JSONDecoder().decode(PlanStep.self, from: Data(#"{"id":"a","title":"t","employeeID":"\#(UUID().uuidString)","input":"i","acceptance":"x","dependencies":[]}"#.utf8))
        XCTAssertNil(legacy.access)
    }

    func testTerminalResumeArguments() {
        var tool = ToolConfig(name: "cli", executable: "/usr/bin/true", arguments: ["-p", "{prompt}"])
        XCTAssertFalse(tool.supportsTerminalResume)
        tool.interactiveResumeArguments = ["--resume", "{session_id}"]
        XCTAssertEqual(tool.terminalResumeArguments(sessionID: "abc; rm -rf /"), ["--resume", "abc; rm -rf /"])
        tool.interactiveResumeArguments = ["--resume", "{session_id}", "--permission-mode", "bypassPermissions"]
        XCTAssertEqual(tool.bypassWarnings, ["bypassPermissions"])
    }
}
