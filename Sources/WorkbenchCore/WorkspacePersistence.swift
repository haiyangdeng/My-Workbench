import Foundation

public struct WorkspacePersistence {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> WorkspaceSnapshot {
        if fileURL.pathExtension == "sqlite" { return try SQLiteWorkspace(url: fileURL).load() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return WorkspaceSnapshot() }
        var snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: fileURL))
        guard (1...3).contains(snapshot.schemaVersion) else { throw WorkbenchError.unsupportedSchema }
        snapshot.schemaVersion = 3
        snapshot.migrateWorkspaces()
        snapshot.recoverInterruptedTasks()
        return snapshot
    }

    public func migrateLegacyJSON(from legacyURL: URL) throws {
        guard fileURL.pathExtension == "sqlite", FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let database = SQLiteWorkspace(url: fileURL)
        guard try !database.isInitialized() else { return }
        let snapshot = try WorkspacePersistence(fileURL: legacyURL).load()
        let backup = legacyURL.deletingPathExtension().appendingPathExtension("pre-sqlite-backup.json")
        if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: legacyURL, to: backup) }
        try database.save(snapshot)
    }

    public func save(_ snapshot: WorkspaceSnapshot) throws {
        if fileURL.pathExtension == "sqlite" { try SQLiteWorkspace(url: fileURL).save(snapshot); return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}
