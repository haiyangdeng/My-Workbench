import CryptoKit
import Foundation

/// A ComfyUI server, usually on a cloud GPU. Its token, if any, lives in the Keychain under the server's ID.
public struct ComfyServer: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var name: String
    public var baseURL: String
    public var ssh: SSHConnection?
    public var requiresToken: Bool
    public var hourlyPrice: Double?
    public var currency: String?
    public var maximumDownloadBytes: Int64
    public var maximumUploadBytes: Int64
    public var jobLimit: Int
    public var timeoutSeconds: Double
    public var enabled: Bool
    public var legacyToolID: UUID?
    public init(id: UUID = UUID(), name: String, baseURL: String, ssh: SSHConnection? = nil, requiresToken: Bool = false, hourlyPrice: Double? = nil, currency: String? = nil, maximumDownloadBytes: Int64 = 512 * 1024 * 1024, maximumUploadBytes: Int64 = 200 * 1024 * 1024, jobLimit: Int = 1, timeoutSeconds: Double = 3600, enabled: Bool = true) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.ssh = ssh; self.requiresToken = requiresToken; self.hourlyPrice = hourlyPrice; self.currency = currency
        self.maximumDownloadBytes = maximumDownloadBytes; self.maximumUploadBytes = maximumUploadBytes; self.jobLimit = jobLimit; self.timeoutSeconds = timeoutSeconds; self.enabled = enabled
    }
    /// With an SSH tunnel the server is reached on localhost.
    public var endpoint: String { ssh.map { "http://127.0.0.1:\($0.localPort)" } ?? baseURL }
    public func connection(workflow: Data = Data("{}".utf8), name: String = "") -> ComfyConnection {
        ComfyConnection(baseURL: endpoint, workflow: workflow, workflowName: name, budgetNote: hourlyPrice.map { "约 \($0) \(currency ?? "") / 小时" } ?? "价格未知", maximumDownloadBytes: maximumDownloadBytes, requiresAPIKey: requiresToken, ssh: ssh)
    }
    public func estimatedCost(seconds: Double) -> Double? { hourlyPrice.map { $0 * seconds / 3600 } }
    public var timeout: TimeInterval { timeoutSeconds.isFinite ? min(86400, max(1, timeoutSeconds)) : 3600 }
}

public struct ServerHealth: Equatable, Sendable {
    public var version: String?
    public var gpu: String?
    public var vramTotal: Int64?
    public var vramFree: Int64?
    public var queueLength: Int?
    public var supportsJobCancel: Bool
    public var checkedAt: Date
    public var error: String?
    /// Node classes installed on the server (MD-03), when object_info could be read.
    public var nodeClasses: Set<String>?
    public init(version: String? = nil, gpu: String? = nil, vramTotal: Int64? = nil, vramFree: Int64? = nil, queueLength: Int? = nil, supportsJobCancel: Bool = false, checkedAt: Date = Date(), error: String? = nil) {
        self.version = version; self.gpu = gpu; self.vramTotal = vramTotal; self.vramFree = vramFree; self.queueLength = queueLength; self.supportsJobCancel = supportsJobCancel; self.checkedAt = checkedAt; self.error = error
    }
    public var usable: Bool { error == nil && supportsJobCancel }
}

public enum ParameterType: String, Codable, CaseIterable, Sendable {
    case text, integer, number, seed, boolean, choice, image, audio, video
    public var isFile: Bool { self == .image || self == .audio || self == .video }
    public var title: String {
        switch self {
        case .text: return "文本"
        case .integer: return "整数"
        case .number: return "数字"
        case .seed: return "种子"
        case .boolean: return "开关"
        case .choice: return "选项"
        case .image: return "图片文件"
        case .audio: return "音频文件"
        case .video: return "视频文件"
        }
    }
    public var mediaKind: MediaKind? { self == .image ? .image : (self == .audio ? .audio : (self == .video ? .video : nil)) }
}

public enum MediaKind: String, Codable, CaseIterable, Sendable {
    case image, video, audio, other
    public var title: String { ["image": "图片", "video": "视频", "audio": "音频", "other": "其他"][rawValue]! }
    public static func of(fileExtension ext: String) -> MediaKind {
        switch ext.lowercased() {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "bmp", "tif", "tiff": return .image
        case "mp4", "mov", "webm", "mkv", "m4v", "avi": return .video
        case "wav", "mp3", "flac", "ogg", "m4a", "aac", "aiff", "opus": return .audio
        default: return .other
        }
    }
}

/// One node input the user exposed as a named parameter.
public struct TemplateParameter: Identifiable, Codable, Equatable, Sendable {
    public var name: String
    public var nodeID: String
    public var inputName: String
    public var type: ParameterType
    public var defaultValue: JSONValue?
    public var minimum: Double?
    public var maximum: Double?
    public var choices: [String]?
    public var description: String
    public var id: String { name }
    public init(name: String, nodeID: String, inputName: String, type: ParameterType, defaultValue: JSONValue? = nil, minimum: Double? = nil, maximum: Double? = nil, choices: [String]? = nil, description: String = "") {
        self.name = name; self.nodeID = nodeID; self.inputName = inputName; self.type = type; self.defaultValue = defaultValue
        self.minimum = minimum; self.maximum = maximum; self.choices = choices; self.description = description
    }

    /// Reads a value written as text (by the user, a director or a reviewer) according to the parameter's type.
    public func parse(_ text: String) throws -> JSONValue {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .text: return .string(text)
        case .image, .audio, .video:
            guard !value.isEmpty else { throw MediaError.invalidValue(name) }
            return .string(value)
        case .boolean:
            if ["true", "yes", "1", "是", "开"].contains(value.lowercased()) { return .bool(true) }
            if ["false", "no", "0", "否", "关"].contains(value.lowercased()) { return .bool(false) }
            throw MediaError.invalidValue(name)
        case .choice:
            guard choices?.contains(value) ?? false else { throw MediaError.invalidValue(name) }
            return .string(value)
        case .seed:
            if value.isEmpty || value.lowercased() == "random" || value == "随机" { return .string("random") }
            guard let number = UInt64(value), number <= UInt64(UInt32.max) * 4096 else { throw MediaError.invalidValue(name) }
            return .number(Double(number))
        case .integer, .number:
            guard let number = Double(value), number.isFinite, type == .number || number.rounded() == number else { throw MediaError.invalidValue(name) }
            return .number(number)
        }
    }

    /// Checks limits; a random seed becomes a concrete number so the run can be repeated.
    public func normalize(_ value: JSONValue?, seed: () -> UInt32) throws -> JSONValue {
        guard let value = value ?? defaultValue else {
            if type == .seed { return .number(Double(seed())) }
            throw MediaError.missingValue(name)
        }
        switch (type, value) {
        case (.seed, .string(let text)) where text == "random": return .number(Double(seed()))
        case (.seed, .number(let number)) where number < 0: return .number(Double(seed()))
        case (.integer, .number(let number)), (.number, .number(let number)), (.seed, .number(let number)):
            if let minimum, number < minimum { throw MediaError.outOfRange(name) }
            if let maximum, number > maximum { throw MediaError.outOfRange(name) }
            return value
        case (.text, .string), (.image, .string), (.audio, .string), (.video, .string), (.boolean, .bool): return value
        case (.choice, .string(let text)):
            guard choices?.contains(text) ?? false else { throw MediaError.invalidValue(name) }
            return value
        default: throw MediaError.invalidValue(name)
        }
    }
}

public struct TemplateOutput: Codable, Equatable, Sendable {
    public var nodeID: String
    public var kind: MediaKind
    public init(nodeID: String, kind: MediaKind) { self.nodeID = nodeID; self.kind = kind }
}

public struct NodeInput: Identifiable, Equatable, Sendable {
    public var nodeID: String
    public var classType: String
    public var title: String
    public var inputName: String
    public var value: JSONValue
    public var id: String { nodeID + "." + inputName }
}

/// An imported API-format workflow with the inputs the user chose to expose and the outputs that count as results.
public struct WorkflowTemplate: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var deletedAt: Date?
    public var name: String
    public var description: String
    public var moduleIDs: [UUID]
    public var workflow: Data
    public var versionHash: String
    public var parameters: [TemplateParameter]
    public var outputs: [TemplateOutput]
    public var estimatedSeconds: Double?
    public var thumbnail: Data?
    public var legacyToolID: UUID?
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, description: String = "", moduleIDs: [UUID] = [], workflow: Data, parameters: [TemplateParameter] = [], outputs: [TemplateOutput] = [], estimatedSeconds: Double? = nil) {
        self.id = id; self.name = name; self.description = description; self.moduleIDs = moduleIDs; self.workflow = workflow
        versionHash = Self.hash(workflow); self.parameters = parameters; self.outputs = outputs; self.estimatedSeconds = estimatedSeconds; createdAt = Date()
    }

    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description }

    /// Accepts only API-format workflows: an object of nodes that each have class_type and inputs.
    public static func nodes(of data: Data) throws -> [String: JSONValue] {
        guard data.count <= 5 * 1024 * 1024 else { throw RemoteError.invalidWorkflow }
        guard let nodes = try JSONDecoder().decode(JSONValue.self, from: data).object, !nodes.isEmpty,
              nodes.values.allSatisfy({ $0["class_type"].string != nil && $0["inputs"].object != nil }) else { throw RemoteError.invalidWorkflow }
        return nodes
    }

    /// Literal inputs (not links to other nodes) that can be exposed.
    public static func candidateInputs(of data: Data) -> [NodeInput] {
        guard let nodes = try? nodes(of: data) else { return [] }
        var result: [NodeInput] = []
        for (nodeID, node) in nodes {
            let classType = node["class_type"].string ?? ""
            let title = node["_meta"]["title"].string ?? classType
            for (input, value) in node["inputs"].object ?? [:] {
                switch value { case .string, .number, .bool: result.append(NodeInput(nodeID: nodeID, classType: classType, title: title, inputName: input, value: value)); default: break }
            }
        }
        return result.sorted { (Int($0.nodeID) ?? Int.max, $0.nodeID, $0.inputName) < (Int($1.nodeID) ?? Int.max, $1.nodeID, $1.inputName) }
    }

    static let outputClasses: [String: MediaKind] = [
        "SaveImage": .image, "PreviewImage": .image, "Image Save": .image,
        "VHS_VideoCombine": .video, "SaveVideo": .video, "SaveWEBM": .video, "SaveAnimatedWEBP": .video, "SaveAnimatedPNG": .video,
        "SaveAudio": .audio, "SaveAudioMP3": .audio, "SaveAudioOpus": .audio, "PreviewAudio": .audio
    ]

    /// First guess at parameters and outputs for common nodes. The user reviews and edits the mapping.
    public static func suggest(for data: Data) -> (parameters: [TemplateParameter], outputs: [TemplateOutput]) {
        guard let nodes = try? nodes(of: data) else { return ([], []) }
        var parameters: [TemplateParameter] = []
        func add(_ name: String, _ input: NodeInput, _ type: ParameterType, _ description: String) {
            guard !parameters.contains(where: { $0.name == name || ($0.nodeID == input.nodeID && $0.inputName == input.inputName) }) else { return }
            parameters.append(TemplateParameter(name: name, nodeID: input.nodeID, inputName: input.inputName, type: type, defaultValue: type == .seed ? .string("random") : input.value, minimum: type == .seed ? 0 : nil, description: description))
        }
        let inputs = candidateInputs(of: data)
        for input in inputs where input.value.string?.contains("{input}") == true { add("input", input, .text, "旧版工作流中的 {input} 文本") }
        for input in inputs where input.classType.hasPrefix("CLIPTextEncode") && input.inputName == "text" {
            let negative = input.title.localizedCaseInsensitiveContains("negative") || input.title.contains("负")
            add(negative ? "negative_prompt" : (parameters.contains { $0.name == "prompt" } ? "negative_prompt" : "prompt"), input, .text, negative ? "不希望出现的内容" : "画面或内容描述")
        }
        for input in inputs where ["seed", "noise_seed"].contains(input.inputName) { add("seed", input, .seed, "随机种子；random 表示提交前随机生成") }
        for input in inputs where input.inputName == "image" && input.classType.contains("LoadImage") { add(parameters.contains { $0.name == "image" } ? "image_\(input.nodeID)" : "image", input, .image, "参考图片") }
        for input in inputs where input.inputName == "audio" && input.classType.contains("LoadAudio") { add("audio", input, .audio, "参考音频") }
        for input in inputs where input.inputName == "video" && input.classType.contains("LoadVideo") { add("video", input, .video, "参考视频") }
        for input in inputs where ["width", "height"].contains(input.inputName) && input.classType.contains("Latent") { add(input.inputName, input, .integer, input.inputName == "width" ? "宽度（像素）" : "高度（像素）") }
        for input in inputs where ["length", "frame_count", "num_frames", "frames"].contains(input.inputName) { add("frames", input, .integer, "帧数") }
        for input in inputs where ["steps"].contains(input.inputName) && input.classType.contains("KSampler") { add("steps", input, .integer, "采样步数") }
        let outputs = nodes.compactMap { id, node in outputClasses[node["class_type"].string ?? ""].map { TemplateOutput(nodeID: id, kind: $0) } }.sorted { $0.nodeID < $1.nodeID }
        return (parameters, outputs)
    }

    public func parameter(_ name: String) -> TemplateParameter? { parameters.first { $0.name == name } }

    /// Fills every parameter from `values` or its default; unknown names are refused.
    public func normalize(_ values: [String: JSONValue], seed: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) throws -> [String: JSONValue] {
        if let unknown = values.keys.first(where: { parameter($0) == nil }) { throw MediaError.unknownParameter(unknown) }
        var result: [String: JSONValue] = [:]
        for parameter in parameters { result[parameter.name] = try parameter.normalize(values[parameter.name], seed: seed) }
        return result
    }

    /// Writes normalized values into the workflow's node inputs.
    public func resolve(_ values: [String: JSONValue]) throws -> Data {
        var nodes = try Self.nodes(of: workflow)
        for parameter in parameters {
            guard var value = values[parameter.name], var node = nodes[parameter.nodeID]?.object, var inputs = node["inputs"]?.object else { throw MediaError.missingValue(parameter.name) }
            // Text written around a {name} placeholder in the workflow is kept, as old {input} workflows expect.
            if case .string(let original) = inputs[parameter.inputName], original.contains("{\(parameter.name)}"), case .string(let text) = value {
                value = .string(original.replacingOccurrences(of: "{\(parameter.name)}", with: text))
            }
            inputs[parameter.inputName] = value; node["inputs"] = .object(inputs); nodes[parameter.nodeID] = .object(node)
        }
        return try JSONEncoder().encode(JSONValue.object(nodes))
    }

    /// Checks the mapping still matches the workflow (nodes and inputs exist, names unique, outputs exist).
    /// Node classes the workflow uses that the server does not have (MD-03). Empty when the list is unknown.
    public func missingNodes(on health: ServerHealth?) -> [String] {
        guard let installed = health?.nodeClasses, let nodes = try? Self.nodes(of: workflow) else { return [] }
        return Set(nodes.values.compactMap { $0["class_type"].string }).subtracting(installed).sorted()
    }

    public func validateMapping() throws {
        let nodes = try Self.nodes(of: workflow)
        guard Set(parameters.map(\.name)).count == parameters.count else { throw MediaError.invalidTemplate("参数名称重复") }
        for parameter in parameters {
            guard !parameter.name.isEmpty, parameter.name.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,40}$", options: .regularExpression) != nil else { throw MediaError.invalidTemplate("参数名「\(parameter.name)」只能使用字母、数字和下划线") }
            guard nodes[parameter.nodeID]?["inputs"].object?[parameter.inputName] != nil else { throw MediaError.invalidTemplate("节点 \(parameter.nodeID) 没有输入 \(parameter.inputName)") }
            if parameter.type == .choice && (parameter.choices ?? []).isEmpty { throw MediaError.invalidTemplate("选项参数「\(parameter.name)」需要至少一个选项") }
        }
        for output in outputs where nodes[output.nodeID] == nil { throw MediaError.invalidTemplate("输出节点 \(output.nodeID) 不存在") }
    }

    /// Typical duration on a server: the median of past runs there, else the user's estimate.
    public func estimate(on serverID: UUID, history: [TaskRun]) -> Double? {
        let matching = history.filter { run in run.generation?.templateID == id && run.generation?.serverID == serverID && (run.status == .completed || run.status == .review) }
        let durations = matching.compactMap { run in run.endedAt.map { $0.timeIntervalSince(run.startedAt) } }.sorted()
        guard !durations.isEmpty else { return estimatedSeconds }
        return durations[durations.count / 2]
    }
}

/// A generation job: which template runs on which server with which values and input files.
public struct GenerationSpec: Codable, Equatable, Sendable {
    public var templateID: UUID
    public var serverID: UUID
    /// Values as entered; seeds may still say "random" until the job is submitted.
    public var values: [String: JSONValue]
    /// File parameters: a local path, or "task:<UUID>" for an accepted output of an earlier step.
    public var inputs: [String: String]
    public var versionHash: String
    /// After submission: every value as sent, including concrete seeds and uploaded file names.
    public var submittedValues: [String: JSONValue]?
    /// Run the job this many times with different seeds; the user picks which results go on (MD-13).
    public var variantCount: Int?
    public var variants: Int { min(8, max(1, variantCount ?? 1)) }
    public init(templateID: UUID, serverID: UUID, values: [String: JSONValue] = [:], inputs: [String: String] = [:], versionHash: String) {
        self.templateID = templateID; self.serverID = serverID; self.values = values; self.inputs = inputs; self.versionHash = versionHash
    }
}

/// A command step, for example ffmpeg joining clips. `{input:<task UUID>}` expands to that step's accepted files.
public struct CommandSpec: Codable, Equatable, Sendable {
    public var toolID: UUID
    public var arguments: [String]
    public init(toolID: UUID, arguments: [String]) { self.toolID = toolID; self.arguments = arguments }
}

public struct NamedValue: Codable, Equatable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public enum MediaError: LocalizedError, Equatable {
    case missingValue(String), invalidValue(String), outOfRange(String), unknownParameter(String), invalidTemplate(String), missingInput(String), uploadTooLarge, serverUnavailable(String), invalidStep(String)
    public var errorDescription: String? {
        switch self {
        case .missingValue(let name): return "参数「\(name)」没有值。"
        case .invalidValue(let name): return "参数「\(name)」的值不符合类型。"
        case .outOfRange(let name): return "参数「\(name)」超出允许范围。"
        case .unknownParameter(let name): return "模板没有参数「\(name)」。"
        case .invalidTemplate(let reason): return "模板无效：\(reason)"
        case .missingInput(let name): return "文件参数「\(name)」找不到可用的文件。"
        case .uploadTooLarge: return "上传文件超过服务器设置的上限。"
        case .serverUnavailable(let reason): return "服务器不可用：\(reason)"
        case .invalidStep(let reason): return "制作计划无效：\(reason)"
        }
    }
}

extension WorkspaceSnapshot {
    public func server(_ id: UUID?) -> ComfyServer? { id.flatMap { id in servers.first { $0.id == id } } }
    public func template(_ id: UUID?) -> WorkflowTemplate? { id.flatMap { id in templates.first { $0.id == id } } }

    /// Every legacy ComfyUI tool also appears as a server and a template with an `input` parameter. Idempotent.
    public mutating func migrateLegacyComfyTools() {
        for tool in tools where tool.adapterKind == .comfyUI {
            guard let remote = tool.remote else { continue }
            if !servers.contains(where: { $0.legacyToolID == tool.id || $0.id == tool.id }) {
                var server = ComfyServer(id: tool.id, name: tool.name, baseURL: remote.ssh == nil ? remote.baseURL : "http://127.0.0.1:\(remote.ssh!.remotePort)", ssh: remote.ssh, requiresToken: remote.requiresAPIKey, maximumDownloadBytes: remote.maximumDownloadBytes, timeoutSeconds: tool.timeout, enabled: tool.isEnabled)
                server.legacyToolID = tool.id
                servers.append(server)
            }
            if !templates.contains(where: { $0.legacyToolID == tool.id }) {
                let suggestion = WorkflowTemplate.suggest(for: remote.workflow)
                var template = WorkflowTemplate(name: remote.workflowName, description: "由旧版 ComfyUI 工具转换", moduleIDs: [WorkArea.defaults[0].id], workflow: remote.workflow, parameters: suggestion.parameters.filter { $0.name == "input" }, outputs: suggestion.outputs)
                template.legacyToolID = tool.id
                templates.append(template)
            }
        }
    }
}
