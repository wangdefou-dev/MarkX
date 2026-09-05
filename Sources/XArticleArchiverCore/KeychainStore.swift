import Foundation
import Security

public enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case readTimedOut
    case readCommandFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let code): "钥匙串操作失败（\(code)）"
        case .readTimedOut: "钥匙串读取超时；请检查是否有待处理的系统授权提示"
        case .readCommandFailed(let code): "钥匙串读取失败（\(code)）"
        }
    }
}

public enum KeychainStore {
    public static let service = "ai.defou.XArticleArchiver"
    public static let s3AccessKeyAccount = "s3-access-key"
    public static let s3SecretKeyAccount = "s3-secret-key"

    public static func save(_ value: String, account: String, service: String = service) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw KeychainStoreError.unexpectedStatus(updateStatus) }

        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(addStatus) }
    }

    public static func read(account: String, service: String = service) throws -> String? {
        // An ad-hoc signed local app can wait indefinitely inside
        // SecItemCopyMatching when another app owns the item's ACL (notably
        // Chrome Safe Storage). Apple's signed `security` helper is permitted
        // by the standard apple-tool partition and gives us a bounded read.
        // Secret bytes stay in the stdout pipe and are never logged.
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", service, "-a", account]
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 8) == .success else {
            process.terminate()
            throw KeychainStoreError.readTimedOut
        }

        var passwordData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let detail = String(data: errorData, encoding: .utf8) ?? ""
            if detail.localizedCaseInsensitiveContains("could not be found") {
                return nil
            }
            throw KeychainStoreError.readCommandFailed(process.terminationStatus)
        }
        while passwordData.last == 0x0A || passwordData.last == 0x0D {
            passwordData.removeLast()
        }
        return String(data: passwordData, encoding: .utf8)
    }

    public static func delete(account: String, service: String = service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let itemStatus = SecItemDelete(query as CFDictionary)
        guard itemStatus == errSecSuccess || itemStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(itemStatus)
        }
    }
}
