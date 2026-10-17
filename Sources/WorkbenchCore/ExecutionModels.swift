import Foundation

public enum ToolAdapter: String, Codable, CaseIterable, Sendable {
    case command, codex, comfyUI
    public var title: String { switch self { case .command: return "通用 CLI"; case .codex: return "Codex"; case .comfyUI: return "ComfyUI" } }
}

public struct WorkProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var directory: String
    public var goal: String
    public init(id: UUID = UUID(), name: String, directory: String, goal: String = "") {
        self.id = id; self.name = name; self.directory = directory; self.goal = goal
    }
}

public struct TaskRun: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var projectID: UUID?
    public var employee: Employee
    public var tool: ToolConfig
    public var input: String
    public var arguments: [String]
    public var workingDirectory: String
    public var outputDirectory: String
    public var logPath: String
    public var status: WorkStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var feedback: String
    public var remotePromptID: String?
    public var remoteArtifacts: [RemoteArtifact]?
    public init(id: UUID = UUID(), task: WorkTask, employee: Employee, tool: ToolConfig, directory: URL, feedback: String = "") {
        self.id = id; taskID = task.id; projectID = task.projectID; self.employee = employee; self.tool = tool
        self.feedback = feedback
        input = task.input + (feedback.isEmpty ? "" : "\n\n返工要求：\n" + feedback)
        workingDirectory = task.workingDirectory
        outputDirectory = directory.appendingPathComponent("output").path
        logPath = directory.appendingPathComponent("execution.log").path
        arguments = tool.executionArguments(input: input, instructions: employee.instructions, output: outputDirectory)
        status = .running; startedAt = Date()
    }
}

public struct WorkArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var runID: UUID
    public var projectID: UUID?
    public var relativePath: String
    public var byteCount: Int64
    public var fileType: String
    public var accepted: Bool
    public init(id: UUID = UUID(), taskID: UUID, runID: UUID, projectID: UUID?, relativePath: String, byteCount: Int64, fileType: String, accepted: Bool = false) {
        self.id = id; self.taskID = taskID; self.runID = runID; self.projectID = projectID
        self.relativePath = relativePath; self.byteCount = byteCount; self.fileType = fileType; self.accepted = accepted
    }
}

public struct WorkHandoff: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sourceTaskID: UUID
    public var sourceRunID: UUID
    public var targetEmployeeID: UUID
    public var projectID: UUID?
    public var artifactIDs: [UUID]
    public var goal: String
    public var parameters: String
    public var constraints: String
    public var passedChecks: String
    public var openQuestions: String
    public var acceptance: String
    public var targetTaskID: UUID?
    public var createdAt: Date
    public init(id: UUID = UUID(), sourceTaskID: UUID, sourceRunID: UUID, targetEmployeeID: UUID, projectID: UUID?, artifactIDs: [UUID], goal: String, parameters: String = "", constraints: String = "", passedChecks: String = "", openQuestions: String = "", acceptance: String) {
        self.id = id; self.sourceTaskID = sourceTaskID; self.sourceRunID = sourceRunID
        self.targetEmployeeID = targetEmployeeID; self.projectID = projectID; self.artifactIDs = artifactIDs
        self.goal = goal; self.parameters = parameters; self.constraints = constraints
        self.passedChecks = passedChecks; self.openQuestions = openQuestions; self.acceptance = acceptance; createdAt = Date()
    }
}

extension ToolConfig {
    public var adapterKind: ToolAdapter { adapter ?? .command }
    public var timeout: TimeInterval { let value = timeoutSeconds ?? 1800; return value.isFinite ? min(86400, max(0.1, value)) : 1800 }
    public var isEnabled: Bool { enabled ?? true }
    public func executionArguments(input: String, instructions: String, output: String) -> [String] {
        if adapterKind == .codex {
            let prompt = "职责：\n\(instructions)\n\n任务：\n\(input)\n\n最终回复会自动保存为：\(output)/result.md。其他产物目录：\(output)"
            return ["exec", "--json", "--sandbox", codexWorkspaceWrite == true ? "workspace-write" : "read-only", "--output-last-message", output + "/result.md"] + (codexWorkspaceWrite == true ? ["--add-dir", output] : []) + ["--", prompt]
        }
        return resolvedArguments(input: input).map { $0.replacingOccurrences(of: "{output}", with: output) }
    }
}

extension WorkspaceSnapshot {
    public func validateHandoff(_ handoff: WorkHandoff) throws {
        guard let task = tasks.first(where: { $0.id == handoff.sourceTaskID }), task.status == .completed,
              let run = runs.first(where: { $0.id == handoff.sourceRunID && $0.taskID == task.id }), run.status == .completed,
              employees.contains(where: { $0.id == handoff.targetEmployeeID && ($0.enabled ?? true) }),
              handoff.projectID == task.projectID,
              handoff.artifactIDs.allSatisfy({ id in artifacts.contains { $0.id == id && $0.runID == run.id && $0.projectID == task.projectID && $0.accepted } }),
              !handoff.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !handoff.acceptance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkbenchError.invalidHandoff }
    }
}
