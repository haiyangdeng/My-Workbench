import XCTest
import SQLite3
@testable import WorkbenchCore

final class WorkspaceV04Tests: XCTestCase {
    func testLegacyMembershipMigrationPreservesSnapshotsAndUnknownDepartment() throws {
        var snapshot = WorkspaceSnapshot()
        let tool = ToolConfig(name: "CLI", executable: "/usr/bin/printf", arguments: [])
        let old = Employee(name: "Nova", role: "开发", department: "开发部", instructions: "", toolID: tool.id)
        let unknown = Employee(name: "Ash", role: "研究", department: "研究部", instructions: "", toolID: tool.id)
        var task = WorkTask(title: "旧任务", employeeID: old.id, input: "", workingDirectory: "/tmp", acceptance: "")
        task.employeeSnapshot = old
        snapshot.employees = [old, unknown]; snapshot.tasks = [task]
        snapshot.migrateWorkspaces()
        XCTAssertEqual(snapshot.workspaces.count, 5)
        XCTAssertEqual(snapshot.employees[0].workspaceID, WorkArea.defaults[2].id)
        XCTAssertEqual(snapshot.employees[1].department, "研究部")
        XCTAssertEqual(snapshot.tasks[0], task)
        let once = snapshot; snapshot.migrateWorkspaces(); XCTAssertEqual(snapshot, once)
    }

    func testCustomAreasRenameAndReloadKeepEmployeeTaskAndHistoricalIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = WorkspacePersistence(fileURL: root.appendingPathComponent("workspace.sqlite"))
        var snapshot = WorkspaceSnapshot()
        let fifth = WorkArea(name: "研究工作区", icon: "book", color: "B79758", sortIndex: 4)
        let sixth = WorkArea(name: "运营工作区", icon: "megaphone", color: "9A7B83", sortIndex: 5)
        snapshot.workspaces += [fifth, sixth]
        var employee = Employee(name: "Quinn", role: "研究", department: fifth.name, instructions: "", toolID: UUID())
        employee.workspaceID = fifth.id; snapshot.employees = [employee]
        var task = WorkTask(title: "独立任务", employeeID: employee.id, input: "", workingDirectory: "/tmp", acceptance: "")
        task.employeeSnapshot = employee; snapshot.tasks = [task]
        var renamed = fifth; renamed.name = "知识工作区"; renamed.icon = "globe"; renamed.color = "658398"
        snapshot.updateWorkspace(renamed); try persistence.save(snapshot)
        let loaded = try persistence.load()
        XCTAssertEqual(loaded.workspaces.count, 6)
        XCTAssertEqual(loaded.workspaces[4], renamed)
        XCTAssertEqual(loaded.employees[0].workspaceID, fifth.id)
        XCTAssertEqual(loaded.employees[0].department, renamed.name)
        XCTAssertEqual(loaded.tasks[0], task)
        XCTAssertEqual(try persistence.load(), loaded)
    }

    func testV02DatabaseGetsUsableBackupBeforeV04Migration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.sqlite")
        let persistence = WorkspacePersistence(fileURL: url)
        var snapshot = WorkspaceSnapshot()
        let employee = Employee(name: "旧员工", role: "开发", department: "开发部", instructions: "", toolID: UUID())
        snapshot.employees = [employee]; try persistence.save(snapshot)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE workspaces; PRAGMA user_version=2", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let loaded = try persistence.load()
        XCTAssertEqual(loaded.employees[0].id, employee.id)
        XCTAssertEqual(loaded.employees[0].workspaceID, WorkArea.defaults[2].id)
        let backup = root.appendingPathComponent("workspace.pre-v04.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(sqlite3_open_v2(backup.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement, 0), 2); sqlite3_finalize(statement)
        let bytes = try Data(contentsOf: backup); _ = try persistence.load(); XCTAssertEqual(try Data(contentsOf: backup), bytes)
    }

    func testLegacyJSONMissingWorkspacesAndWorkspaceIDLoads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var snapshot = WorkspaceSnapshot(); snapshot.schemaVersion = 2
        snapshot.employees = [Employee(name: "旧员工", role: "配音", department: "音频音乐部", instructions: "", toolID: UUID())]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]); json.removeValue(forKey: "workspaces")
        let url = root.appendingPathComponent("workspace.json"); try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try WorkspacePersistence(fileURL: url).load()
        XCTAssertEqual(loaded.schemaVersion, 4); XCTAssertEqual(loaded.workspaces.count, 4)
        XCTAssertEqual(loaded.employees[0].workspaceID, WorkArea.defaults[1].id)
    }

    func testLegacyCodexLoginClassificationKeepsFailureDistinctFromLoggedOut() {
        var tool = ToolConfig(name: "Codex", executable: "/tool", arguments: []); tool.adapter = .codex
        XCTAssertEqual(tool.authenticationStatusArguments, ["login", "status"])
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 0, cancelled: false), output: "Logged in using ChatGPT").state, .loggedIn)
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false), output: "Not logged in\n").state, .loggedOut)
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false), output: "Network failure").state, .failed)
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false, timedOut: true), output: "Not logged in").state, .failed)
        tool.adapter = .command; XCTAssertNil(tool.authenticationStatusArguments)
        tool.loginStatusArguments = ["status"]; XCTAssertEqual(tool.authenticationStatusArguments, ["status"])
        XCTAssertEqual(LoginCheck.classify(tool: tool, result: ProcessResult(exitCode: 1, cancelled: false), output: "Not logged in").state, .failed)
    }
}
