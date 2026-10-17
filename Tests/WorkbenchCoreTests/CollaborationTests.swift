import XCTest
@testable import WorkbenchCore

final class CollaborationTests: XCTestCase {
    private func fixture() -> (WorkspaceSnapshot, Employee) {
        var workspace = WorkspaceSnapshot()
        let tool = ToolConfig(name: "fixture", executable: "/usr/bin/printf", arguments: [])
        let employee = Employee(name: "工程师", role: "实现", department: "开发部", instructions: "", toolID: tool.id)
        workspace.tools = [tool]; workspace.employees = [employee]; return (workspace, employee)
    }
    func testPlanAllowsParallelStepsAndRejectsCyclesMissingAndDuplicateIDs() throws {
        let (workspace, employee) = fixture()
        let a = PlanStep(id: "a", title: "开发", employeeID: employee.id, input: "开发", acceptance: "输出文件")
        let b = PlanStep(id: "b", title: "设计", employeeID: employee.id, input: "设计", acceptance: "输出文件")
        let c = PlanStep(id: "c", title: "交付", employeeID: employee.id, input: "合并", acceptance: "验收", dependencies: ["a", "b"])
        let draft = PlanDraft(title: "协作", goal: "交付", steps: [a, b, c])
        XCTAssertNoThrow(try draft.validate(workspace: workspace))
        var cycle = draft; cycle.steps[0].dependencies = ["c"]; XCTAssertThrowsError(try cycle.validate(workspace: workspace))
        var missing = draft; missing.steps[2].dependencies = ["outside"]; XCTAssertThrowsError(try missing.validate(workspace: workspace))
        var duplicate = draft; duplicate.steps[1].id = "a"; XCTAssertThrowsError(try duplicate.validate(workspace: workspace))
        var empty = draft; empty.steps[0].acceptance = "  \n"; XCTAssertThrowsError(try empty.validate(workspace: workspace))
    }
    func testDisabledOrMissingToolCannotEnterPlan() throws {
        var (workspace, employee) = fixture()
        let draft = PlanDraft(title: "协作", goal: "交付", steps: [PlanStep(id: "a", title: "任务", employeeID: employee.id, input: "输入", acceptance: "检查")])
        workspace.tools[0].enabled = false; XCTAssertThrowsError(try draft.validate(workspace: workspace))
        workspace.tools[0].enabled = true; workspace.employees[0].enabled = false; XCTAssertThrowsError(try draft.validate(workspace: workspace))
        workspace.employees[0].enabled = true; workspace.tools = []; XCTAssertThrowsError(try draft.validate(workspace: workspace))
    }
    func testStructuredSchemasAllowOnlyConfiguredEmployeesAndKnownVerdicts() throws {
        let ids = [UUID(), UUID()]
        let schema = try JSONDecoder().decode(JSONValue.self, from: CollaborationSchema.plan(employeeIDs: ids))
        XCTAssertEqual(schema["properties"]["steps"]["items"]["properties"]["employeeID"]["enum"].array?.compactMap(\.string), ids.map(\.uuidString))
        XCTAssertEqual(schema["additionalProperties"].boolean, false)
        XCTAssertThrowsError(try JSONDecoder().decode(ReviewDecision.self, from: Data(#"{"decision":"execute-command","notes":"invalid"}"#.utf8)))
        let decision = try JSONDecoder().decode(ReviewDecision.self, from: Data(#"{"decision":"rework","notes":"文件缺少说明"}"#.utf8))
        XCTAssertEqual(decision.decision, .rework)
    }
    func testPlanAndReviewsPersistTogetherInSQLite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var (workspace, _) = fixture()
        let plan = CollaborationPlan(projectID: UUID(), title: "计划", goal: "交付", taskIDs: [UUID()], maximumReworks: 100)
        XCTAssertEqual(plan.maximumReworks, 2)
        let review = ReviewRecord(sourceTaskID: plan.taskIDs[0], sourceRunID: UUID(), reviewerTaskID: UUID(), reviewerRunID: UUID(), decision: ReviewDecision(decision: .pass, notes: "检查文件通过"))
        workspace.plans = [plan]; workspace.reviews = [review]
        let persistence = WorkspacePersistence(fileURL: root.appendingPathComponent("workspace.sqlite")); try persistence.save(workspace)
        let restored = try persistence.load()
        XCTAssertEqual(restored.plans, [plan]); XCTAssertEqual(restored.reviews, [review])
    }
}
