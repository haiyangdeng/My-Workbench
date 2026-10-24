import XCTest
import Darwin
@testable import WorkbenchCore

final class ExecutionTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workbench-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func testCancelStopsTermResistantParentAndChild() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let runner = ProcessRunner(), id = UUID()
        let script = "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do /bin/sleep 0.1; done' & echo $! > child.pid; wait"
        let job = Task { try await runner.run(id: id, tool: ToolConfig(name: "child", executable: "/bin/sh", arguments: ["-c", script]), input: "", directory: root.path, onOutput: { _ in }) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(nanoseconds: 10_000_000) }
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), 0)
        runner.cancel(id: id)
        let result = try await job.value
        XCTAssertEqual(result.status, .cancelled)
        for _ in 0..<100 where kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(kill(child, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    /// Codex runs each shell command in a new process group, so killing the CLI's group alone leaves it running.
    func testCancelStopsChildInItsOwnProcessGroup() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let runner = ProcessRunner(), id = UUID()
        let script = "/usr/bin/perl -e 'setpgrp(0, 0); sleep 60' & echo $! > child.pid; wait"
        let job = Task { try await runner.run(id: id, tool: ToolConfig(name: "own group", executable: "/bin/sh", arguments: ["-c", script]), input: "", directory: root.path, onOutput: { _ in }) }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidFile.path) { try await Task.sleep(nanoseconds: 10_000_000) }
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<100 where getpgid(child) != child { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(getpgid(child), child, "The child leads its own process group, as Codex's commands do")
        runner.cancel(id: id)
        let result = try await job.value
        XCTAssertEqual(result.status, .cancelled)
        for _ in 0..<150 where kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(kill(child, 0), -1, "Stop must reach a command the CLI started in another process group")
    }
    /// A CLI that exits normally must not leave a command it started behind (holding the output pipe or running on).
    func testNormalExitStopsOrphanedChildInItsOwnGroup() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let script = "/usr/bin/perl -e 'setpgrp(0, 0); sleep 60' & echo $! > child.pid; /bin/sleep 1.6; exit 0"
        let started = Date()
        let result = try await ProcessRunner().run(id: UUID(), tool: ToolConfig(name: "orphan", executable: "/bin/sh", arguments: ["-c", script]), input: "", directory: root.path, onOutput: { _ in })
        XCTAssertEqual(result.status, .review)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "The run must not wait for the orphan to exit on its own")
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<150 where kill(child, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(kill(child, 0), -1)
    }
    func testTimeoutEscalatesAndPreservesOutput() async throws {
        var tool = ToolConfig(name: "timeout", executable: "/bin/sh", arguments: ["-c", "trap '' TERM; printf 'before timeout'; while :; do sleep 1; done"])
        tool.timeoutSeconds = 0.1
        let started = Date()
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let log = try RunLog(url: root.appendingPathComponent("log"))
        let result = try await ProcessRunner().run(id: UUID(), tool: tool, input: "", directory: root.path, onOutput: { log.append($0) })
        try log.close()
        XCTAssertEqual(result.status, .timedOut); XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("log"), encoding: .utf8).contains("before timeout"))
    }
    func testHundredThousandLinesStayOnDiskWithBoundedMemory() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("log"), log = try RunLog(url: root.appendingPathComponent("log"))
        let tool = ToolConfig(name: "logs", executable: "/usr/bin/awk", arguments: ["BEGIN {for(i=0;i<100000;i++) print i \" 中文日志\"}"])
        let result = try await ProcessRunner().run(id: UUID(), tool: tool, input: "", directory: root.path, onOutput: { log.append($0) })
        let tail = log.drain(); try log.close()
        let full = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(result.status, .review); XCTAssertEqual(full.filter { $0 == "\n" }.count, 100000)
        XCTAssertTrue(full.contains("99999 中文日志")); XCTAssertFalse(full.contains("�"))
        XCTAssertLessThan(tail.utf8.count, 150000); XCTAssertTrue(tail.contains("99999 中文日志"))
    }
    func testSQLiteMigrationKeepsBackupAndDoesNotReimport() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("workspace.json"), database = WorkspacePersistence(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var initial = WorkspaceSnapshot(); initial.schemaVersion = 1
        initial.employees = [Employee(name: "旧员工", role: "开发", department: "开发部", instructions: "", toolID: UUID())]
        try WorkspacePersistence(fileURL: legacy).save(initial)
        let oldBytes = try Data(contentsOf: legacy)
        try database.migrateLegacyJSON(from: legacy)
        initial.migrateWorkspaces()
        XCTAssertEqual(try database.load().employees, initial.employees)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.pre-sqlite-backup.json")), oldBytes)
        var next = try database.load(); next.employees[0].name = "已编辑"; try database.save(next)
        try database.migrateLegacyJSON(from: legacy)
        XCTAssertEqual(try database.load().employees[0].name, "已编辑")
        XCTAssertEqual(try Data(contentsOf: legacy), oldBytes)
    }
    func testSQLiteFailedTransactionPreservesEarlierSnapshot() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let db = WorkspacePersistence(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var snapshot = WorkspaceSnapshot(); let tool = ToolConfig(name: "original", executable: "/usr/bin/printf", arguments: [])
        snapshot.tools = [tool]; try db.save(snapshot)
        snapshot.tools.append(tool)
        XCTAssertThrowsError(try db.save(snapshot))
        XCTAssertEqual(try db.load().tools, [tool])
    }
    func testArtifactIsolationAndNoOverwriteOnRetry() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = RunArchive(root: root.appendingPathComponent("archive"))
        let employee = Employee(name: "test", role: "test", department: "开发部", instructions: "", toolID: UUID())
        let tool = ToolConfig(name: "printf", executable: "/usr/bin/printf", arguments: [])
        var task = WorkTask(title: "task", employeeID: employee.id, input: "", workingDirectory: root.path, acceptance: "check")
        task.projectID = UUID()
        let firstID = UUID(), secondID = UUID()
        let first = TaskRun(id: firstID, task: task, employee: employee, tool: tool, directory: try archive.prepare(runID: firstID, projectID: task.projectID))
        let second = TaskRun(id: secondID, task: task, employee: employee, tool: tool, directory: try archive.prepare(runID: secondID, projectID: task.projectID), feedback: "改进")
        try Data("old".utf8).write(to: URL(fileURLWithPath: first.outputDirectory).appendingPathComponent("result.txt"))
        try Data("new".utf8).write(to: URL(fileURLWithPath: second.outputDirectory).appendingPathComponent("result.txt"))
        let artifacts = try archive.artifacts(for: first)
        XCTAssertEqual(artifacts.count, 1); XCTAssertEqual(try String(contentsOf: archive.url(for: artifacts[0]), encoding: .utf8), "old")
        XCTAssertNotEqual(first.id, second.id); XCTAssertNotEqual(first.outputDirectory, second.outputDirectory)
        XCTAssertThrowsError(try archive.prepare(runID: firstID, projectID: task.projectID))
        var wrong = artifacts[0]; wrong.projectID = UUID(); XCTAssertThrowsError(try archive.url(for: wrong))
        let link = URL(fileURLWithPath: first.outputDirectory).appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertEqual(try archive.artifacts(for: first).count, 1)
    }
    func testUnstartedQueueDoesNotBecomeALegacyExecution() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var workspace = WorkspaceSnapshot()
        let tool = ToolConfig(name: "tool", executable: "/usr/bin/printf", arguments: [])
        let employee = Employee(name: "员工", role: "开发", department: "开发部", instructions: "", toolID: tool.id)
        var task = WorkTask(title: "未启动", employeeID: employee.id, input: "", workingDirectory: root.path, acceptance: "检查")
        task.status = .queued; workspace.tasks = [task]; workspace.tools = [tool]; workspace.employees = [employee]
        workspace.recoverInterruptedTasks()
        try workspace.migrateLegacyRuns(archive: RunArchive(root: root.appendingPathComponent("archive")))
        XCTAssertEqual(workspace.tasks[0].status, .interrupted); XCTAssertTrue(workspace.runs.isEmpty)
    }
    func testLegacyRunMigrationRetainsLogAndIsIdempotent() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = RunArchive(root: root.appendingPathComponent("archive"))
        var workspace = WorkspaceSnapshot()
        let tool = ToolConfig(name: "tool", executable: "/usr/bin/printf", arguments: [])
        let employee = Employee(name: "旧员工", role: "开发", department: "开发部", instructions: "", toolID: tool.id)
        var task = WorkTask(title: "旧结果", employeeID: employee.id, input: "输入", workingDirectory: root.path, acceptance: "检查")
        task.status = .review; task.log = "旧日志中文"; task.exitCode = 0
        workspace.tasks = [task]; workspace.tools = [tool]; workspace.employees = [employee]
        try workspace.migrateLegacyRuns(archive: archive)
        XCTAssertEqual(workspace.runs.count, 1); XCTAssertEqual(workspace.runs[0].status, .review)
        XCTAssertTrue(try String(contentsOf: URL(fileURLWithPath: workspace.runs[0].logPath), encoding: .utf8).contains("旧日志中文"))
        try workspace.migrateLegacyRuns(archive: archive); XCTAssertEqual(workspace.runs.count, 1)
    }
    func testHandoffRejectsForeignRunAndUnacceptedArtifacts() throws {
        var workspace = WorkspaceSnapshot()
        let tool = ToolConfig(name: "tool", executable: "/usr/bin/printf", arguments: [])
        let employee = Employee(name: "test", role: "test", department: "开发部", instructions: "", toolID: tool.id)
        var task = WorkTask(title: "source", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "checked")
        task.status = .completed; task.projectID = UUID()
        var run = TaskRun(task: task, employee: employee, tool: tool, directory: URL(fileURLWithPath: "/tmp")); run.status = .completed
        var artifact = WorkArtifact(taskID: task.id, runID: run.id, projectID: task.projectID, relativePath: "result.txt", byteCount: 1, fileType: "txt")
        let handoff = WorkHandoff(sourceTaskID: task.id, sourceRunID: run.id, targetEmployeeID: employee.id, projectID: task.projectID, artifactIDs: [artifact.id], goal: "next", acceptance: "check")
        workspace.tasks = [task]; workspace.employees = [employee]; workspace.runs = [run]; workspace.artifacts = [artifact]
        XCTAssertThrowsError(try workspace.validateHandoff(handoff))
        artifact.accepted = true; workspace.artifacts = [artifact]; XCTAssertNoThrow(try workspace.validateHandoff(handoff))
        workspace.artifacts[0].runID = UUID(); XCTAssertThrowsError(try workspace.validateHandoff(handoff))
    }
}
