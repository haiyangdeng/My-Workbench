import XCTest
@testable import WorkbenchCore

final class ReviewEvidenceTests: XCTestCase {
    func testEvidenceIncludesOwnedUTF8TextAndFlagsTruncationAndMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = RunArchive(root: root)
        let employee = Employee(name: "test", role: "test", department: "设计部", instructions: "", toolID: UUID())
        let task = WorkTask(title: "test", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "检查")
        let id = UUID(), directory = try archive.prepare(runID: id, projectID: nil)
        let run = TaskRun(id: id, task: task, employee: employee, tool: ToolConfig(name: "tool", executable: "/usr/bin/printf", arguments: []), directory: directory)
        let output = URL(fileURLWithPath: run.outputDirectory)
        try Data("中文正文🙂".utf8).write(to: output.appendingPathComponent("brief.md"))
        try Data(String(repeating: "中文", count: 30000).utf8).write(to: output.appendingPathComponent("long.md"))
        try Data([0, 1, 2]).write(to: output.appendingPathComponent("movie.mp4"))
        let items = try archive.artifacts(for: run)
        let evidence = try ReviewEvidence.text(artifacts: items, archive: archive)
        XCTAssertTrue(evidence.contains("中文正文🙂")); XCTAssertTrue(evidence.contains("已截断")); XCTAssertTrue(evidence.contains("返回blocked")); XCTAssertFalse(evidence.contains("�"))
        XCTAssertLessThan(evidence.utf8.count, 23000)
        var wrong = items[0]; wrong.runID = UUID(); XCTAssertThrowsError(try ReviewEvidence.text(artifacts: [wrong], archive: archive))
    }
    func testNullArgumentIsRejectedRatherThanSilentlyTruncated() async {
        do {
            _ = try await ProcessRunner().run(id: UUID(), tool: ToolConfig(name: "printf", executable: "/usr/bin/printf", arguments: ["%s", "{input}"]), input: "a\0b", directory: "/tmp", onOutput: { _ in })
            XCTFail("Expected invalid argument")
        } catch { XCTAssertEqual(error.localizedDescription, WorkbenchError.invalidArguments.localizedDescription) }
    }
    func testTimeoutUsesFiniteBounds() {
        var tool = ToolConfig(name: "tool", executable: "/usr/bin/printf", arguments: [])
        tool.timeoutSeconds = .infinity; XCTAssertEqual(tool.timeout, 1800)
        tool.timeoutSeconds = -10; XCTAssertEqual(tool.timeout, 0.1)
        tool.timeoutSeconds = 1e20; XCTAssertEqual(tool.timeout, 86400)
    }
}
