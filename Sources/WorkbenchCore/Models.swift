import Foundation

public enum WorkStatus: String, Codable, CaseIterable, Sendable {
    case draft, queued, running, review, completed, failed, cancelled, timedOut, interrupted

    public var title: String {
        switch self {
        case .draft: return "草稿"
        case .queued: return "排队"
        case .running: return "执行中"
        case .review: return "待验收"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .timedOut: return "超时"
        case .interrupted: return "已中断"
        }
    }
}

public struct ToolConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var adapter: ToolAdapter?
    public var timeoutSeconds: Double?
    public var enabled: Bool?
    public var versionArguments: [String]?
    public var detectedVersion: String?
    public var codexWorkspaceWrite: Bool?
    public var remote: ComfyConnection?
    public var loginStatusArguments: [String]?
    public var loginArguments: [String]?
    public var resumeArguments: [String]?
    public var outputFormat: CLIOutputFormat?
    public var includeInstructions: Bool?
    public var modelArguments: [String]?
    public var structuredOutputArguments: [String]?
    public var readOnlyArguments: [String]?
    public var editArguments: [String]?
    public var loggedOutText: String?
    public var useLoginShellPath: Bool?
    public var interactiveResumeArguments: [String]?
    /// The CLI may be used for command steps in production plans (for example ffmpeg).
    public var commandStep: Bool?
    /// Most runs of this CLI at once (TL-11); nil means only the global limit applies.
    public var concurrencyLimit: Int?
    /// The detected version differs from the last one (TL-12); cleared by a successful check.
    public var versionChanged: Bool?
    /// Extra environment variables for this CLI, for example ANTHROPIC_BASE_URL. Saved with the definition and exported.
    public var environment: [String: String]?
    /// Names of variables whose values are secrets. The values live in the Keychain (see `CredentialVault.cliEnvironment`)
    /// and are never saved in the workspace or exported.
    public var secretEnvironmentNames: [String]?
    /// Pass the macOS system proxy to the CLI (see SystemProxy). nil means on.
    public var useSystemProxy: Bool?

    public init(id: UUID = UUID(), name: String, executable: String, arguments: [String]) {
        self.id = id; self.name = name; self.executable = executable; self.arguments = arguments
    }

    public func resolvedArguments(input: String) -> [String] {
        arguments.map { Self.expand($0, values: ["input": input, "prompt": input]) }
    }
}

public struct Employee: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var name: String
    public var role: String
    public var department: String
    public var instructions: String
    public var toolID: UUID
    public var enabled: Bool?
    public var avatarSymbol: String?
    public var avatarImageData: Data?
    public var workspaceID: UUID?
    public var additionalWorkspaceIDs: [UUID]?
    public var maxAccess: AccessLevel?
    public var model: String?

    public init(id: UUID = UUID(), name: String, role: String, department: String, instructions: String, toolID: UUID, avatarSymbol: String? = nil, avatarImageData: Data? = nil) {
        self.id = id; self.name = name; self.role = role; self.department = department
        self.instructions = instructions; self.toolID = toolID
        self.avatarSymbol = avatarSymbol; self.avatarImageData = avatarImageData
    }
}

public struct WorkTask: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var title: String
    public var employeeID: UUID
    public var input: String
    public var workingDirectory: String
    public var acceptance: String
    public var status: WorkStatus = .draft
    public var createdAt: Date = Date()
    public var archivedAt: Date?
    public var log: String = ""
    public var exitCode: Int32?
    public var projectID: UUID?
    public var dependencyIDs: [UUID]?
    public var handoffID: UUID?
    public var pendingFeedback: String?
    public var purpose: TaskPurpose?
    public var planID: UUID?
    public var reviewSourceTaskID: UUID?
    public var reviewSourceRunID: UUID?
    public var toolSnapshot: ToolConfig?
    public var employeeSnapshot: Employee?
    public var accessLevel: AccessLevel?
    public var generation: GenerationSpec?
    public var command: CommandSpec?
    public var worktree: WorktreeInfo?

    public init(id: UUID = UUID(), title: String, employeeID: UUID, input: String, workingDirectory: String, acceptance: String) {
        self.id = id; self.title = title; self.employeeID = employeeID; self.input = input
        self.workingDirectory = workingDirectory; self.acceptance = acceptance
    }

    public mutating func accept() throws {
        guard status == .review else { throw WorkbenchError.invalidTransition }
        status = .completed
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 4
    public var schemaVersion = WorkspaceSnapshot.currentSchemaVersion
    public var workspaces: [WorkArea] = WorkArea.defaults
    public var categories: [ProjectCategory] = []
    public var conversations: [Conversation] = []
    public var messages: [ChatMessage] = []
    public var sessions: [AgentSession] = []
    public var servers: [ComfyServer] = []
    public var templates: [WorkflowTemplate] = []
    public var tools: [ToolConfig] = []
    public var employees: [Employee] = []
    public var tasks: [WorkTask] = []
    public var projects: [WorkProject] = []
    public var runs: [TaskRun] = []
    public var artifacts: [WorkArtifact] = []
    public var handoffs: [WorkHandoff] = []
    public var plans: [CollaborationPlan] = []
    public var reviews: [ReviewRecord] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, workspaces, categories, conversations, messages, sessions, servers, templates, tools, employees, tasks, projects, runs, artifacts, handoffs, plans, reviews }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        workspaces = try c.decodeIfPresent([WorkArea].self, forKey: .workspaces) ?? WorkArea.defaults
        categories = try c.decodeIfPresent([ProjectCategory].self, forKey: .categories) ?? []
        conversations = try c.decodeIfPresent([Conversation].self, forKey: .conversations) ?? []
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        sessions = try c.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
        servers = try c.decodeIfPresent([ComfyServer].self, forKey: .servers) ?? []
        templates = try c.decodeIfPresent([WorkflowTemplate].self, forKey: .templates) ?? []
        tools = try c.decodeIfPresent([ToolConfig].self, forKey: .tools) ?? []
        employees = try c.decodeIfPresent([Employee].self, forKey: .employees) ?? []
        tasks = try c.decodeIfPresent([WorkTask].self, forKey: .tasks) ?? []
        projects = try c.decodeIfPresent([WorkProject].self, forKey: .projects) ?? []
        runs = try c.decodeIfPresent([TaskRun].self, forKey: .runs) ?? []
        artifacts = try c.decodeIfPresent([WorkArtifact].self, forKey: .artifacts) ?? []
        handoffs = try c.decodeIfPresent([WorkHandoff].self, forKey: .handoffs) ?? []
        plans = try c.decodeIfPresent([CollaborationPlan].self, forKey: .plans) ?? []
        reviews = try c.decodeIfPresent([ReviewRecord].self, forKey: .reviews) ?? []
    }
    public mutating func recoverInterruptedTasks() {
        for i in tasks.indices where tasks[i].status == .running || tasks[i].status == .queued {
            tasks[i].status = .interrupted
            tasks[i].log += "\n[system] 上次执行已中断，请检查工具状态后再重试。\n"
        }
        for i in runs.indices where runs[i].status == .running || runs[i].status == .queued {
            runs[i].status = .interrupted; runs[i].endedAt = Date()
        }
        // Chat turns are never re-sent after a restart.
        for i in messages.indices where messages[i].state?.isActive == true {
            messages[i].state = .interrupted; messages[i].endedAt = messages[i].endedAt ?? Date()
            messages[i].detail = "应用退出时这一轮还没有完成，没有自动重新发送。"
        }
    }
}

public enum WorkbenchError: LocalizedError {
    case invalidExecutable, invalidDirectory, unsupportedSchema, invalidTransition, invalidHandoff, unsafeArtifact, invalidArguments

    public var errorDescription: String? {
        switch self {
        case .invalidExecutable: return "请选择存在且可执行的绝对路径。"
        case .invalidDirectory: return "工作目录不存在，或不是目录。"
        case .unsupportedSchema: return "数据版本暂不支持，原文件已保留。"
        case .invalidArguments: return "参数或环境变量包含无法传给进程的空字符，请修正输入。"
        case .invalidHandoff: return "只能交接已验收的执行和属于该执行的产物，且必须填写目标与验收标准。"
        case .unsafeArtifact: return "产物路径必须位于本次执行的产物目录内，不能引用符号链接或其他项目。"
        case .invalidTransition: return "只有待验收任务可以标记为已完成。"
        }
    }
}
