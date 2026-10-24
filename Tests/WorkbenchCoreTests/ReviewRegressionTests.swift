import XCTest
@testable import WorkbenchCore

final class ReviewRegressionTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workbench review \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func repository(_ root: URL) async throws -> GitRepository {
        let git = GitRepository(directory: root.path)
        let result = await git.run(["init", "-q", "-b", "main"])
        XCTAssertEqual(result.status, 0)
        try "original\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "initial")
        return git
    }
    private func baseline(_ git: GitRepository) async throws -> GitChangeBaseline {
        let value = await git.changeBaseline()
        return try XCTUnwrap(value)
    }

    func testArchiveRejectsReplacedOutputAndAncestorDirectories() throws {
        for component in ["output", "run", "project", "runs"] {
            let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
            let archive = RunArchive(root: root.appendingPathComponent("Archives"))
            let tool = ToolConfig(name: "test", executable: "/usr/bin/true", arguments: [])
            let employee = Employee(name: "test", role: "", department: "", instructions: "", toolID: tool.id)
            var task = WorkTask(title: "test", employeeID: employee.id, input: "", workingDirectory: root.path, acceptance: "check")
            task.projectID = UUID()
            let runID = UUID(), directory = try archive.prepare(runID: runID, projectID: task.projectID)
            let run = TaskRun(id: runID, task: task, employee: employee, tool: tool, directory: directory)
            let output = URL(fileURLWithPath: run.outputDirectory)
            try "existing".write(to: output.appendingPathComponent("existing.txt"), atomically: true, encoding: .utf8)
            let artifact = try XCTUnwrap(archive.artifacts(for: run).first)
            let replaced: URL
            switch component {
            case "output": replaced = output
            case "run": replaced = directory
            case "runs": replaced = directory.deletingLastPathComponent()
            default: replaced = directory.deletingLastPathComponent().deletingLastPathComponent()
            }
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: replaced, to: outside)
            try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
            let source = root.appendingPathComponent("source.txt")
            try "new".write(to: source, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try archive.importFile(source, into: run))
            XCTAssertThrowsError(try archive.url(for: artifact))
            XCTAssertThrowsError(try archive.artifacts(for: run))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("source.txt").path), component)
            if component == "project" || component == "runs" {
                XCTAssertThrowsError(try archive.prepare(runID: UUID(), projectID: task.projectID))
            }
        }
    }

    func testGitPreservesUnicodeQuotesNewlinesArrowsAndLiteralPathspecs() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = try await repository(root)
        _ = await git.run(["config", "core.quotePath", "true"])
        let names = ["中文说明.md", "quote\".txt", "line\nbreak.txt", "a -> b.txt", ":literal*.txt"]
        for name in names { try "old\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        _ = await git.commitAll(message: "names")
        for name in names { try "old\nuser\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let before = try await baseline(git)
        XCTAssertEqual(Set(before.status.keys), Set(names)); XCTAssertEqual(before.content.count, names.count)
        for name in names { try "old\nuser\nagent\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let changes = await git.changedFiles(since: before)
        XCTAssertEqual(Set(changes), Set(names))
        let diff = await git.diff(files: changes, since: before)
        XCTAssertEqual(diff.components(separatedBy: "+agent").count - 1, names.count)
        XCTAssertFalse(diff.contains("+user"), "Only changes since the actual starting contents belong to this run")
        XCTAssertTrue(diff.contains("+++ b/中文说明.md")); XCTAssertFalse(diff.contains("workbench-baseline"))
        let newName = "新增\n\" -> :*.md"
        try "untracked content\n".write(to: root.appendingPathComponent(newName), atomically: true, encoding: .utf8)
        let untrackedDiff = await git.diff(files: [newName])
        XCTAssertTrue(untrackedDiff.contains("+untracked content"))
        let all = await git.diffAll(against: before.head!)
        XCTAssertTrue(all.contains("+untracked content"))
    }

    func testGitCapturesCommittedChangesAndKeepsEvidenceAfterLaterCommits() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = try await repository(root)
        let before = try await baseline(git)
        try "original\nagent commit\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "agent")
        let changes = await git.changedFiles(since: before)
        XCTAssertEqual(changes, ["notes.txt"])
        let diff = await git.diff(files: changes, since: before)
        XCTAssertTrue(diff.contains("+agent commit"))
        let status = await git.status(); XCTAssertEqual(status, [:])
    }

    func testGitDoesNotAttributeUnchangedUserEditsOrPreexistingRenameToAgent() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = try await repository(root)
        try "original\nuser only\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        _ = await git.run(["mv", "notes.txt", "重命名 -> \"\n.md"])
        let before = try await baseline(git)
        _ = await git.commitAll(message: "commit preexisting changes")
        let changes = await git.changedFiles(since: before)
        XCTAssertEqual(changes, [])
    }

    func testGitDetectsFurtherEditsToDirtyFilesEvenWhenCommittedOrRevertedClean() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = try await repository(root)
        let file = root.appendingPathComponent("notes.txt")
        try "original\nuser\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try await baseline(git)
        try "original\nuser\nagent\n".write(to: file, atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "agent")
        let changes = await git.changedFiles(since: before)
        let diff = await git.diff(files: changes, since: before)
        XCTAssertEqual(changes, ["notes.txt"]); XCTAssertTrue(diff.contains("+agent")); XCTAssertFalse(diff.contains("+user"))
        let dirty = try await baseline(git)
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "revert contents")
        let reverted = await git.changedFiles(since: dirty)
        XCTAssertEqual(reverted, ["notes.txt"])
    }

    func testGitBaselineWorksBeforeFirstCommit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(directory: root.path)
        _ = await git.run(["init", "-q"])
        let file = root.appendingPathComponent("first.txt")
        try "user\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try await baseline(git)
        try "user\nagent\n".write(to: file, atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "first")
        let changes = await git.changedFiles(since: before)
        let diff = await git.diff(files: changes, since: before)
        XCTAssertEqual(changes, ["first.txt"]); XCTAssertTrue(diff.contains("+agent")); XCTAssertFalse(diff.contains("+user"))
    }

    func testGitBaselineKeepsFingerprintOnlyForFilesOverTheCopyLimit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = try await repository(root)
        let big = root.appendingPathComponent("big.bin"), notes = root.appendingPathComponent("notes.txt")
        try Data([0]).write(to: big); _ = await git.commitAll(message: "binary")
        try Data(repeating: 0, count: GitRepository.baselineFileLimit + 1).write(to: big)
        try "original\nuser\n".write(to: notes, atomically: true, encoding: .utf8)
        let before = try await baseline(git)
        XCTAssertEqual(before.saved, ["notes.txt"]); XCTAssertNotNil(before.content["big.bin"])
        try Data(repeating: 1, count: GitRepository.baselineFileLimit + 1).write(to: big)
        try "original\nuser\nagent\n".write(to: notes, atomically: true, encoding: .utf8)
        let changes = await git.changedFiles(since: before)
        XCTAssertEqual(changes, ["big.bin", "notes.txt"])
        let diff = await git.diff(files: changes, since: before)
        XCTAssertTrue(diff.contains("差异相对于 HEAD") && diff.contains("big.bin"), diff)
        XCTAssertTrue(diff.contains("+agent")); XCTAssertFalse(diff.contains("+user"))
    }

    func testGitDiffSinceBaselineHidesAbsolutePathsInBinaryAndHeaderLines() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = try await repository(root)
        let image = root.appendingPathComponent("image.png")
        try Data([0, 1, 2]).write(to: image); _ = await git.commitAll(message: "image")
        try Data([0, 1, 2, 3]).write(to: image)
        try "original\n--- \(root.path)/kept\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let before = try await baseline(git)
        try Data([0, 1, 2, 3, 4]).write(to: image)
        try "original\n--- \(root.path)/kept\nagent\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let diff = await git.diff(files: await git.changedFiles(since: before), since: before)
        XCTAssertTrue(diff.contains("Binary files a/image.png and b/image.png differ"), diff)
        XCTAssertFalse(diff.contains("workbench-baseline"), diff)
        XCTAssertEqual(diff.components(separatedBy: root.path).count - 1, 1, "Only the file's own content keeps the project path: \(diff)")
    }

    func testChangeEvidenceIsKeptApartFromDeliverables() {
        let run = UUID(), task = UUID(), project = UUID()
        let evidence = WorkArtifact(taskID: task, runID: run, projectID: project, relativePath: "projects/\(project)/runs/\(run)/output/" + RunArchive.changeEvidencePath, byteCount: 1, fileType: "diff")
        let deliverable = WorkArtifact(taskID: task, runID: run, projectID: project, relativePath: "projects/\(project)/runs/\(run)/output/changes.diff", byteCount: 1, fileType: "diff")
        XCTAssertTrue(evidence.isChangeEvidence); XCTAssertFalse(deliverable.isChangeEvidence)
    }
}
