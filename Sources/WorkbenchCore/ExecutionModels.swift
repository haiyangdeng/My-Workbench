import Foundation

public enum ToolAdapter: String, Codable, CaseIterable, Sendable {
    case command, codex, comfyUI
    public var title: String { switch self { case .command: return "通用 CLI"; case .codex: return "Codex"; case .comfyUI: return "ComfyUI" } }
}

public struct WorkProject: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var name: String
    public var directory: String
    public var goal: String
    public var categoryID: UUID?
    public var moduleIDs: [UUID]?
    public var archivedAt: Date?
    public var createdAt: Date?
    /// Copy accepted generation and command outputs into the project folder (MD-15).
    public var autoExport: Bool?
    public init(id: UUID = UUID(), name: String, directory: String, goal: String = "") {
        self.id = id; self.name = name; self.directory = directory; self.goal = goal
    }
    public var isArchived: Bool { archivedAt != nil || isDeleted }
}

public struct TaskRun: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var projectID: UUID?
    public var employee: Employee
    public var tool: ToolConfig
    public var input: String
    public var acceptance: String?
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
    public var accessLevel: AccessLevel?
    public var sessionID: String?
    public var usage: CLIUsage?
    public var model: String?
    public var conversationID: UUID?
    public var generation: GenerationSpec?
    /// Every server job of this run, for variant runs that submit several.
    public var remotePromptIDs: [String]?
    /// The CLI's final reply, bounded, so step cards and task details can show it without reading files.
    public var replyText: String?
    public init(id: UUID = UUID(), task: WorkTask, employee: Employee, tool: ToolConfig, directory: URL, feedback: String = "") {
        self.id = id; taskID = task.id; projectID = task.projectID; self.employee = employee; self.tool = tool
        self.feedback = feedback
        input = task.input + (feedback.isEmpty ? "" : "\n\n返工要求：\n" + feedback)
        acceptance = task.acceptance
        workingDirectory = task.workingDirectory
        outputDirectory = directory.appendingPathComponent("output").path
        logPath = directory.appendingPathComponent("execution.log").path
        arguments = (try? tool.invocation(CLIInvocation(prompt: input, instructions: employee.instructions, outputDirectory: outputDirectory, workingDirectory: workingDirectory))) ?? tool.resolvedArguments(input: input)
        status = .running; startedAt = Date()
    }
}

public struct WorkArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String?
    public var deletedAt: Date?
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
    /// The change record Workbench saves for review, not a deliverable: kept out of the asset library and counts.
    public var isChangeEvidence: Bool { relativePath.hasSuffix("/output/" + RunArchive.changeEvidencePath) }
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
    public var isEnabled: Bool { !isDeleted && (enabled ?? true) }
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
