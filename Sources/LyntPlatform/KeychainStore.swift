import Foundation
import Security

/// Credentials remain in the user's local Keychain; never in preferences or logs.
public struct KeychainStore: Sendable {
    public static let defaultService = "com.lynt.personal-writing-assistant.providers"
    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    public func get(_ providerID: String) throws -> String? {
        var query = try baseQuery(providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    public func set(_ value: String, for providerID: String) throws {
        let query = try baseQuery(providerID)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try delete(providerID)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public func delete(_ providerID: String) throws {
        let status = SecItemDelete(try baseQuery(providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(_ providerID: String) throws -> [String: Any] {
        guard !providerID.isEmpty, !service.isEmpty else { throw KeychainError.invalidAccount }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecAttrSynchronizable as String: false
        ]
    }
}

public enum KeychainError: LocalizedError, Equatable {
    case status(OSStatus)
    case invalidData
    case invalidAccount

    public var errorDescription: String? {
        switch self {
        case .status(let status): return "Keychain could not complete the request (status \(status))."
        case .invalidData: return "The stored API key could not be decoded. Save the key again."
        case .invalidAccount: return "The credential identifier is invalid."
        }
    }
}
