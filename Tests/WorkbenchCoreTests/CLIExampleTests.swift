import XCTest
@testable import WorkbenchCore

/// The Appendix A definitions in docs/cli-examples import cleanly and produce the documented command lines.
final class CLIExampleTests: XCTestCase {
    private func example(_ name: String) throws -> ToolConfig {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/cli-examples/\(name).json")
        return try CLIDefinitionFile.load(try Data(contentsOf: url))
    }

    func testClaudeCodeDefinitionCoversEveryMode() throws {
        let claude = try example("claude-code")
        XCTAssertEqual(claude.format, .streamJSON); XCTAssertTrue(claude.isCLI); XCTAssertTrue(claude.assignsSessionID)
        XCTAssertTrue(claude.supports(.readOnly) && claude.supports(.edit)); XCTAssertTrue(claude.supportsResume && claude.supportsTerminalResume)
        XCTAssertTrue(claude.bypassWarnings.isEmpty); XCTAssertTrue(claude.usesInstructionsPlaceholder)
        XCTAssertEqual(claude.authenticationStatusArguments, ["auth", "status"]); XCTAssertEqual(claude.authenticationLoginArguments, ["auth", "login"])

        let first = try claude.invocation(CLIInvocation(prompt: "Fix the parser; don't touch $(HOME)", instructions: "Be careful.", outputDirectory: "/out", workingDirectory: "/repo", access: .readOnly, sessionID: "s-1"))
        XCTAssertEqual(first, ["-p", "Fix the parser; don't touch $(HOME)", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--session-id", "s-1",
                               "--append-system-prompt", "Be careful.", "--permission-mode", "plan"])
        let resumed = try claude.invocation(CLIInvocation(prompt: "Continue", instructions: "Be careful.", outputDirectory: "/out", workingDirectory: "/repo", model: "opus", access: .edit, schema: #"{"type":"object"}"#, sessionID: "s-1", resume: true))
        XCTAssertEqual(resumed, ["-p", "Continue", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--resume", "s-1",
                                 "--append-system-prompt", "Be careful.", "--permission-mode", "acceptEdits", "--model", "opus", "--json-schema", #"{"type":"object"}"#])
        XCTAssertEqual(claude.terminalResumeArguments(sessionID: "s-1"), ["--resume", "s-1"])
        let loggedOut = LoginCheck.classify(tool: claude, result: ProcessResult(exitCode: 1, cancelled: false), output: "{\n  \"loggedIn\": false,\n  \"authMethod\": \"none\"\n}")
        XCTAssertEqual(loggedOut.state, .loggedOut)
        XCTAssertEqual(LoginCheck.classify(tool: claude, result: ProcessResult(exitCode: 0, cancelled: false), output: "{\"loggedIn\": true}").state, .loggedIn)
    }

    func testCodexDefinitionCoversEveryMode() throws {
        let codex = try example("codex")
        XCTAssertEqual(codex.format, .jsonLines); XCTAssertFalse(codex.assignsSessionID, "Codex reports its own thread ID")
        XCTAssertTrue(codex.supports(.readOnly) && codex.supports(.edit)); XCTAssertTrue(codex.bypassWarnings.isEmpty)
        let first = try codex.invocation(CLIInvocation(prompt: "Read README.md", outputDirectory: "/out", workingDirectory: "/repo", access: .readOnly))
        XCTAssertEqual(first, ["exec", "--sandbox", "read-only", "--json", "--skip-git-repo-check", "--", "Read README.md"])
        let resumed = try codex.invocation(CLIInvocation(prompt: "Edit it", outputDirectory: "/out", workingDirectory: "/repo", model: "gpt-5", access: .edit, schema: "{}", schemaFile: "/out/schema.json", sessionID: "thread-9", resume: true))
        XCTAssertEqual(resumed, ["exec", "--sandbox", "workspace-write", "--add-dir", "/out", "--model", "gpt-5", "--output-schema", "/out/schema.json",
                                 "resume", "--json", "--skip-git-repo-check", "--", "thread-9", "Edit it"])
        XCTAssertEqual(codex.terminalResumeArguments(sessionID: "thread-9"), ["--sandbox", "read-only", "resume", "thread-9"])
        XCTAssertEqual(LoginCheck.classify(tool: codex, result: ProcessResult(exitCode: 1, cancelled: false), output: "Not logged in").state, .loggedOut)
        XCTAssertEqual(LoginCheck.classify(tool: codex, result: ProcessResult(exitCode: 0, cancelled: false), output: "Logged in using ChatGPT").state, .loggedIn)
    }
}
