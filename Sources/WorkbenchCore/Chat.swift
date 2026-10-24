import Foundation

public enum ChatMode: String, Codable, CaseIterable, Sendable {
    case single, parallel, team, director
    public var title: String {
        switch self {
        case .single: return "单人"
        case .parallel: return "并行"
        case .team: return "团队"
        case .director: return "导演"
        }
    }
}

public enum ChatRole: String, Codable, Sendable { case user, agent }

/// What an agent turn is for. Planning and wrap-up turns belong to team mode.
public enum TurnKind: String, Codable, Sendable { case reply, planning, production, wrapUp }

public enum TurnState: String, Codable, CaseIterable, Sendable {
    case queued, running, replied, failed, stopped, timedOut, interrupted, cancelled
    public var title: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "回复中"
        case .replied: return "已回复"
        case .failed: return "失败"
        case .stopped: return "已停止"
        case .timedOut: return "超时"
        case .interrupted: return "已中断"
        case .cancelled: return "已取消"
        }
    }
    public var isActive: Bool { self == .queued || self == .running }
    public init(_ status: WorkStatus) {
        switch status {
        case .review, .completed: self = .replied
        case .cancelled: self = .stopped
        case .timedOut: self = .timedOut
        case .interrupted: self = .interrupted
        default: self = .failed
        }
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var projectID: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), projectID: UUID, title: String, createdAt: Date = Date()) {
        self.id = id; self.projectID = projectID; self.title = title; self.createdAt = createdAt; updatedAt = createdAt
    }
    /// First line of the first message, trimmed to 40 characters.
    public static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "新对话" : String(line.prefix(40))
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var role: ChatRole
    public var text: String
    public var createdAt: Date
    // User messages
    public var attachments: [String]?
    public var targetIDs: [UUID]?
    public var mode: ChatMode?
    public var access: AccessLevel?
    public var leadID: UUID?
    /// Director mode (MD-16): the templates and servers the director may use for this message.
    public var directorTemplateIDs: [UUID]?
    public var directorServerIDs: [UUID]?
    // Agent turns
    public var agentID: UUID?
    public var replyToID: UUID?
    public var kind: TurnKind?
    public var prompt: String?
    public var runID: UUID?
    public var state: TurnState?
    public var activities: [CLIActivity]?
    public var detail: String?
    public var usage: CLIUsage?
    public var resumed: Bool?
    public var startedAt: Date?
    public var endedAt: Date?
    public var promotedTaskID: UUID?
    /// Files an Edit turn changed in a git project (CH-11).
    public var changedFiles: [String]?
    // Team planning
    public var planDraft: PlanDraft?
    public var planID: UUID?
    public var repairOfID: UUID?

    public init(id: UUID = UUID(), conversationID: UUID, role: ChatRole, text: String, createdAt: Date = Date()) {
        self.id = id; self.conversationID = conversationID; self.role = role; self.text = text; self.createdAt = createdAt
    }
    public var turnKind: TurnKind { kind ?? .reply }
}

/// The CLI's own conversation ID for one agent in one conversation.
public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var conversationID: UUID
    public var agentID: UUID
    public var toolID: UUID
    public var nativeID: String
    public var updatedAt: Date
    public var invalid: Bool
    public init(id: UUID = UUID(), conversationID: UUID, agentID: UUID, toolID: UUID, nativeID: String, updatedAt: Date = Date(), invalid: Bool = false) {
        self.id = id; self.conversationID = conversationID; self.agentID = agentID; self.toolID = toolID; self.nativeID = nativeID; self.updatedAt = updatedAt; self.invalid = invalid
    }
}

extension WorkspaceSnapshot {
    public func messages(in conversationID: UUID) -> [ChatMessage] {
        messages.filter { $0.conversationID == conversationID }.sorted { $0.createdAt < $1.createdAt }
    }
    public func usableSession(conversationID: UUID, agentID: UUID, toolID: UUID) -> AgentSession? {
        sessions.first { $0.conversationID == conversationID && $0.agentID == agentID && $0.toolID == toolID && !$0.invalid }
    }
    public mutating func recordSession(conversationID: UUID, agentID: UUID, toolID: UUID, nativeID: String) {
        if let index = sessions.firstIndex(where: { $0.conversationID == conversationID && $0.agentID == agentID && $0.toolID == toolID && !$0.invalid }) {
            sessions[index].nativeID = nativeID; sessions[index].updatedAt = Date()
        } else { sessions.append(AgentSession(conversationID: conversationID, agentID: agentID, toolID: toolID, nativeID: nativeID)) }
    }

    /// Earlier messages, newest last, bounded so a new session gets context without an unbounded prompt.
    public func transcriptContext(conversationID: UUID, before date: Date, limit: Int = 12_000) -> String {
        var lines: [String] = []
        var used = 0
        for message in messages(in: conversationID).reversed() where message.createdAt < date {
            let author = message.role == .user ? "用户" : (employees.first { $0.id == message.agentID }?.name ?? "员工")
            let body = message.role == .agent && message.state != .replied ? "" : String(message.text.prefix(2000))
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let line = "\(author)：\(body)"
            if used + line.count > limit { break }
            lines.append(line); used += line.count
        }
        return lines.reversed().joined(separator: "\n\n")
    }
}

/// Explains why a turn or run did not succeed, in the terms the user can act on.
public enum TurnDiagnosis {
    public static func explain(status: WorkStatus, exitCode: Int32?, summary: CLIOutputSummary, tool: ToolConfig, outputTail: String) -> String? {
        if !summary.permissionDenials.isEmpty {
            let names = Array(Set(summary.permissionDenials)).sorted().joined(separator: "、")
            let note = "CLI 拒绝了 \(summary.permissionDenials.count) 个需要授权的操作（\(names)）。可以提高这一轮的权限，或在终端中继续这个会话。"
            if status == .review { return note }
            return note + "\n" + (summary.errorMessage ?? "")
        }
        switch status {
        case .review, .completed: return nil
        case .cancelled: return "已停止。已经产生的输出保留在记录中。"
        case .timedOut: return "超过 \(Int(tool.timeout)) 秒没有完成，已停止。可以在工具连接中调整超时。"
        default: break
        }
        let text = (summary.errorMessage ?? "") + "\n" + outputTail
        let marker = tool.loggedOutText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loginHints = ["not logged in", "please run /login", "please log in", "authentication required", "invalid api key", "unauthorized"]
        if (!marker.isEmpty && text.localizedCaseInsensitiveContains(marker)) || loginHints.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return "CLI 没有登录。在“工具连接”中点“在终端登录”，完成后再发送。"
        }
        let quotaHints = ["usage limit", "rate limit", "rate_limit", "insufficient_quota", "quota exceeded", "credit balance is too low", "too many requests"]
        if quotaHints.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            let retry = text.range(of: #"try again (at|in) [^.\n]+"#, options: [.regularExpression, .caseInsensitive]).map { "（CLI 提示：\(text[$0])）" } ?? ""
            return "CLI 账号的用量额度已用完或被限流\(retry)。额度恢复后再发送；团队和制作计划会在失败的步骤处暂停，恢复后可以继续。"
        }
        let reason = summary.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? String(outputTail.trimmingCharacters(in: .whitespacesAndNewlines).suffix(600)).nonEmpty ?? "没有输出。"
        return "CLI 退出码 \(exitCode.map(String.init) ?? "未知")：\(reason)"
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
