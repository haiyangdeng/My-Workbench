import Foundation

/// How the workbench reads a CLI's stdout. The app ships no CLI presets; the user picks a format per CLI.
public enum CLIOutputFormat: String, Codable, CaseIterable, Sendable {
    case plainText, streamJSON, jsonLines
    public var title: String {
        switch self {
        case .plainText: return "纯文本"
        case .streamJSON: return "stream-json 事件（Claude Code 格式）"
        case .jsonLines: return "JSONL 事件（Codex 格式）"
        }
    }
}

public enum AccessLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case readOnly, edit
    public var title: String { self == .readOnly ? "只读" : "可编辑项目" }
    public static func < (lhs: AccessLevel, rhs: AccessLevel) -> Bool { lhs == .readOnly && rhs == .edit }
}

public enum CLIError: LocalizedError, Equatable {
    case accessUnsupported(AccessLevel), resumeUnsupported, missingSession
    public var errorDescription: String? {
        switch self {
        case .accessUnsupported(let level): return "这个 CLI 没有配置「\(level.title)」所需的参数，无法以该权限运行。请在工具连接中补充。"
        case .resumeUnsupported: return "这个 CLI 没有配置续接会话参数。"
        case .missingSession: return "没有可续接的会话编号。"
        }
    }
}

public enum CLIEnvironmentError: LocalizedError, Equatable {
    case invalidLine(String), invalidName(String), reserved(String), duplicate(String)
    public var errorDescription: String? {
        switch self {
        case .invalidLine(let line): return "环境变量每行写成 NAME=value：「\(line)」"
        case .invalidName(let name): return "环境变量名只能用字母、数字和下划线，且不能以数字开头：「\(name)」"
        case .reserved(let name): return "「\(name)」由工作台使用，不能自行设置。"
        case .duplicate(let name): return "环境变量「\(name)」重复了。"
        }
    }
}

extension ToolConfig {
    /// Reads "NAME=value" lines. Names use letters, digits and underscores and do not start with a digit; MYWORKBENCH_* is
    /// reserved. Blank lines are skipped. The value is everything after the first "=" and may be empty.
    public static func parseEnvironment(_ text: String) throws -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = [], seen: Set<String> = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let equals = line.firstIndex(of: "=") else { throw CLIEnvironmentError.invalidLine(line) }
            let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces), value = String(line[line.index(after: equals)...])
            guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first),
                  name.unicodeScalars.allSatisfy({ $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }) else { throw CLIEnvironmentError.invalidName(name) }
            if name.uppercased().hasPrefix("MYWORKBENCH_") { throw CLIEnvironmentError.reserved(name) }
            guard seen.insert(name).inserted else { throw CLIEnvironmentError.duplicate(name) }
            result.append((name, value))
        }
        return result
    }
}

public struct CLIInvocation: Sendable {
    public var prompt: String
    public var instructions: String
    public var outputDirectory: String
    public var workingDirectory: String
    public var model: String?
    public var access: AccessLevel
    public var schema: String?
    public var schemaFile: String?
    public var sessionID: String?
    public var resume: Bool
    public init(prompt: String, instructions: String = "", outputDirectory: String, workingDirectory: String, model: String? = nil, access: AccessLevel = .readOnly, schema: String? = nil, schemaFile: String? = nil, sessionID: String? = nil, resume: Bool = false) {
        self.prompt = prompt; self.instructions = instructions; self.outputDirectory = outputDirectory; self.workingDirectory = workingDirectory
        self.model = model; self.access = access; self.schema = schema; self.schemaFile = schemaFile; self.sessionID = sessionID; self.resume = resume
    }
}

extension ToolConfig {
    public static let flagsPlaceholder = "{flags}"
    /// Option values that skip the CLI's own approvals. Used only to warn; the user still decides.
    public static let knownBypassFlags = ["bypassPermissions", "--dangerously-skip-permissions", "danger-full-access", "--dangerously-bypass-approvals-and-sandbox", "--yolo"]

    public var isCLI: Bool { adapterKind != .comfyUI }
    public var executableAvailable: Bool { executable.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: executable) }
    public var format: CLIOutputFormat { outputFormat ?? .plainText }
    /// A CLI that defines no access flags at all is not access-managed: the workbench says so and runs its templates as written.
    public var managesAccess: Bool { !(readOnlyArguments ?? []).isEmpty || !(editArguments ?? []).isEmpty }
    public func accessArguments(_ level: AccessLevel) -> [String] { (level == .readOnly ? readOnlyArguments : editArguments) ?? [] }
    public func supports(_ level: AccessLevel) -> Bool { !managesAccess || !accessArguments(level).isEmpty }
    public var supportsResume: Bool { !(resumeArguments ?? []).isEmpty }
    public var supportsTerminalResume: Bool { !(interactiveResumeArguments ?? []).isEmpty }
    /// argv for continuing a headless session interactively in the built-in terminal.
    public func terminalResumeArguments(sessionID: String) -> [String] {
        (interactiveResumeArguments ?? []).map { Self.expand($0, values: ["session_id": sessionID]) }
    }
    public var usesInstructionsPlaceholder: Bool { allTemplateArguments.contains { $0.contains("{instructions}") } }
    /// When the new-turn template carries {session_id}, the workbench chooses the session ID; otherwise it is read from the output.
    public var assignsSessionID: Bool { arguments.contains { $0.contains("{session_id}") } }
    /// Every template and fragment the user wrote, for scanning.
    public var allTemplateArguments: [String] {
        var all = arguments
        for fragment in [resumeArguments, readOnlyArguments, editArguments, modelArguments, structuredOutputArguments, interactiveResumeArguments] { all += fragment ?? [] }
        return all
    }
    public var bypassWarnings: [String] {
        let all = allTemplateArguments
        return Self.knownBypassFlags.filter { flag in all.contains { $0.contains(flag) } }
    }

    /// The prompt text actually sent, including agent instructions and, without a schema flag, the JSON instruction.
    public func effectivePrompt(_ call: CLIInvocation) -> String {
        var prompt = call.prompt
        var templates: [String] = call.resume ? (resumeArguments ?? []) : arguments
        templates += accessArguments(call.access)
        templates += modelArguments ?? []
        templates += structuredOutputArguments ?? []
        if includeInstructions == true, !call.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !templates.contains(where: { $0.contains("{instructions}") }) {
            prompt = "职责：\n\(call.instructions)\n\n任务：\n\(prompt)"
        }
        if let schema = call.schema, (structuredOutputArguments ?? []).isEmpty {
            prompt += "\n\n只返回一个符合以下 JSON Schema 的 JSON 对象，不要输出其他文字：\n\(schema)"
        }
        return prompt
    }

    /// Builds argv without a shell. Each placeholder fills exactly one argument, except a standalone {flags},
    /// which expands to the access, model and structured-output fragments.
    public func invocation(_ call: CLIInvocation) throws -> [String] {
        let template: [String]
        if call.resume {
            guard supportsResume else { throw CLIError.resumeUnsupported }
            guard let session = call.sessionID, !session.isEmpty else { throw CLIError.missingSession }
            template = resumeArguments ?? []
        } else { template = arguments }
        guard supports(call.access) else { throw CLIError.accessUnsupported(call.access) }
        let prompt = effectivePrompt(call)
        let values: [String: String] = [
            "prompt": prompt, "input": prompt, "output": call.outputDirectory, "workdir": call.workingDirectory,
            "model": call.model ?? "", "instructions": call.instructions, "schema": call.schema ?? "",
            "schema_file": call.schemaFile ?? "", "session_id": call.sessionID ?? ""
        ]
        var flags = accessArguments(call.access)
        if let model = call.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flags += modelArguments ?? [] }
        if call.schema != nil { flags += structuredOutputArguments ?? [] }
        let expandedFlags = flags.map { Self.expand($0, values: values) }
        var result: [String] = []
        var placedFlags = false
        for element in template {
            if element == Self.flagsPlaceholder { result += expandedFlags; placedFlags = true }
            else { result.append(Self.expand(element, values: values)) }
        }
        if !placedFlags {
            if let separator = template.firstIndex(of: "--") { result.insert(contentsOf: expandedFlags, at: separator) }
            else { result += expandedFlags }
        }
        return result
    }

    /// Single pass: text substituted into an argument is never scanned again, so a prompt containing "{output}" stays literal.
    public static func expand(_ template: String, values: [String: String]) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let name = String(template[template.index(after: index)..<close])
                if let value = values[name] { result += value; index = template.index(after: close); continue }
            }
            result.append(template[index]); index = template.index(after: index)
        }
        return result
    }

    /// Converts the retired built-in Codex adapter into an ordinary CLI definition with the same behavior.
    public func migratingLegacyAdapter() -> ToolConfig {
        guard adapter == .codex else { return self }
        var tool = self
        tool.adapter = .command
        tool.arguments = ["exec", "--json", "--skip-git-repo-check", "--output-last-message", "{output}/result.md", Self.flagsPlaceholder, "--", "{prompt}"]
        tool.outputFormat = .jsonLines
        tool.includeInstructions = true
        tool.readOnlyArguments = ["--sandbox", "read-only"]
        tool.editArguments = ["--sandbox", "workspace-write", "--add-dir", "{output}"]
        tool.structuredOutputArguments = ["--output-schema", "{schema_file}"]
        tool.modelArguments = ["--model", "{model}"]
        tool.loginStatusArguments = ["login", "status"]
        tool.loginArguments = ["login"]
        tool.loggedOutText = "Not logged in"
        return tool
    }
}
