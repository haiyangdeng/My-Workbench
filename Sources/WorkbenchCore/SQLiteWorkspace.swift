import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteWorkspace {
    let url: URL
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let db else { if let db { sqlite3_close(db) }; throw error(db, code) }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        var versionStatement: OpaquePointer?
        try prepare(db, "PRAGMA user_version", &versionStatement)
        let versionCode = sqlite3_step(versionStatement)
        let version = sqlite3_column_int(versionStatement, 0)
        sqlite3_finalize(versionStatement)
        guard versionCode == SQLITE_ROW else { throw error(db, versionCode) }
        guard version == 0 || version == 2 || version == 3 else { throw WorkbenchError.unsupportedSchema }
        if version == 2 { try backupBeforeMigration(db) }
        try execute(db, "PRAGMA journal_mode=WAL")
        try execute(db, "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
        for table in tables {
            try execute(db, "CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        }
        return try body(db)
    }
    private var tables: [String] { ["tools", "employees", "tasks", "projects", "runs", "artifacts", "handoffs", "plans", "reviews", "workspaces"] }
    private func backupBeforeMigration(_ db: OpaquePointer) throws {
        let backupURL = url.deletingPathExtension().appendingPathExtension("pre-v04.sqlite")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        var target: OpaquePointer?
        let code = sqlite3_open(backupURL.path, &target)
        guard code == SQLITE_OK, let target else { if let target { sqlite3_close(target) }; throw error(db, code) }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", db, "main") else { throw error(target, sqlite3_errcode(target)) }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE && finish == SQLITE_OK else {
            try? FileManager.default.removeItem(at: backupURL)
            throw error(target, finish == SQLITE_OK ? step : finish)
        }
        try execute(target, "PRAGMA journal_mode=DELETE")
    }
    func load() throws -> WorkspaceSnapshot {
        try database { db in
            var snapshot = WorkspaceSnapshot()
            snapshot.tools = try rows(db, "tools"); snapshot.employees = try rows(db, "employees")
            snapshot.tasks = try rows(db, "tasks"); snapshot.projects = try rows(db, "projects")
            snapshot.runs = try rows(db, "runs"); snapshot.artifacts = try rows(db, "artifacts")
            snapshot.handoffs = try rows(db, "handoffs"); snapshot.plans = try rows(db, "plans"); snapshot.reviews = try rows(db, "reviews")
            let areas: [WorkArea] = try rows(db, "workspaces")
            if !areas.isEmpty { snapshot.workspaces = areas }
            snapshot.migrateWorkspaces()
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try replace(db, "workspaces", snapshot.workspaces); try replace(db, "employees", snapshot.employees)
                try execute(db, "PRAGMA user_version=3"); try execute(db, "COMMIT")
            } catch { try? execute(db, "ROLLBACK"); throw error }
            snapshot.recoverInterruptedTasks()
            return snapshot
        }
    }
    func isInitialized() throws -> Bool {
        try database { db in
            var statement: OpaquePointer?; try prepare(db, "SELECT value FROM metadata WHERE key='initialized'", &statement)
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }
    func save(_ snapshot: WorkspaceSnapshot) throws {
        guard snapshot.schemaVersion == 3 else { throw WorkbenchError.unsupportedSchema }
        try database { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                try replace(db, "tools", snapshot.tools); try replace(db, "employees", snapshot.employees)
                try replace(db, "tasks", snapshot.tasks); try replace(db, "projects", snapshot.projects)
                try replace(db, "runs", snapshot.runs); try replace(db, "artifacts", snapshot.artifacts)
                try replace(db, "handoffs", snapshot.handoffs); try replace(db, "plans", snapshot.plans); try replace(db, "reviews", snapshot.reviews)
                try replace(db, "workspaces", snapshot.workspaces); try execute(db, "PRAGMA user_version=3")
                try execute(db, "INSERT OR REPLACE INTO metadata (key,value) VALUES ('initialized',1)")
                try execute(db, "COMMIT")
            } catch { try? execute(db, "ROLLBACK"); throw error }
        }
    }
    private func rows<T: Decodable>(_ db: OpaquePointer, _ table: String) throws -> [T] {
        var statement: OpaquePointer?; try prepare(db, "SELECT payload FROM \(table) ORDER BY rowid", &statement)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw error(db, code) }
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            result.append(try JSONDecoder().decode(T.self, from: data))
        }
        return result
    }
    private func replace<T: Encodable & Identifiable>(_ db: OpaquePointer, _ table: String, _ rows: [T]) throws where T.ID == UUID {
        try execute(db, "DELETE FROM \(table)")
        var statement: OpaquePointer?; try prepare(db, "INSERT INTO \(table) (id,payload) VALUES (?,?)", &statement)
        defer { sqlite3_finalize(statement) }
        for row in rows {
            let payload = try JSONEncoder().encode(row)
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            let idCode = sqlite3_bind_text(statement, 1, row.id.uuidString, -1, sqliteTransient)
            let blobCode = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), sqliteTransient) }
            guard idCode == SQLITE_OK, blobCode == SQLITE_OK else { throw error(db, idCode == SQLITE_OK ? blobCode : idCode) }
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else { throw error(db, code) }
        }
    }
    private func prepare(_ db: OpaquePointer, _ sql: String, _ statement: inout OpaquePointer?) throws {
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK else { throw error(db, code) }
    }
    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw error(db, code) }
    }
    private func error(_ db: OpaquePointer?, _ code: Int32) -> Error {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据文件"
        return NSError(domain: "MyWorkbench.SQLite", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
