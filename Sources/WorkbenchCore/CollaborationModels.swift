import Foundation

public enum TaskPurpose: String, Codable, Sendable { case work, planning, review }

public struct PlanStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var employeeID: UUID
    public var input: String
    public var acceptance: String
    public var dependencies: [String]
    public init(id: String, title: String, employeeID: UUID, input: String, acceptance: String, dependencies: [String] = []) {
        self.id = id; self.title = title; self.employeeID = employeeID; self.input = input; self.acceptance = acceptance; self.dependencies = dependencies
    }
}
public struct PlanDraft: Codable, Equatable, Sendable {
    public var title: String
    public var goal: String
    public var steps: [PlanStep]
    public init(title: String, goal: String, steps: [PlanStep]) { self.title = title; self.goal = goal; self.steps = steps }
    public func validate(workspace: WorkspaceSnapshot) throws {
        let ids = Set(steps.map(\.id))
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...20).contains(steps.count), ids.count == steps.count else { throw CollaborationError.invalidPlan }
        for step in steps {
            guard !step.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, step.id.count <= 80, !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !step.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !step.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  workspace.employees.contains(where: { $0.id == step.employeeID && ($0.enabled ?? true) }),
                  let employee = workspace.employees.first(where: { $0.id == step.employeeID }), workspace.tools.contains(where: { $0.id == employee.toolID && $0.isEnabled }),
                  Set(step.dependencies).count == step.dependencies.count, !step.dependencies.contains(step.id), step.dependencies.allSatisfy(ids.contains) else { throw CollaborationError.invalidPlan }
        }
        var visited = Set<String>()
        while visited.count < steps.count {
            let ready = steps.filter { !visited.contains($0.id) && $0.dependencies.allSatisfy(visited.contains) }
            guard !ready.isEmpty else { throw CollaborationError.cyclicDependencies }
            ready.forEach { visited.insert($0.id) }
        }
    }
}
public struct CollaborationPlan: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var goal: String
    public var taskIDs: [UUID]
    public var reviewerID: UUID?
    public var maximumReworks: Int
    public var paused: Bool
    public var approvedAt: Date
    public init(id: UUID = UUID(), projectID: UUID, title: String, goal: String, taskIDs: [UUID], reviewerID: UUID? = nil, maximumReworks: Int = 1) {
        self.id = id; self.projectID = projectID; self.title = title; self.goal = goal; self.taskIDs = taskIDs
        self.reviewerID = reviewerID; self.maximumReworks = min(2, max(0, maximumReworks)); paused = false; approvedAt = Date()
    }
}
public struct ReviewDecision: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable { case pass, rework, blocked }
    public var decision: Verdict
    public var notes: String
    public init(decision: Verdict, notes: String) { self.decision = decision; self.notes = notes }
}
public struct ReviewRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceTaskID: UUID
    public var sourceRunID: UUID
    public var reviewerTaskID: UUID
    public var reviewerRunID: UUID
    public var decision: ReviewDecision
    public var createdAt: Date
    public init(sourceTaskID: UUID, sourceRunID: UUID, reviewerTaskID: UUID, reviewerRunID: UUID, decision: ReviewDecision) {
        id = UUID(); self.sourceTaskID = sourceTaskID; self.sourceRunID = sourceRunID; self.reviewerTaskID = reviewerTaskID; self.reviewerRunID = reviewerRunID; self.decision = decision; createdAt = Date()
    }
}
public enum CollaborationError: LocalizedError {
    case invalidPlan, cyclicDependencies, missingStructuredOutput, invalidReviewer
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "计划必须包含1至20个独立步骤，使用已启用员工和工具，并填写输入与验收标准。"
        case .cyclicDependencies: return "步骤依赖形成循环，无法执行。请调整先后顺序。"
        case .missingStructuredOutput: return "没有取得有效的结构化结果，请检查本次执行的 result.json。"
        case .invalidReviewer: return "请选择没有参与生产步骤的可用审核员工。审核只能针对已归档的当前执行结果。"
        }
    }
}

public enum CollaborationSchema {
    private static func text(_ enumValues: [String]? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("string")]
        if let enumValues { fields["enum"] = .array(enumValues.map(JSONValue.string)) }; return .object(fields)
    }
    private static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties), "required": .array(properties.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
    }
    public static func plan(employeeIDs: [UUID]) throws -> Data {
        let step = object(["id": text(), "title": text(), "employeeID": text(employeeIDs.map(\.uuidString)), "input": text(), "acceptance": text(), "dependencies": .object(["type": .string("array"), "items": text()])])
        return try JSONEncoder().encode(object(["title": text(), "goal": text(), "steps": .object(["type": .string("array"), "items": step])]))
    }
    public static func review() throws -> Data { try JSONEncoder().encode(object(["decision": text(["pass", "rework", "blocked"]), "notes": text()])) }
}
