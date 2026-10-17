import Foundation
import Security

public struct CredentialVault {
    private let service = "com.ocean.myworkbench.remote"
    public init() {}
    public func read(toolID: UUID) throws -> String? {
        var query = base(toolID); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw error(status) }
        return String(data: data, encoding: .utf8)
    }
    public func save(_ value: String, toolID: UUID) throws {
        let data = Data(value.utf8), query = base(toolID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil); guard added == errSecSuccess else { throw error(added) }
        } else if status != errSecSuccess { throw error(status) }
    }
    public func remove(toolID: UUID) throws {
        let status = SecItemDelete(base(toolID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private func base(_ id: UUID) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] }
    private func error(_ status: OSStatus) -> Error {
        NSError(domain: "MyWorkbench.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "钥匙串访问失败：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"])
    }
}
