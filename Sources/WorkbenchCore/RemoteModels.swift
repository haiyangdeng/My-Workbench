import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var boolean: Bool? { if case .bool(let value) = self { return value }; return nil }
    public subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    public func replacingInput(_ input: String) -> JSONValue {
        switch self {
        case .string(let value): return .string(value.replacingOccurrences(of: "{input}", with: input))
        case .array(let value): return .array(value.map { $0.replacingInput(input) })
        case .object(let value): return .object(value.mapValues { $0.replacingInput(input) })
        default: return self
        }
    }
}

public struct SSHConnection: Codable, Equatable, Sendable {
    public var hostAlias: String
    public var localPort: Int
    public var remotePort: Int
    public init(hostAlias: String, localPort: Int = 8189, remotePort: Int = 8188) { self.hostAlias = hostAlias; self.localPort = localPort; self.remotePort = remotePort }
    public func arguments() throws -> [String] {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@-")
        guard !hostAlias.isEmpty, !hostAlias.hasPrefix("-"), hostAlias.unicodeScalars.allSatisfy(allowed.contains), (1024...65535).contains(localPort), (1...65535).contains(remotePort) else { throw RemoteError.invalidConfiguration }
        return ["-N", "-T", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30", hostAlias]
    }
}

public struct ComfyConnection: Codable, Equatable, Sendable {
    public var baseURL: String
    public var workflow: Data
    public var workflowName: String
    public var budgetNote: String
    public var maximumDownloadBytes: Int64
    public var requiresAPIKey: Bool
    public var ssh: SSHConnection?
    public init(baseURL: String, workflow: Data, workflowName: String, budgetNote: String = "价格未知，执行前检查服务预算", maximumDownloadBytes: Int64 = 512 * 1024 * 1024, requiresAPIKey: Bool = false, ssh: SSHConnection? = nil) {
        self.baseURL = baseURL; self.workflow = workflow; self.workflowName = workflowName; self.budgetNote = budgetNote
        self.maximumDownloadBytes = maximumDownloadBytes; self.requiresAPIKey = requiresAPIKey; self.ssh = ssh
    }
    public func workflow(input: String) throws -> JSONValue {
        guard workflow.count <= 5 * 1024 * 1024 else { throw RemoteError.invalidWorkflow }
        let json = try JSONDecoder().decode(JSONValue.self, from: workflow)
        guard let nodes = json.object, !nodes.isEmpty,
              nodes.values.allSatisfy({ $0["class_type"].string != nil && $0["inputs"].object != nil }) else { throw RemoteError.invalidWorkflow }
        return json.replacingInput(input)
    }
}

public struct RemoteArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var filename: String
    public var subfolder: String
    public var type: String
    public var byteCount: Int64?
    public var localArtifactID: UUID?
    public init(id: UUID = UUID(), filename: String, subfolder: String, type: String, byteCount: Int64? = nil) {
        self.id = id; self.filename = filename; self.subfolder = subfolder; self.type = type; self.byteCount = byteCount
    }
}

public enum RemoteJobState: Equatable, Sendable {
    case pending, running, success([RemoteArtifact]), failed(String), unknown
}
public enum RemoteError: LocalizedError {
    case invalidConfiguration, invalidWorkflow, http(Int), malformedResponse, unsafeCancellation, downloadLimit, sizeMismatch, ambiguousSubmission
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "请检查服务 URL、SSH 别名和端口。URL 不能含账号或密码。"
        case .invalidWorkflow: return "请选择不超过5MB、包含 class_type 与 inputs 的 ComfyUI API 工作流 JSON。"
        case .http(let code): return "服务返回 HTTP \(code)。请检查地址、登录和工作流配置。"
        case .malformedResponse: return "服务响应格式无法识别。请检查 ComfyUI API 兼容性。"
        case .unsafeCancellation: return "服务未提供可验证的单任务取消接口，远程任务仍需在服务端确认。"
        case .downloadLimit: return "远程文件超过允许下载大小，或服务未提供文件大小。"
        case .sizeMismatch: return "文件下载大小与服务声明不符，候选下载未加入产物。"
        case .ambiguousSubmission: return "提交结果不确定。执行编号已保留，请先查询服务端状态，不要直接重试。"
        }
    }
}
