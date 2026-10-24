import XCTest
@testable import WorkbenchCore

final class P1Tests: XCTestCase {
    private func repository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wb git \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = GitRepository(directory: root.path)
        _ = await git.run(["init", "-q", "-b", "main"])
        try "line 1\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = await git.commitAll(message: "initial")
        return root
    }

    func testStatusParsingAndChangedFiles() {
        let before = GitRepository.parseStatus(" M a.swift\0?? new file.txt\0R  renamed.txt\0old.txt\0")
        XCTAssertEqual(before, ["a.swift": " M", "new file.txt": "??", "renamed.txt": "R "])
        let after = ["a.swift": " M", "new file.txt": " A", "b.swift": "??"]
        XCTAssertEqual(GitRepository.changedFiles(before: before, after: after), ["b.swift", "new file.txt", "renamed.txt"])
    }

    func testRealRepositoryStatusDiffAndWorktreeMergeAndConflict() async throws {
        guard FileManager.default.isExecutableFile(atPath: GitRepository.executable) else { throw XCTSkip("git not installed") }
        let root = try await repository(); defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(directory: root.path)
        let isRepository = await git.isRepository()
        XCTAssertTrue(isRepository)
        let notRepository = await GitRepository(directory: FileManager.default.temporaryDirectory.path).isRepository()
        XCTAssertFalse(notRepository)
        let clean = await git.status()
        XCTAssertEqual(clean, [:])
        try "line 1\nline 2\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "hello; $(id)\n".write(to: root.appendingPathComponent("new file.txt"), atomically: true, encoding: .utf8)
        let changed = GitRepository.changedFiles(before: clean ?? [:], after: await git.status() ?? [:])
        XCTAssertEqual(changed, ["README.md", "new file.txt"])
        let diff = await git.diff(files: changed)
        XCTAssertTrue(diff.contains("+line 2") && diff.contains("+hello; $(id)"))
        _ = await git.commitAll(message: "work")

        let base = await git.head()
        let first = root.deletingLastPathComponent().appendingPathComponent("wt-a-\(UUID().uuidString)"), second = root.deletingLastPathComponent().appendingPathComponent("wt-b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let addA = await git.addWorktree(path: first.path, branch: "workbench/a"), addB = await git.addWorktree(path: second.path, branch: "workbench/b")
        XCTAssertEqual(addA.status, 0); XCTAssertEqual(addB.status, 0)
        try "from a\n".write(to: first.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "from b\n".write(to: second.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        let pendingDiff = await GitRepository(directory: first.path).diffAll(against: base!)
        XCTAssertTrue(pendingDiff.contains("+from a"))
        let commitA = await GitRepository(directory: first.path).commitAll(message: "a"), mergeA = await git.merge(branch: "workbench/a", message: "merge a")
        XCTAssertEqual(commitA.status, 0); XCTAssertEqual(mergeA.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("shared.txt"), encoding: .utf8), "from a\n")
        _ = await GitRepository(directory: second.path).commitAll(message: "b")
        let mergeB = await git.merge(branch: "workbench/b", message: "merge b")
        XCTAssertNotEqual(mergeB.status, 0, "Both worktrees added shared.txt differently, so the second merge conflicts")
        _ = await git.run(["merge", "--abort"])
        let removed = await git.removeWorktree(path: second.path), deleted = await git.deleteBranch("workbench/b")
        XCTAssertEqual(removed.status, 0); XCTAssertEqual(deleted.status, 0)
        let nothing = await GitRepository(directory: first.path).commitAll(message: "nothing")
        XCTAssertEqual(nothing.status, 0, "Nothing to commit counts as success")
    }

    func testDefinitionFileCarriesNoIdentityOrVersion() throws {
        var tool = ToolConfig(name: "Claude Code", executable: "/Users/me/.local/bin/claude", arguments: ["-p", "{prompt}"])
        tool.detectedVersion = "2.1"; tool.enabled = false; tool.versionChanged = true; tool.readOnlyArguments = ["--permission-mode", "plan"]; tool.concurrencyLimit = 2
        let data = try CLIDefinitionFile(tool: tool).encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(tool.id.uuidString)); XCTAssertFalse(text.contains("detectedVersion"))
        let loaded = try CLIDefinitionFile.load(data)
        XCTAssertNotEqual(loaded.id, tool.id); XCTAssertEqual(loaded.arguments, tool.arguments); XCTAssertEqual(loaded.readOnlyArguments, tool.readOnlyArguments)
        XCTAssertEqual(loaded.concurrencyLimit, 2); XCTAssertNil(loaded.enabled); XCTAssertNil(loaded.detectedVersion)
        XCTAssertThrowsError(try CLIDefinitionFile.load(Data(#"{"format":"other","version":1,"tool":{}}"#.utf8)))
    }

    func testMissingNodesAndVariantClamp() {
        let template = WorkflowTemplate(name: "t", workflow: MediaTests.workflow)
        XCTAssertEqual(template.missingNodes(on: nil), [], "Unknown node list means no warning")
        var health = ServerHealth(); health.nodeClasses = ["KSampler", "CLIPTextEncode", "SaveImage"]
        XCTAssertEqual(template.missingNodes(on: health), ["EmptyLatentImage", "LoadImage"])
        var spec = GenerationSpec(templateID: template.id, serverID: UUID(), versionHash: template.versionHash)
        XCTAssertEqual(spec.variants, 1); spec.variantCount = 20; XCTAssertEqual(spec.variants, 8); spec.variantCount = 0; XCTAssertEqual(spec.variants, 1)
    }
}
