import Foundation

public enum LoginState: String, Codable, Sendable {
    case unknown, checking, loggedIn, loggedOut, failed, unsupported
    public var title: String {
        switch self {
        case .unknown: return "待检测"
        case .checking: return "检测中"
        case .loggedIn: return "已登录"
        case .loggedOut: return "未登录"
        case .failed: return "检测失败"
        case .unsupported: return "未配置检测"
        }
    }
}

public struct LoginCheck: Equatable, Sendable {
    public var state: LoginState
    public var checkedAt: Date?
    public var detail: String
    public init(state: LoginState = .unknown, checkedAt: Date? = nil, detail: String = "") {
        self.state = state; self.checkedAt = checkedAt; self.detail = detail
    }
    /// The logged-out text wins over the exit code; otherwise exit 0 means logged in. Timeouts and other failures stay "failed".
    public static func classify(tool: ToolConfig, result: ProcessResult, output: String) -> LoginCheck {
        let state: LoginState
        let marker = tool.migratingLegacyAdapter().loggedOutText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if result.timedOut || result.cancelled { state = .failed }
        else if !marker.isEmpty && output.localizedCaseInsensitiveContains(marker) { state = .loggedOut }
        else if result.status == .review { state = .loggedIn }
        else { state = .failed }
        // Store a bounded diagnostic in memory only; CLI output may contain private account data.
        return LoginCheck(state: state, checkedAt: Date(), detail: String(output.suffix(2000)))
    }
}

extension ToolConfig {
    public var authenticationStatusArguments: [String]? {
        if adapterKind == .comfyUI { return nil }
        return migratingLegacyAdapter().loginStatusArguments.flatMap { $0.isEmpty ? nil : $0 }
    }
    public var authenticationLoginArguments: [String]? {
        if adapterKind == .comfyUI { return nil }
        return migratingLegacyAdapter().loginArguments.flatMap { $0.isEmpty ? nil : $0 }
    }
}
