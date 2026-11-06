import Foundation
import Security

/// Where the identity is kept between runs. The client never makes one: the service does.
public protocol IdentityStore: Sendable {
    func load() async throws -> Identity?
    func save(_ identity: Identity?) async throws
}

public actor MemoryIdentityStore: IdentityStore {
    private var identity: Identity?
    public init(_ identity: Identity? = nil) { self.identity = identity }
    public func load() -> Identity? { identity }
    public func save(_ identity: Identity?) { self.identity = identity }
}

/// The Keychain: a generic password per product (`account`, your choice), this device only, readable
/// after the first unlock (so answers can be fetched in the background).
///
/// `accessGroup`: a keychain access group your apps share (their `keychain-access-groups` entitlement),
/// so another app of yours, the standalone reporter beside it, uses the same identity and the user's
/// tickets stay one thread. `dataProtection`: macOS's data protection keychain (as iOS has; it needs the
/// app signed with a keychain entitlement); off, the login keychain (an unsigned tool, tests).
public struct KeychainIdentityStore: IdentityStore {
    public let service: String
    public let account: String
    public let accessGroup: String?
    public let dataProtection: Bool

    public init(account: String, service: String = "alias-support", accessGroup: String? = nil, dataProtection: Bool = true) {
        self.account = account; self.service = service; self.accessGroup = accessGroup; self.dataProtection = dataProtection
    }

    private func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func load() throws -> Identity? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let data = out as? Data else { throw KeychainError(status: st) }
        return try? JSONDecoder().decode(Identity.self, from: data)
    }

    public func save(_ identity: Identity?) throws {
        let st0 = SecItemDelete(query() as CFDictionary)
        guard st0 == errSecSuccess || st0 == errSecItemNotFound else { throw KeychainError(status: st0) }
        guard let identity else { return }
        var q = query()
        q[kSecValueData as String] = try JSONEncoder().encode(identity)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw KeychainError(status: st) }
    }
}

public struct KeychainError: Error, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        "the keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)")
    }
}
