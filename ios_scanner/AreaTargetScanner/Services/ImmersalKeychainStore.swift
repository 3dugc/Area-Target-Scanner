import Foundation
import Security

protocol ImmersalCredentialStoring {
    func load() throws -> ImmersalCredential?
    func save(_ credential: ImmersalCredential) throws
    func clear() throws
}

final class ImmersalKeychainStore: ImmersalCredentialStoring {
    private let service: String
    init(service: String = "com.areatarget.scanner.immersal") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api.immersal.com",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> ImmersalCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw StoreError.invalidData }
        return try JSONDecoder().decode(ImmersalCredential.self, from: data)
    }

    func save(_ credential: ImmersalCredential) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    enum StoreError: Error, LocalizedError {
        case invalidData, keychain(OSStatus)
        var errorDescription: String? { "无法访问本机登录凭据，请解锁设备后重试。" }
    }
}
