import Foundation

public struct RunArchive: Sendable {
    /// Workbench's own record of an Edit run's project changes, inside the run's outputs but in a folder agents don't use.
    public static let changeEvidencePath = ".workbench/changes.diff"
    public let root: URL
    public init(root: URL) { self.root = root }
    public func directory(runID: UUID, projectID: UUID?) -> URL {
        root.appendingPathComponent("projects/\(projectID?.uuidString ?? "unassigned")/runs/\(runID.uuidString)", isDirectory: true)
    }
    public func prepare(runID: UUID, projectID: UUID?) throws -> URL {
        _ = try outputDirectory(runID: runID, projectID: projectID, allowMissing: true)
        let directory = directory(runID: runID, projectID: projectID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "MyWorkbench.Archive", code: 1, userInfo: [NSLocalizedDescriptionKey: "执行编号已存在，不能覆盖旧记录。"])
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("output"), withIntermediateDirectories: true)
        // Check again after creating: a folder swapped for a link between the check and the create is caught here.
        _ = try outputDirectory(runID: runID, projectID: projectID)
        return directory
    }
    private func outputComponents(runID: UUID, projectID: UUID?) -> [String] {
        ["projects", projectID?.uuidString ?? "unassigned", "runs", runID.uuidString, "output"]
    }
    /// Check every directory below the configured archive root, including a replaced run or project folder.
    private func outputDirectory(runID: UUID, projectID: UUID?, allowMissing: Bool = false) throws -> URL {
        let components = outputComponents(runID: runID, projectID: projectID)
        var output = root.standardizedFileURL
        for component in components {
            output.appendPathComponent(component, isDirectory: true)
            if let values = try? output.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                guard values.isSymbolicLink != true, values.isDirectory == true else { throw WorkbenchError.unsafeArtifact }
            } else if !allowMissing { throw WorkbenchError.unsafeArtifact }
        }
        let expected = components.reduce(root.resolvingSymlinksInPath().standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true) }
        guard output.resolvingSymlinksInPath().standardizedFileURL.path == expected.path else { throw WorkbenchError.unsafeArtifact }
        return output
    }
    public func artifacts(for run: TaskRun) throws -> [WorkArtifact] {
        let output = URL(fileURLWithPath: run.outputDirectory).standardizedFileURL
        let owned = try outputDirectory(runID: run.id, projectID: run.projectID)
        guard output.path == owned.path else { throw WorkbenchError.unsafeArtifact }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: output, includingPropertiesForKeys: Array(keys)) else { return [] }
        var result: [WorkArtifact] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let safe = file.resolvingSymlinksInPath().standardizedFileURL
            guard safe.path.hasPrefix(output.resolvingSymlinksInPath().path + "/") else { throw WorkbenchError.unsafeArtifact }
            let relative = file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)
            result.append(WorkArtifact(taskID: run.taskID, runID: run.id, projectID: run.projectID, relativePath: String(relative), byteCount: Int64(values.fileSize ?? 0), fileType: file.pathExtension.lowercased()))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }
    /// Called from lists and previews, so it skips the per-folder walk: the file's real location has to be inside the run's
    /// real output folder, which a replaced run, project or output folder can't satisfy.
    public func url(for artifact: WorkArtifact) throws -> URL {
        guard !artifact.relativePath.hasPrefix("/"), !artifact.relativePath.split(separator: "/").contains("..") else { throw WorkbenchError.unsafeArtifact }
        let file = root.appendingPathComponent(artifact.relativePath).standardizedFileURL
        let components = outputComponents(runID: artifact.runID, projectID: artifact.projectID)
        let owned = components.reduce(root.standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true) }
        let real = components.reduce(root.resolvingSymlinksInPath().standardizedFileURL) { $0.appendingPathComponent($1, isDirectory: true) }
        guard file.path.hasPrefix(owned.path + "/"), file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(real.path + "/") else { throw WorkbenchError.unsafeArtifact }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkbenchError.unsafeArtifact }
        return file
    }
    public func importFile(_ source: URL, into run: TaskRun, named name: String? = nil) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WorkbenchError.unsafeArtifact }
        let output = try outputDirectory(runID: run.id, projectID: run.projectID)
        guard URL(fileURLWithPath: run.outputDirectory).standardizedFileURL.path == output.standardizedFileURL.path else { throw WorkbenchError.unsafeArtifact }
        let filename = name ?? source.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\") else { throw WorkbenchError.unsafeArtifact }
        let sourceName = URL(fileURLWithPath: filename)
        var target = output.appendingPathComponent(filename), counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = output.appendingPathComponent("\(sourceName.deletingPathExtension().lastPathComponent)-\(counter)").appendingPathExtension(sourceName.pathExtension)
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: target)
    }
}

public final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var pending = ""
    private var failure: Error?
    public init(url: URL, appendExisting: Bool = false) throws {
        if !appendExisting || !FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        handle = try FileHandle(forWritingTo: url)
        if appendExisting { try handle.seekToEnd() }
    }
    public func append(_ chunk: LogChunk) {
        append("[\(chunk.stream.rawValue)] \(chunk.text)")
    }
    public func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        do { try handle.write(contentsOf: Data(text.utf8)) } catch { failure = error }
        pending += text
        if pending.utf8.count > 128 * 1024 { pending = "[system] 界面显示最近日志；完整内容保存在执行归档。\n" + String(pending.suffix(32 * 1024)) }
    }
    public func drain() -> String {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = ""; return result
    }
    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        try handle.synchronize(); try handle.close()
        if let failure { throw failure }
    }
    public static func boundedTail(_ text: String) -> String {
        text.utf8.count > 128 * 1024 ? "[system] 界面显示最近日志；完整内容保存在执行归档。\n" + String(text.suffix(32 * 1024)) : text
    }
}
