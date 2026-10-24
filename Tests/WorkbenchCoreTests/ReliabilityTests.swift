import XCTest
@testable import WorkbenchCore

/// Fixes from the 2026-10-24 test pass (docs/TEST_REPORT_2026-10-24.md).
final class ReliabilityTests: XCTestCase {
    // B1: zero or a negative number is an input mistake, never "no limit".
    func testBudgetCapsMustBePositiveAndRequiredForGenerateSteps() throws {
        XCTAssertThrowsError(try BudgetCap.parse(minutes: "0", cost: "", hasGenerateSteps: true)) { XCTAssertEqual($0 as? BudgetCap.Problem, .notPositive) }
        XCTAssertThrowsError(try BudgetCap.parse(minutes: "", cost: "-3", hasGenerateSteps: true)) { XCTAssertEqual($0 as? BudgetCap.Problem, .notPositive) }
        XCTAssertThrowsError(try BudgetCap.parse(minutes: "ten", cost: "", hasGenerateSteps: true)) { XCTAssertEqual($0 as? BudgetCap.Problem, .notANumber) }
        XCTAssertThrowsError(try BudgetCap.parse(minutes: "", cost: "", hasGenerateSteps: true)) { XCTAssertEqual($0 as? BudgetCap.Problem, .missing) }
        XCTAssertThrowsError(try BudgetCap.validate(minutes: .infinity, cost: nil, hasGenerateSteps: false))
        let caps = try BudgetCap.parse(minutes: " 12 ", cost: "", hasGenerateSteps: true)
        XCTAssertEqual(caps.minutes, 12); XCTAssertNil(caps.cost)
        XCTAssertNoThrow(try BudgetCap.validate(minutes: nil, cost: nil, hasGenerateSteps: false))
    }

    // B3: Codex reports connection retries as `error` events, then completes the turn.
    func testRecoveredErrorsDoNotFailACompletedTurn() {
        let recovered = CLIOutputCollector(format: .jsonLines)
        recovered.consume(#"{"type":"error","message":"Reconnecting... 5/5 (request timed out)"}"# + "\n")
        recovered.consume(#"{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}"# + "\n")
        recovered.consume(#"{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":1}}"# + "\n")
        let summary = recovered.finish()
        XCTAssertNil(summary.errorMessage); XCTAssertEqual(summary.replyText, "ok")
        XCTAssertEqual(summary.recoveredErrors, ["Reconnecting... 5/5 (request timed out)"])

        let failed = CLIOutputCollector(format: .jsonLines)
        failed.consume(#"{"type":"error","message":"Reconnecting... 1/5"}"# + "\n")
        failed.consume(#"{"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized"}}"# + "\n")
        XCTAssertEqual(failed.finish().errorMessage, "unexpected status 401 Unauthorized")
    }

    // B4: a file the user had already modified keeps " M" when an agent edits it further.
    func testChangedFilesCatchFurtherEditsToAlreadyModifiedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "user line\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: root.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let status = ["notes.txt": " M", "other.txt": " M"]
        let before = GitRepository.fingerprints(directory: root.path, files: status.keys)
        try "user line\nagent line\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let after = GitRepository.fingerprints(directory: root.path, files: status.keys)
        XCTAssertEqual(GitRepository.changedFiles(before: status, after: status, beforeContent: before, afterContent: after), ["notes.txt"])
        XCTAssertEqual(GitRepository.changedFiles(before: status, after: status), [], "Status alone cannot see the edit")
        XCTAssertEqual(GitRepository.changedFiles(before: [:], after: ["new.txt": "??"]), ["new.txt"])
    }

    // B9: an app opened from Finder has no HTTPS_PROXY; the system proxy is passed on unless the user set their own.
    func testSystemProxyBecomesProxyVariablesWithLocalBypass() {
        let settings: [String: Any] = ["HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "127.0.0.1", "HTTPSPort": NSNumber(value: 7890),
                                       "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "127.0.0.1", "HTTPPort": NSNumber(value: 7890),
                                       "SOCKSEnable": NSNumber(value: 0), "ExceptionsList": ["*.local", "169.254/16"]]
        let variables = SystemProxy.environment(settings: settings, inherited: [:])
        XCTAssertEqual(variables["HTTPS_PROXY"], "http://127.0.0.1:7890"); XCTAssertEqual(variables["http_proxy"], "http://127.0.0.1:7890")
        XCTAssertNil(variables["ALL_PROXY"])
        XCTAssertEqual(variables["NO_PROXY"], "localhost,127.0.0.1,::1,*.local,169.254/16")
        XCTAssertEqual(SystemProxy.environment(settings: settings, inherited: ["https_proxy": "http://10.0.0.1:3128"]), [:], "The user's own proxy wins")
        XCTAssertEqual(SystemProxy.environment(settings: ["HTTPSEnable": NSNumber(value: 0)], inherited: [:]), [:])
        XCTAssertEqual(SystemProxy.summary(settings: settings), "HTTPS 127.0.0.1:7890 · HTTP 127.0.0.1:7890")
    }

    func testEnvironmentLinesAreValidatedAndReservedNamesRefused() throws {
        let parsed = try ToolConfig.parseEnvironment("ANTHROPIC_BASE_URL=https://relay.example/v1\n\n  HTTPS_PROXY = http://127.0.0.1:7890 \nEMPTY=\nTOKEN=a=b")
        XCTAssertEqual(parsed.map(\.name), ["ANTHROPIC_BASE_URL", "HTTPS_PROXY", "EMPTY", "TOKEN"])
        XCTAssertEqual(parsed[1].value, " http://127.0.0.1:7890"); XCTAssertEqual(parsed[3].value, "a=b")
        XCTAssertThrowsError(try ToolConfig.parseEnvironment("NO_EQUALS")) { XCTAssertEqual($0 as? CLIEnvironmentError, .invalidLine("NO_EQUALS")) }
        XCTAssertThrowsError(try ToolConfig.parseEnvironment("1BAD=x")) { XCTAssertEqual($0 as? CLIEnvironmentError, .invalidName("1BAD")) }
        XCTAssertThrowsError(try ToolConfig.parseEnvironment("BAD-NAME=x")) { XCTAssertEqual($0 as? CLIEnvironmentError, .invalidName("BAD-NAME")) }
        XCTAssertThrowsError(try ToolConfig.parseEnvironment("MYWORKBENCH_RUN_ID=x")) { XCTAssertEqual($0 as? CLIEnvironmentError, .reserved("MYWORKBENCH_RUN_ID")) }
        XCTAssertThrowsError(try ToolConfig.parseEnvironment("A=1\nA=2")) { XCTAssertEqual($0 as? CLIEnvironmentError, .duplicate("A")) }
    }

    /// Exported definitions carry variable names and plain values, never secret values (those live only in the Keychain).
    func testExportKeepsPlainVariablesAndSecretNamesOnly() throws {
        var tool = ToolConfig(name: "Claude Code", executable: "/usr/local/bin/claude", arguments: ["-p", "{prompt}"])
        tool.environment = ["ANTHROPIC_BASE_URL": "https://relay.example/v1"]; tool.secretEnvironmentNames = ["ANTHROPIC_AUTH_TOKEN"]; tool.useSystemProxy = false
        let data = try CLIDefinitionFile(tool: tool).encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("ANTHROPIC_AUTH_TOKEN")); XCTAssertFalse(text.contains("sk-"))
        let loaded = try CLIDefinitionFile.load(data)
        XCTAssertEqual(loaded.environment, tool.environment); XCTAssertEqual(loaded.secretEnvironmentNames, ["ANTHROPIC_AUTH_TOKEN"]); XCTAssertEqual(loaded.useSystemProxy, false)
        XCTAssertNotEqual(loaded.id, tool.id)
    }

    // B8: a usage limit gets its own message with the CLI's retry time.
    func testUsageLimitIsExplainedWithRetryTime() {
        var summary = CLIOutputSummary()
        summary.errorMessage = "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro) or try again at 12:13 PM."
        let tool = ToolConfig(name: "Codex", executable: "/usr/local/bin/codex", arguments: [])
        let message = TurnDiagnosis.explain(status: .failed, exitCode: 1, summary: summary, tool: tool, outputTail: "") ?? ""
        XCTAssertTrue(message.contains("用量额度"), message); XCTAssertTrue(message.contains("try again at 12:13 PM"), message)
        summary.errorMessage = "Not logged in"
        XCTAssertTrue(TurnDiagnosis.explain(status: .failed, exitCode: 1, summary: summary, tool: tool, outputTail: "")?.contains("没有登录") == true)
    }

    func testProcessTreeFindsDescendantsAndIgnoresReusedPIDs() throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", "/bin/sleep 5 & wait"]
        try process.run(); defer { process.terminate() }
        var children: Set<ProcessTree.Entry> = []
        for _ in 0..<100 where children.isEmpty { children = ProcessTree.descendants(of: process.processIdentifier); usleep(20_000) }
        XCTAssertEqual(children.count, 1)
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(ProcessTree.alive(children).count, 1)
        XCTAssertTrue(ProcessTree.alive([ProcessTree.Entry(pid: child.pid, started: child.started + 1)]).isEmpty, "Same PID with another start time is not the recorded process")
        ProcessTree.signal(children, SIGKILL)
        for _ in 0..<100 where !ProcessTree.alive(children).isEmpty { usleep(20_000) }
        XCTAssertTrue(ProcessTree.alive(children).isEmpty)
    }
}
