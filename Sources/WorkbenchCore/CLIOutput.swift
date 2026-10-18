import Foundation

public struct CLIUsage: Codable, Equatable, Sendable {
    public var costUSD: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(costUSD: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.costUSD = costUSD; self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
    public var isEmpty: Bool { costUSD == nil && inputTokens == nil && outputTokens == nil }
}

public struct CLIActivity: Codable, Equatable, Sendable {
    public var kind: String
    public var summary: String
    public init(kind: String, summary: String) { self.kind = kind; self.summary = summary }
}

public enum CLIEvent: Equatable, Sendable {
    case textDelta(String), message(String), activity(CLIActivity), session(String)
}

public struct CLIOutputSummary: Equatable, Sendable {
    public var replyText = ""
    public var sessionID: String?
    public var usage = CLIUsage()
    public var activities: [CLIActivity] = []
    public var structuredJSON: Data?
    public var errorMessage: String?
    /// Tool names the CLI refused because they needed an approval that headless mode could not give.
    public var permissionDenials: [String] = []
    public init() {}
}

/// Reads one CLI's stdout incrementally. stdout chunks may split lines and UTF-8 is already decoded upstream.
public final class CLIOutputCollector: @unchecked Sendable {
    public static let replyLimit = 1024 * 1024
    private let lock = NSLock()
    private let format: CLIOutputFormat
    private var buffer = ""
    private var summary = CLIOutputSummary()
    private var assistantText = ""
    private var resultText: String?
    private let onEvent: (@Sendable (CLIEvent) -> Void)?

    public init(format: CLIOutputFormat, onEvent: (@Sendable (CLIEvent) -> Void)? = nil) {
        self.format = format; self.onEvent = onEvent
    }

    public func consume(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if format == .plainText { summary.replyText = Self.bounded(summary.replyText + text); emit(.textDelta(text)); return }
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline]); buffer.removeSubrange(...newline)
            parse(line)
        }
        if buffer.utf8.count > 8 * 1024 * 1024 { buffer = "" }
    }

    public func finish() -> CLIOutputSummary {
        lock.lock(); defer { lock.unlock() }
        if format != .plainText, !buffer.isEmpty { parse(buffer); buffer = "" }
        if format != .plainText { summary.replyText = Self.bounded(resultText ?? assistantText) }
        return summary
    }

    private func emit(_ event: CLIEvent) { onEvent?(event) }

    private func parse(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
        if format == .streamJSON { parseStreamJSON(json) } else { parseJSONLines(json) }
    }

    private func setSession(_ id: String?) {
        guard let id, !id.isEmpty, summary.sessionID != id else { return }
        summary.sessionID = id; emit(.session(id))
    }
    private func addActivity(_ activity: CLIActivity) {
        summary.activities.append(activity)
        if summary.activities.count > 500 { summary.activities.removeFirst(summary.activities.count - 500) }
        emit(.activity(activity))
    }

    // Claude Code `--output-format stream-json`: system/init, assistant, user, stream_event and result messages.
    private func parseStreamJSON(_ json: JSONValue) {
        setSession(json["session_id"].string)
        switch json["type"].string {
        case "assistant":
            for block in json["message"]["content"].array ?? [] {
                switch block["type"].string {
                case "text":
                    if let text = block["text"].string, !text.isEmpty {
                        assistantText += (assistantText.isEmpty ? "" : "\n\n") + text
                        assistantText = Self.bounded(assistantText); emit(.message(text))
                    }
                case "tool_use":
                    addActivity(CLIActivity(kind: block["name"].string ?? "tool", summary: Self.describeToolInput(block["input"])))
                default: break
                }
            }
        case "stream_event":
            let event = json["event"]
            if event["type"].string == "content_block_delta", event["delta"]["type"].string == "text_delta", let text = event["delta"]["text"].string { emit(.textDelta(text)) }
        case "result":
            if let text = json["result"].string { resultText = text }
            if json["is_error"].boolean == true || (json["subtype"].string ?? "success") != "success" {
                summary.errorMessage = json["result"].string ?? json["subtype"].string
            }
            if case .number(let cost) = json["total_cost_usd"] { summary.usage.costUSD = cost }
            summary.usage.inputTokens = Self.integer(json["usage"]["input_tokens"]) ?? summary.usage.inputTokens
            summary.usage.outputTokens = Self.integer(json["usage"]["output_tokens"]) ?? summary.usage.outputTokens
            summary.permissionDenials = (json["permission_denials"].array ?? []).map { $0["tool_name"].string ?? "tool" }
            let structured = json["structured_output"]
            if structured.object != nil || structured.array != nil { summary.structuredJSON = try? JSONEncoder().encode(structured) }
        default: break
        }
    }

    // Codex `exec --json`: thread.started, item.*, turn.completed/failed and error events (older msg-wrapped events too).
    private func parseJSONLines(_ json: JSONValue) {
        switch json["type"].string {
        case "thread.started": setSession(json["thread_id"].string)
        case "item.completed":
            let item = json["item"]
            switch item["type"].string {
            case "agent_message":
                if let text = item["text"].string { resultText = text; emit(.message(text)) }
            case "command_execution": addActivity(CLIActivity(kind: "command", summary: item["command"].string ?? ""))
            case "file_change":
                let paths = (item["changes"].array ?? []).compactMap { $0["path"].string }
                addActivity(CLIActivity(kind: "file_change", summary: paths.joined(separator: ", ")))
            case "mcp_tool_call": addActivity(CLIActivity(kind: "mcp", summary: [item["server"].string, item["tool"].string].compactMap { $0 }.joined(separator: " · ")))
            case "web_search": addActivity(CLIActivity(kind: "web_search", summary: item["query"].string ?? ""))
            default: break
            }
        case "turn.completed":
            summary.usage.inputTokens = Self.integer(json["usage"]["input_tokens"]) ?? summary.usage.inputTokens
            summary.usage.outputTokens = Self.integer(json["usage"]["output_tokens"]) ?? summary.usage.outputTokens
        case "turn.failed": summary.errorMessage = json["error"]["message"].string ?? "turn failed"
        case "error": summary.errorMessage = json["message"].string ?? "error"
        default:
            let message = json["msg"]
            switch message["type"].string {
            case "session_configured": setSession(message["session_id"].string)
            case "agent_message": if let text = message["message"].string { resultText = text; emit(.message(text)) }
            case "exec_command_begin": addActivity(CLIActivity(kind: "command", summary: (message["command"].array ?? []).compactMap(\.string).joined(separator: " ")))
            case "error": summary.errorMessage = message["message"].string
            default: break
            }
        }
    }

    private static func integer(_ value: JSONValue) -> Int? { if case .number(let number) = value, number.isFinite { return Int(number) }; return nil }
    private static func describeToolInput(_ input: JSONValue) -> String {
        for key in ["file_path", "path", "command", "pattern", "url", "query", "description"] { if let value = input[key].string, !value.isEmpty { return String(value.prefix(300)) } }
        return ""
    }
    static func bounded(_ text: String) -> String {
        text.utf8.count > replyLimit ? "…\n" + String(text.suffix(replyLimit / 2)) : text
    }

    /// Finds one JSON object in a reply: the whole text, a fenced block, or the outermost braces.
    public static func extractJSONObject(from text: String) -> Data? {
        var candidates = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let fence = text.range(of: "```"), let end = text.range(of: "```", range: fence.upperBound..<text.endIndex) {
            var inner = String(text[fence.upperBound..<end.lowerBound])
            if let newline = inner.firstIndex(of: "\n"), !inner[..<newline].contains("{") { inner = String(inner[inner.index(after: newline)...]) }
            candidates.append(inner)
        }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close { candidates.append(String(text[open...close])) }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else { continue }
            return data
        }
        return nil
    }
}
