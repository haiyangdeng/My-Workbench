import XCTest
@testable import WorkbenchCore

final class CLIDefinitionTests: XCTestCase {
    private func claudeLike() -> ToolConfig {
        var tool = ToolConfig(name: "Claude Code", executable: "/usr/bin/true", arguments: ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--session-id", "{session_id}"])
        tool.resumeArguments = ["-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--resume", "{session_id}"]
        tool.outputFormat = .streamJSON
        tool.readOnlyArguments = ["--permission-mode", "plan"]
        tool.editArguments = ["--permission-mode", "acceptEdits"]
        tool.modelArguments = ["--model", "{model}"]
        tool.structuredOutputArguments = ["--json-schema", "{schema}"]
        return tool
    }

    func testPromptStaysOneLiteralArgumentAndIsNeverRescanned() throws {
        let tool = ToolConfig(name: "echo", executable: "/bin/echo", arguments: ["--in", "{prompt}", "--out={output}/x"])
        let prompt = "line 1\nquote \" ; $(touch nope) `id` {output} {session_id}"
        let argv = try tool.invocation(CLIInvocation(prompt: prompt, outputDirectory: "/tmp/run", workingDirectory: "/tmp"))
        XCTAssertEqual(argv, ["--in", prompt, "--out=/tmp/run/x"])
        XCTAssertEqual(ToolConfig.expand("{unknown}{prompt}", values: ["prompt": "{prompt}"]), "{unknown}{prompt}")
    }

    func testFlagsGoToPlaceholderThenBeforeSeparatorThenAtEnd() throws {
        var tool = ToolConfig(name: "x", executable: "/usr/bin/true", arguments: ["exec", "{flags}", "--", "{prompt}"])
        tool.readOnlyArguments = ["--sandbox", "read-only"]; tool.editArguments = ["--sandbox", "workspace-write", "--add-dir", "{output}"]
        let call = CLIInvocation(prompt: "hi", outputDirectory: "/o", workingDirectory: "/w", access: .edit)
        XCTAssertEqual(try tool.invocation(call), ["exec", "--sandbox", "workspace-write", "--add-dir", "/o", "--", "hi"])
        tool.arguments = ["exec", "--json", "--", "{prompt}"]
        XCTAssertEqual(try tool.invocation(call), ["exec", "--json", "--sandbox", "workspace-write", "--add-dir", "/o", "--", "hi"])
        tool.arguments = ["-p", "{prompt}"]
        XCTAssertEqual(try tool.invocation(call), ["-p", "hi", "--sandbox", "workspace-write", "--add-dir", "/o"])
    }

    func testAccessLevelsModelSchemaAndBypassWarnings() throws {
        var tool = claudeLike()
        let base = CLIInvocation(prompt: "hi", outputDirectory: "/o", workingDirectory: "/w", model: "haiku", access: .readOnly, schema: #"{"type":"object"}"#, sessionID: "s-1")
        XCTAssertEqual(try tool.invocation(base), ["-p", "hi", "--output-format", "stream-json", "--verbose", "--session-id", "s-1", "--permission-mode", "plan", "--model", "haiku", "--json-schema", #"{"type":"object"}"#])
        XCTAssertTrue(tool.assignsSessionID); XCTAssertTrue(tool.managesAccess); XCTAssertTrue(tool.bypassWarnings.isEmpty)
        tool.editArguments = []
        XCTAssertFalse(tool.supports(.edit)); XCTAssertTrue(tool.supports(.readOnly))
        var edit = base; edit.access = .edit
        XCTAssertThrowsError(try tool.invocation(edit)) { XCTAssertEqual($0 as? CLIError, .accessUnsupported(.edit)) }
        let unmanaged = ToolConfig(name: "printf", executable: "/usr/bin/printf", arguments: ["%s", "{input}"])
        XCTAssertFalse(unmanaged.managesAccess); XCTAssertTrue(unmanaged.supports(.edit)); XCTAssertFalse(unmanaged.assignsSessionID)
        tool.editArguments = ["--permission-mode", "bypassPermissions"]
        XCTAssertEqual(tool.bypassWarnings, ["bypassPermissions"])
    }

    func testInstructionsGoToTemplatePrefixOrNowhere() throws {
        var tool = ToolConfig(name: "x", executable: "/usr/bin/true", arguments: ["{prompt}"])
        let call = CLIInvocation(prompt: "task", instructions: "be brief", outputDirectory: "/o", workingDirectory: "/w")
        XCTAssertEqual(try tool.invocation(call), ["task"], "Legacy CLIs never get instructions injected")
        tool.includeInstructions = true
        XCTAssertEqual(try tool.invocation(call), ["职责：\nbe brief\n\n任务：\ntask"])
        tool.arguments = ["--system", "{instructions}", "{prompt}"]
        XCTAssertEqual(try tool.invocation(call), ["--system", "be brief", "task"])
    }

    func testResumeNeedsTemplateAndSessionAndPromptOnlySchema() throws {
        var tool = ToolConfig(name: "x", executable: "/usr/bin/true", arguments: ["{prompt}"])
        var call = CLIInvocation(prompt: "again", outputDirectory: "/o", workingDirectory: "/w", resume: true)
        XCTAssertThrowsError(try tool.invocation(call)) { XCTAssertEqual($0 as? CLIError, .resumeUnsupported) }
        tool.resumeArguments = ["resume", "{session_id}", "{prompt}"]
        XCTAssertThrowsError(try tool.invocation(call)) { XCTAssertEqual($0 as? CLIError, .missingSession) }
        call.sessionID = "abc"
        XCTAssertEqual(try tool.invocation(call), ["resume", "abc", "again"])
        call.resume = false; call.schema = #"{"type":"object"}"#
        let argv = try tool.invocation(call)
        XCTAssertEqual(argv.count, 1); XCTAssertTrue(argv[0].hasPrefix("again\n\n只返回一个符合以下 JSON Schema")); XCTAssertTrue(argv[0].hasSuffix(#"{"type":"object"}"#))
    }

    func testLegacyCodexAdapterBecomesOrdinaryDefinition() throws {
        var legacy = ToolConfig(name: "Codex", executable: "/usr/bin/true", arguments: []); legacy.adapter = .codex
        let tool = legacy.migratingLegacyAdapter()
        XCTAssertEqual(tool.adapterKind, .command); XCTAssertEqual(tool.format, .jsonLines)
        XCTAssertEqual(tool.authenticationStatusArguments, ["login", "status"])
        let argv = try tool.invocation(CLIInvocation(prompt: "p", instructions: "r", outputDirectory: "/o", workingDirectory: "/w", access: .readOnly, schema: "{}", schemaFile: "/o/s.json"))
        XCTAssertEqual(argv, ["exec", "--json", "--skip-git-repo-check", "--output-last-message", "/o/result.md", "--sandbox", "read-only", "--output-schema", "/o/s.json", "--", "职责：\nr\n\n任务：\np"])
    }

    func testLoginClassificationUsesLoggedOutTextAndKeepsFailuresDistinct() {
        var tool = ToolConfig(name: "cli", executable: "/tool", arguments: [])
        XCTAssertNil(tool.authenticationStatusArguments)
        tool.loginStatusArguments = ["auth", "status"]; tool.loggedOutText = #""loggedIn": false"#
        XCTAssertEqual(tool.authenticationStatusArguments, ["auth", "status"])
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 0, cancelled: false), output: #"{"loggedIn": true}"#).state, .loggedIn)
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false), output: "{\n  \"loggedIn\": false\n}").state, .loggedOut)
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false), output: "network down").state, .failed)
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false, timedOut: true), output: #""loggedIn": false"#).state, .failed)
        tool.loggedOutText = nil
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false), output: "Not logged in").state, .failed)
    }

    func testStreamJSONSplitAcrossChunks() {
        let events = EventLog()
        let collector = CLIOutputCollector(format: .streamJSON) { events.append($0) }
        let lines = [
            #"{"type":"system","subtype":"init","session_id":"sess-1","tools":[]}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}},"session_id":"sess-1"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"},{"type":"tool_use","name":"Edit","input":{"file_path":"/w/a.swift"}}]},"session_id":"sess-1"}"#,
            "not json at all",
            #"{"type":"result","subtype":"success","is_error":false,"result":"Done 中文","session_id":"sess-1","total_cost_usd":0.0123,"usage":{"input_tokens":10,"output_tokens":5},"structured_output":{"ok":true}}"#
        ].joined(separator: "\n")
        let bytes = Array(lines)
        for start in stride(from: 0, to: bytes.count, by: 7) { collector.consume(String(bytes[start..<min(bytes.count, start + 7)])) }
        let summary = collector.finish()
        XCTAssertEqual(summary.sessionID, "sess-1"); XCTAssertEqual(summary.replyText, "Done 中文")
        XCTAssertEqual(summary.usage, CLIUsage(costUSD: 0.0123, inputTokens: 10, outputTokens: 5))
        XCTAssertEqual(summary.activities, [CLIActivity(kind: "Edit", summary: "/w/a.swift")])
        XCTAssertEqual(try XCTUnwrap(summary.structuredJSON).count > 0, true)
        XCTAssertNil(summary.errorMessage)
        XCTAssertTrue(events.items.contains(.textDelta("Hel"))); XCTAssertTrue(events.items.contains(.session("sess-1")))
    }

    func testJSONLinesAndErrors() {
        let collector = CLIOutputCollector(format: .jsonLines)
        collector.consume(#"{"type":"thread.started","thread_id":"th-9"}"# + "\n")
        collector.consume(#"{"type":"item.completed","item":{"id":"1","type":"command_execution","command":"ls -la","status":"completed"}}"# + "\n")
        collector.consume(#"{"type":"item.completed","item":{"id":"2","type":"file_change","changes":[{"path":"a.txt","kind":"add"}]}}"# + "\n")
        collector.consume(#"{"type":"item.completed","item":{"id":"3","type":"agent_message","text":"{\"decision\":\"pass\"}"}}"# + "\n")
        collector.consume(#"{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":4}}"#)
        let summary = collector.finish()
        XCTAssertEqual(summary.sessionID, "th-9"); XCTAssertEqual(summary.replyText, #"{"decision":"pass"}"#)
        XCTAssertEqual(summary.activities.map(\.kind), ["command", "file_change"])
        XCTAssertEqual(summary.usage.outputTokens, 4)
        let failed = CLIOutputCollector(format: .jsonLines); failed.consume(#"{"type":"turn.failed","error":{"message":"quota"}}"#)
        XCTAssertEqual(failed.finish().errorMessage, "quota")
    }

    func testPlainTextAndJSONExtraction() throws {
        let collector = CLIOutputCollector(format: .plainText)
        collector.consume("你好"); collector.consume("\nworld")
        XCTAssertEqual(collector.finish().replyText, "你好\nworld")
        XCTAssertNotNil(CLIOutputCollector.extractJSONObject(from: "Here:\n```json\n{\"a\": 1}\n```\nthanks"))
        XCTAssertNotNil(CLIOutputCollector.extractJSONObject(from: "prefix {\"a\": {\"b\": 2}} suffix"))
        XCTAssertNil(CLIOutputCollector.extractJSONObject(from: "[1, 2]"))
        XCTAssertNil(CLIOutputCollector.extractJSONObject(from: "no json"))
    }

    func testFakeCLIEndToEndThroughProcessRunner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake cli")
        try """
        #!/bin/sh
        printf '{"type":"system","subtype":"init","session_id":"%s"}\\n' "$4"
        printf '{"type":"result","subtype":"success","result":"%s","session_id":"%s"}\\n' "$2" "$4"
        """.write(to: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(script.path, 0o755), 0)
        var tool = ToolConfig(name: "fake", executable: script.path, arguments: ["-p", "{prompt}", "--session-id", "{session_id}"])
        tool.outputFormat = .streamJSON
        let argv = try tool.invocation(CLIInvocation(prompt: "ping;$(id)", outputDirectory: root.path, workingDirectory: root.path, sessionID: "11111111-2222-3333-4444-555555555555"))
        let collector = CLIOutputCollector(format: tool.format)
        let result = try await ProcessRunner().run(id: UUID(), tool: tool, input: "", directory: root.path, arguments: argv, onOutput: { if $0.stream == .stdout { collector.consume($0.text) } })
        let summary = collector.finish()
        XCTAssertEqual(result.status, .review)
        XCTAssertEqual(summary.replyText, "ping;$(id)"); XCTAssertEqual(summary.sessionID, "11111111-2222-3333-4444-555555555555")
    }

    func testLoginShellLookupParsesMarkersAndResolvesRealCommand() async {
        let parsed = LoginShell.parse("noise\n__WB_CMD__/bin/sh\n__WB_PATH__/a:/b\n")
        XCTAssertEqual(parsed, LoginShell.Lookup(executable: "/bin/sh", searchPath: "/a:/b"))
        XCTAssertNil(LoginShell.parse("__WB_CMD__alias ll='ls'\n").executable)
        let lookup = await LoginShell.lookup("sh", shell: "/bin/zsh", interactive: false)
        XCTAssertEqual(lookup.executable, "/bin/sh"); XCTAssertNotNil(lookup.searchPath)
        let missing = await LoginShell.lookup("definitely-not-a-command-\(UUID().uuidString.prefix(6))", shell: "/bin/zsh", interactive: false)
        XCTAssertNil(missing.executable)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CLIEvent] = []
    func append(_ event: CLIEvent) { lock.lock(); values.append(event); lock.unlock() }
    var items: [CLIEvent] { lock.lock(); defer { lock.unlock() }; return values }
}
