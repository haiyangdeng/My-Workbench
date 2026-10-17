import XCTest
@testable import WorkbenchCore

private final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [LogChunk] = []
    func append(_ chunk: LogChunk) { lock.lock(); chunks.append(chunk); lock.unlock() }
    func text(_ stream: LogChunk.Stream) -> String {
        lock.lock(); defer { lock.unlock() }
        return chunks.filter { $0.stream == stream }.map(\.text).joined()
    }
}

final class WorkbenchCoreTests: XCTestCase {
    func testInputRemainsOneLiteralArgument() async throws {
        let input = "中文 with spaces; $(touch should-not-exist) `echo unsafe`"
        let tool = ToolConfig(name: "printf", executable: "/usr/bin/printf", arguments: ["%s", "{input}"])
        let output = OutputCapture()
        let result = try await ProcessRunner().run(id: UUID(), tool: tool, input: input, directory: "/tmp", onOutput: { output.append($0) })
        XCTAssertEqual(result.status, .review)
        XCTAssertEqual(output.text(.stdout), input)
    }

    func testBothPipesAndNonzeroExit() async throws {
        let tool = ToolConfig(name: "fixture", executable: "/bin/sh", arguments: ["-c", "printf 'out'; printf 'err' >&2; exit 7"])
        let output = OutputCapture()
        let result = try await ProcessRunner().run(id: UUID(), tool: tool, input: "", directory: "/tmp", onOutput: { output.append($0) })
        XCTAssertEqual(result.exitCode, 7); XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(output.text(.stdout), "out"); XCTAssertEqual(output.text(.stderr), "err")
    }

    func testExecutablePathWithSpaces() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workbench fixture \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("tool with spaces")
        try Data("#!/bin/sh\n/usr/bin/printf '%s' \"$1\"\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let output = OutputCapture()
        _ = try await ProcessRunner().run(id: UUID(), tool: ToolConfig(name: "fixture", executable: executable.path, arguments: ["{input}"]), input: "valid", directory: directory.path, onOutput: { output.append($0) })
        XCTAssertEqual(output.text(.stdout), "valid")
    }

    func testInvalidExecutableAndDirectory() async {
        for (executable, directory) in [("missing", "/tmp"), ("/usr/bin/printf", "/missing/workbench")] {
            do {
                _ = try await ProcessRunner().run(id: UUID(), tool: ToolConfig(name: "fixture", executable: executable, arguments: []), input: "", directory: directory, onOutput: { _ in })
                XCTFail("Expected validation failure")
            } catch { XCTAssertTrue(error is WorkbenchError) }
        }
    }

    func testCancelBeforeLaunchDoesNotExecute() async throws {
        let runner = ProcessRunner(); let id = UUID(); runner.cancel(id: id)
        let output = OutputCapture()
        let result = try await runner.run(id: id, tool: ToolConfig(name: "fixture", executable: "/usr/bin/printf", arguments: ["should not run"]), input: "", directory: "/tmp", onOutput: { output.append($0) })
        XCTAssertTrue(result.cancelled); XCTAssertEqual(output.text(.stdout), "")
    }

    func testCancelRunningDirectProcess() async throws {
        let runner = ProcessRunner(); let id = UUID()
        let job = Task { try await runner.run(id: id, tool: ToolConfig(name: "sleep", executable: "/bin/sleep", arguments: ["10"]), input: "", directory: "/tmp", onOutput: { _ in }) }
        try await Task.sleep(nanoseconds: 100_000_000); runner.cancel(id: id)
        let result = try await job.value
        XCTAssertTrue(result.cancelled); XCTAssertEqual(result.status, .cancelled)
    }

    func testSplitUTF8Decoder() {
        let bytes = Data("你好🙂".utf8); var decoder = UTF8StreamDecoder(); var text = ""
        for byte in bytes { text += decoder.append(Data([byte])) }
        text += decoder.append(Data(), final: true)
        XCTAssertEqual(text, "你好🙂")
    }

    func testPersistenceAndInterruptedRecovery() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/workspace.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspacePersistence(fileURL: file)
        var snapshot = WorkspaceSnapshot()
        snapshot.tools = [ToolConfig(name: "fixture", executable: "/usr/bin/printf", arguments: ["%s", "{input}"])]
        var task = WorkTask(title: "fixture", employeeID: UUID(), input: "", workingDirectory: "/tmp", acceptance: "checked")
        task.status = .running; snapshot.tasks = [task]
        try store.save(snapshot)
        let restored = try store.load()
        XCTAssertEqual(restored.tools, snapshot.tools); XCTAssertEqual(restored.tasks[0].status, .interrupted)
    }

    func testCorruptDataIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let badData = Data("broken data".utf8); try badData.write(to: file)
        XCTAssertThrowsError(try WorkspacePersistence(fileURL: file).load())
        XCTAssertEqual(try Data(contentsOf: file), badData)
    }

    func testUnsupportedSchemaIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var snapshot = WorkspaceSnapshot(); snapshot.schemaVersion = 99
        let data = try JSONEncoder().encode(snapshot); try data.write(to: file)
        XCTAssertThrowsError(try WorkspacePersistence(fileURL: file).load())
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testCompletionRequiresReview() throws {
        var task = WorkTask(title: "fixture", employeeID: UUID(), input: "", workingDirectory: "/tmp", acceptance: "checked")
        XCTAssertThrowsError(try task.accept()); task.status = .review
        try task.accept(); XCTAssertEqual(task.status, .completed)
    }

    func testLegacyEmployeeWithoutAvatarFieldsStillLoads() throws {
        let employee = Employee(name: "旧员工", role: "开发", department: "开发部", instructions: "保留档案", toolID: UUID())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(employee)) as? [String: Any])
        object.removeValue(forKey: "avatarSymbol"); object.removeValue(forKey: "avatarImageData")
        let restored = try JSONDecoder().decode(Employee.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.id, employee.id)
        XCTAssertEqual(restored.name, employee.name)
        XCTAssertNil(restored.avatarSymbol); XCTAssertNil(restored.avatarImageData)
    }

    func testMultipleEmployeeAvatarsPersistIndependently() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())/workspace.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let toolID = UUID(), photo = Data([0x89, 0x50, 0x4E, 0x47])
        let first = Employee(name: "工程师", role: "实现", department: "开发部", instructions: "代码", toolID: toolID, avatarSymbol: "cpu")
        let second = Employee(name: "测试员", role: "验证", department: "开发部", instructions: "测试", toolID: toolID, avatarImageData: photo)
        var snapshot = WorkspaceSnapshot(); snapshot.employees = [first, second]
        let persistence = WorkspacePersistence(fileURL: file)
        try persistence.save(snapshot)
        let restored = try persistence.load()
        snapshot.migrateWorkspaces()
        XCTAssertEqual(restored.employees, snapshot.employees)
        XCTAssertNotEqual(restored.employees[0].id, restored.employees[1].id)
        XCTAssertNil(restored.employees[0].avatarImageData)
        XCTAssertEqual(restored.employees[1].avatarImageData, photo)
    }
}
