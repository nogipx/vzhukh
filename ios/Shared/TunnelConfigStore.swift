import Foundation
import Security

/// Passes the tunnel configuration from the app to the extension.
///
/// It goes through the keychain rather than through `providerConfiguration`,
/// which is the other obvious route, because that dictionary is stored in the
/// system's VPN preferences and holds SSH private keys here. The keychain is
/// the place built for that, and a shared access group is what lets two
/// processes of the same team reach one item.
enum TunnelConfigStore {
    /// The access group, team prefix included. It is read from the bundle
    /// rather than written out, because the prefix is the team ID and
    /// hard-coding one would break the moment the project is built by another
    /// account. Both Info.plists carry `$(AppIdentifierPrefix)dev.nogipx.vzhukh`,
    /// which Xcode expands at build time.
    static var accessGroup: String {
        let group = Bundle.main.object(forInfoDictionaryKey: "VZKeychainAccessGroup") as? String

        guard let group, hasTeamPrefix(group) else {
            // Two ways this goes wrong, and both produce a keychain error that
            // names nothing: the entry is missing, or AppIdentifierPrefix
            // expanded to nothing because the build was not signed. Fail here
            // instead, where the reason is still visible.
            fatalError(
                "VZKeychainAccessGroup is \(group ?? "missing"), which carries no team prefix. "
                    + "An unsigned build cannot reach the shared keychain."
            )
        }

        return group
    }

    /// A usable group is a ten-character team ID, a dot, then the identifier.
    private static func hasTeamPrefix(_ group: String) -> Bool {
        let parts = group.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return false }

        let prefix = parts[0]
        return prefix.count == 10 && prefix.allSatisfy { $0.isNumber || $0.isUppercase }
    }

    private static let service = "dev.nogipx.vzhukh.tunnel"
    private static let account = "active-configuration"

    enum StoreError: LocalizedError {
        case notFound
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No tunnel configuration has been saved."
            case let .keychain(status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
                return "Keychain error: \(detail)"
            }
        }
    }

    /// Replaces the stored configuration.
    static func save(_ configuration: TunnelConfiguration) throws {
        let payload = try configuration.encoded()

        var query = baseQuery()
        query[kSecValueData as String] = payload
        // After first unlock, not when-unlocked: a tunnel can be started by
        // the system while the phone is still locked, and an item the
        // extension cannot read then would fail in a way that only shows up
        // on a locked device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemDelete(baseQuery() as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    static func load() throws -> TunnelConfiguration {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw StoreError.notFound }
            return try TunnelConfiguration.decoded(from: data)
        case errSecItemNotFound:
            throw StoreError.notFound
        default:
            throw StoreError.keychain(status)
        }
    }

    static func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
