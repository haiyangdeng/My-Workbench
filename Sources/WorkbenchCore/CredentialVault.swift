import Foundation
import Security

public struct CredentialVault {
    private let service: String
    public init(service: String = "com.ocean.myworkbench.remote") { self.service = service }
    /// Secret environment variables of CLI definitions, one item per CLI and variable name.
    public static let cliEnvironment = CredentialVault(service: "com.ocean.myworkbench.cli-environment")
    public static func account(toolID: UUID, name: String) -> String { toolID.uuidString + "/" + name }

    public func read(account: String) throws -> String? {
        var query = base(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw error(status) }
        return String(data: data, encoding: .utf8)
    }
    public func save(_ value: String, account: String) throws {
        let data = Data(value.utf8), query = base(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil); guard added == errSecSuccess else { throw error(added) }
        } else if status != errSecSuccess { throw error(status) }
    }
    public func remove(account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private func base(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    // Server tokens are stored under the server's (or legacy tool's) ID.
    public func read(toolID: UUID) throws -> String? { try read(account: toolID.uuidString) }
    public func save(_ value: String, toolID: UUID) throws { try save(value, account: toolID.uuidString) }
    public func remove(toolID: UUID) throws { try remove(account: toolID.uuidString) }
    private func error(_ status: OSStatus) -> Error {
        NSError(domain: "MyWorkbench.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "钥匙串访问失败：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"])
    }
}
