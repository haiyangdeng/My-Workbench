import XCTest
import SQLite3
@testable import WorkbenchCore

final class ProjectCategoryTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }

    func testCategoryValidationOrderingAndDeleteMovesProjects() throws {
        var snapshot = WorkspaceSnapshot()
        let client = ProjectCategory(name: "Client", sortIndex: 0), channel = ProjectCategory(name: "Channel", sortIndex: 1)
        snapshot.categories = [client, channel]
        XCTAssertThrowsError(try snapshot.validate(ProjectCategory(name: " Client ")))
        XCTAssertThrowsError(try snapshot.validate(ProjectCategory(name: ProjectCategory.uncategorizedName)))
        XCTAssertThrowsError(try snapshot.validate(ProjectCategory(name: String(repeating: "长", count: 41))))
        XCTAssertThrowsError(try snapshot.validate(ProjectCategory(name: "ok", color: "zzzzzz")))
        XCTAssertNoThrow(try snapshot.validate(client))
        snapshot.moveCategory(channel.id, by: -1)
        XCTAssertEqual(snapshot.sortedCategories.map(\.name), ["Channel", "Client"])
        var project = WorkProject(name: "A", directory: "/tmp"); project.categoryID = client.id
        let run = TaskRun(task: WorkTask(title: "t", employeeID: UUID(), input: "", workingDirectory: "/tmp", acceptance: "a"), employee: Employee(name: "e", role: "r", department: "d", instructions: "", toolID: UUID()), tool: ToolConfig(name: "t", executable: "/usr/bin/true", arguments: []), directory: URL(fileURLWithPath: "/tmp/x"))
        snapshot.projects = [project]; snapshot.runs = [run]
        snapshot.deleteCategory(client.id)
        XCTAssertNil(snapshot.projects[0].categoryID); XCTAssertEqual(snapshot.projects[0].id, project.id)
        XCTAssertEqual(snapshot.runs, [run]); XCTAssertEqual(snapshot.sortedCategories.map(\.sortIndex), [0])
    }

    func testFilterByCategoryModuleStatusTextAndSort() {
        var snapshot = WorkspaceSnapshot()
        let category = ProjectCategory(name: "Channel"); snapshot.categories = [category]
        let video = WorkArea.defaults[0].id, code = WorkArea.defaults[2].id
        var a = WorkProject(name: "Beta video", directory: "/tmp"); a.categoryID = category.id; a.moduleIDs = [video]; a.createdAt = Date(timeIntervalSince1970: 10)
        var b = WorkProject(name: "Alpha app", directory: "/tmp", goal: "ship"); b.moduleIDs = [code]; b.createdAt = Date(timeIntervalSince1970: 20)
        var c = WorkProject(name: "Old", directory: "/tmp"); c.categoryID = UUID(); c.archivedAt = Date()
        snapshot.projects = [a, b, c]
        var task = WorkTask(title: "t", employeeID: UUID(), input: "", workingDirectory: "/tmp", acceptance: "x"); task.projectID = a.id; task.createdAt = Date(timeIntervalSince1970: 99)
        snapshot.tasks = [task]
        var filter = ProjectFilter()
        XCTAssertEqual(snapshot.projects(matching: filter).map(\.name), ["Beta video", "Alpha app"], "Most recent activity first; archived hidden")
        filter.sort = .name; XCTAssertEqual(snapshot.projects(matching: filter).map(\.name), ["Alpha app", "Beta video"])
        filter.category = .id(category.id); XCTAssertEqual(snapshot.projects(matching: filter).map(\.name), ["Beta video"])
        filter.category = .uncategorized; filter.status = .all
        XCTAssertEqual(Set(snapshot.projects(matching: filter).map(\.name)), ["Alpha app", "Old"], "A dangling category counts as Uncategorized")
        filter = ProjectFilter(); filter.moduleID = video; XCTAssertEqual(snapshot.projects(matching: filter).map(\.name), ["Beta video"])
        filter = ProjectFilter(); filter.text = "SHIP"; XCTAssertEqual(snapshot.projects(matching: filter).map(\.name), ["Alpha app"])
        filter = ProjectFilter(); filter.status = .archived; XCTAssertEqual(snapshot.projects(matching: filter).map(\.name), ["Old"])
    }

    func testV3DatabaseMigratesToV4OnceWithReadableBackup() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.sqlite")
        var legacy = ToolConfig(name: "Codex", executable: "/usr/bin/true", arguments: []); legacy.adapter = .codex; legacy.codexWorkspaceWrite = true
        let printf = ToolConfig(name: "printf", executable: "/usr/bin/printf", arguments: ["%s", "{input}"])
        var coder = Employee(name: "Coder", role: "dev", department: "声音工作区", instructions: "", toolID: legacy.id); coder.workspaceID = WorkArea.defaults[1].id
        let echo = Employee(name: "Echo", role: "dev", department: "开发部", instructions: "", toolID: printf.id)
        let project = WorkProject(name: "P", directory: "/tmp"), empty = WorkProject(name: "Empty", directory: "/tmp")
        var task = WorkTask(title: "t", employeeID: coder.id, input: "", workingDirectory: "/tmp", acceptance: "a"); task.projectID = project.id
        var v3 = WorkspaceSnapshot(); v3.tools = [legacy, printf]; v3.employees = [coder, echo]; v3.projects = [project, empty]; v3.tasks = [task]
        try WorkspacePersistence(fileURL: url).save(v3)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=3", nil, nil, nil), SQLITE_OK); sqlite3_close(db)

        let loaded = try WorkspacePersistence(fileURL: url).load()
        XCTAssertEqual(loaded.schemaVersion, 4)
        let tool = try XCTUnwrap(loaded.tools.first { $0.id == legacy.id })
        XCTAssertEqual(tool.adapterKind, .command); XCTAssertEqual(tool.format, .jsonLines); XCTAssertTrue(tool.supports(.edit))
        XCTAssertEqual(loaded.tools.first { $0.id == printf.id }, printf, "Generic CLIs keep their exact definition")
        XCTAssertEqual(loaded.employees.first { $0.id == coder.id }?.maxAccess, .edit)
        XCTAssertNil(loaded.employees.first { $0.id == echo.id }?.maxAccess)
        XCTAssertEqual(loaded.projects.first { $0.id == project.id }?.moduleIDs, [WorkArea.defaults[1].id])
        XCTAssertEqual(loaded.projects.first { $0.id == empty.id }?.moduleIDs, [WorkArea.defaults[2].id])
        XCTAssertNil(loaded.projects[0].categoryID); XCTAssertEqual(loaded.tasks.map(\.id), [task.id])

        let backup = root.appendingPathComponent("workspace.pre-v06.sqlite")
        XCTAssertEqual(sqlite3_open_v2(backup.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(statement, 0), 3); sqlite3_finalize(statement); sqlite3_close(db)
        let bytes = try Data(contentsOf: backup)
        var edited = try WorkspacePersistence(fileURL: url).load(); edited.categories = [ProjectCategory(name: "Client")]
        try WorkspacePersistence(fileURL: url).save(edited)
        XCTAssertEqual(try WorkspacePersistence(fileURL: url).load().categories.map(\.name), ["Client"])
        XCTAssertEqual(try Data(contentsOf: backup), bytes, "The backup is written once and never replaced")
    }

    func testFutureSchemaIsRefusedAndPreserved() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.sqlite")
        try WorkspacePersistence(fileURL: url).save(WorkspaceSnapshot())
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=5", nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        XCTAssertThrowsError(try WorkspacePersistence(fileURL: url).load())
    }
}
