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

/// How a server's SSH host key is checked. `acceptNew` trusts a host seen for the first time (a rented GPU instance is
/// often new) but still refuses a key that changed for a known host.
public enum SSHHostKeyPolicy: String, Codable, CaseIterable, Sendable {
    case strict, acceptNew
    public var title: String { self == .strict ? "只接受 known_hosts 中已有的主机" : "首次连接时信任新主机（已知主机换密钥仍会拒绝）" }
}

/// An SSH tunnel to a ComfyUI server: ComfyUI on the remote side is reached at 127.0.0.1:`localPort` on this Mac.
/// `hostAlias` is a Host from ~/.ssh/config or a host name or address; user, port and key override the config.
public struct SSHConnection: Codable, Equatable, Sendable {
    public var hostAlias: String
    public var localPort: Int
    public var remotePort: Int
    public var user: String?
    public var port: Int?
    public var identityFile: String?
    /// Log in with a password kept in the Keychain (answered through SSH_ASKPASS). Otherwise key or ssh-agent only.
    public var usesPassword: Bool?
    public var hostKeyPolicy: SSHHostKeyPolicy?
    /// Where ComfyUI listens as seen from the SSH host; 127.0.0.1 unless it runs on another machine behind it.
    public var remoteHost: String?
    public init(hostAlias: String, localPort: Int = 8189, remotePort: Int = 8188, user: String? = nil, port: Int? = nil, identityFile: String? = nil, usesPassword: Bool? = nil, hostKeyPolicy: SSHHostKeyPolicy? = nil, remoteHost: String? = nil) {
        self.hostAlias = hostAlias; self.localPort = localPort; self.remotePort = remotePort; self.user = user; self.port = port
        self.identityFile = identityFile; self.usesPassword = usesPassword; self.hostKeyPolicy = hostKeyPolicy; self.remoteHost = remoteHost
    }

    /// Checks every field before anything reaches ssh. Each value becomes its own argv element; nothing goes through a shell.
    public func validate() throws {
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._@-")
        let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !hostAlias.isEmpty, !hostAlias.hasPrefix("-"), hostAlias.unicodeScalars.allSatisfy(hostCharacters.contains) else { throw RemoteError.invalidConfiguration }
        guard (1024...65535).contains(localPort), (1...65535).contains(remotePort) else { throw RemoteError.invalidConfiguration }
        if let user { guard !user.isEmpty, !user.hasPrefix("-"), user.unicodeScalars.allSatisfy(nameCharacters.contains) else { throw RemoteError.invalidConfiguration } }
        if let port { guard (1...65535).contains(port) else { throw RemoteError.invalidConfiguration } }
        if let identityFile { guard identityFile.hasPrefix("/"), !identityFile.contains("\0") else { throw RemoteError.invalidConfiguration } }
        if let remoteHost { guard !remoteHost.isEmpty, !remoteHost.hasPrefix("-"), remoteHost.unicodeScalars.allSatisfy(nameCharacters.contains) else { throw RemoteError.invalidConfiguration } }
    }

    /// Options shared by the tunnel and the login probe.
    private func options() -> [String] {
        var result = ["-o", "StrictHostKeyChecking=\(hostKeyPolicy == .acceptNew ? "accept-new" : "yes")", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if usesPassword == true {
            result += ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1", "-o", "PreferredAuthentications=publickey,keyboard-interactive,password"]
        } else { result += ["-o", "BatchMode=yes"] }
        if let port { result += ["-p", String(port)] }
        if let identityFile { result += ["-i", identityFile, "-o", "IdentitiesOnly=yes"] }
        if let user { result += ["-l", user] }
        return result
    }
    /// The tunnel: forward 127.0.0.1:localPort here to remoteHost:remotePort there, and nothing else.
    public func arguments() throws -> [String] {
        try validate()
        return ["-N", "-T", "-L", "127.0.0.1:\(localPort):\(remoteHost ?? "127.0.0.1"):\(remotePort)", "-o", "ExitOnForwardFailure=yes"] + options() + [hostAlias]
    }
    /// A login check without a tunnel: runs `true` on the host.
    public func probeArguments() throws -> [String] {
        try validate()
        return ["-T"] + options() + [hostAlias, "true"]
    }

    /// What ssh's error output means for the user, in the terms they can act on.
    public static func diagnose(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("remote host identification has changed") { return "服务器的 SSH 主机密钥变了。云主机重装或换了 IP 后会这样；确认无误后，在终端运行 ssh-keygen -R <主机> 删除旧记录再连接。" }
        if text.contains("host key verification failed") || text.contains("no matching host key") { return "这台主机还不在 known_hosts 中。可以在服务器设置里选择“首次连接时信任新主机”，或先在终端用 ssh 连接一次。" }
        if text.contains("permission denied") { return "SSH 认证失败：用户名、私钥或密码不对，或者服务器不接受这种登录方式。" }
        if text.contains("could not resolve hostname") { return "无法解析主机名。请检查主机地址或 ~/.ssh/config 中的别名。" }
        if text.contains("forwarding failed") || text.contains("connect_to") || text.contains("open failed") { return "SSH 已连上，但转发到 ComfyUI 端口失败：ComfyUI 可能还没启动，或者端口不对。" }
        if text.contains("connection refused") { return "SSH 端口拒绝连接：云主机可能还没有启动完成，或者端口不对。" }
        if text.contains("timed out") || text.contains("operation timed out") { return "连接 SSH 超时：云主机可能已关机，或网络不通。" }
        if text.contains("address already in use") || text.contains("cannot listen to port") { return "本机端口已被占用。请在服务器设置里换一个本机端口。" }
        let last = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "没有输出"
        return "SSH 连接失败：" + last
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
