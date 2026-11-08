// Bearer token: generated on first run, stored in the login Keychain.
import Foundation
import Security

public enum TokenStore {
    static let service = "com.kuarasoft.macwright"
    static let account = "mcp-bearer-token"

    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ token: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrLabel as String] = "MacWright MCP token"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// The stored token, creating and saving one on first run.
    public static func loadOrCreate() -> String {
        if let t = load(), !t.isEmpty { return t }
        let t = generate()
        save(t)
        return t
    }
}

/// True when an Authorization header carries exactly `Bearer <token>`. Constant-time on the token.
public func bearerMatches(_ header: String?, token: String) -> Bool {
    guard let header, !token.isEmpty else { return false }
    let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
    let given = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8), want = Array(token.utf8)
    var diff = given.count ^ want.count
    for i in 0..<want.count { diff |= Int(want[i] ^ (i < given.count ? given[i] : 0)) }
    return diff == 0
}
