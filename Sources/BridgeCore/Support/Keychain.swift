import Foundation
import Security

/// Backend API keys in the login keychain.
///
/// Profiles are plain JSON on disk so they can be diffed, backed up, and shared;
/// the secrets they reference are not, so a profile file is safe to hand to
/// someone else.
public enum Keychain {
    public static let service = "com.claudebridge.backend-key"

    /// Keychain calls are synchronous and can block indefinitely: reading an
    /// item created under a different code signature makes macOS put up an
    /// authorisation prompt, and `SecItemCopyMatching` does not return until
    /// the user answers it. On the main actor that freezes the entire app, so
    /// every call is routed off it through this queue.
    ///
    /// Development builds hit this constantly, because an ad-hoc signature
    /// changes on every rebuild and the item no longer looks like it belongs
    /// to the same app.
    private static let queue = DispatchQueue(label: "com.claudebridge.keychain")

    public static func get(account: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: getBlocking(account: account)) }
        }
    }

    public static func set(_ secret: String, account: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try setBlocking(secret, account: account)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func remove(account: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try removeBlocking(account: account)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking primitives
    //
    // Safe to call directly only from somewhere that can afford to wait — the
    // headless daemon at startup, say. Never from the main actor.

    public static func setBlocking(_ secret: String, account: String) throws {
        // A delete-then-add is simpler than SecItemUpdate's attribute dance and
        // is idempotent for a single-value item.
        try? removeBlocking(account: account)
        guard !secret.isEmpty else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // Deliberately no ACL widening here.
        //
        // macOS scopes an item's decrypt ACL to the creating binary and pins a
        // PartitionID to its cdhash, which is why a rebuilt app is asked to
        // authorise again: an ad-hoc signature changes every build, so the item
        // no longer looks like it belongs to the same program. Passing an
        // unrecognised "ACL" key to SecItemAdd does not change this — the call
        // still returns errSecSuccess, because unknown attribute keys are
        // silently dropped, and the resulting ACL is byte-identical.
        //
        // Widening it for real means kSecAttrAccess with a SecAccess whose
        // trusted-application list is nil, which lets *any* process running as
        // this user read the stored provider keys without a prompt. That trades
        // away the only thing that makes keychain storage worth doing over a
        // plain file, so it is not done.
        //
        // The prompt is a development artefact: a stable Developer ID signature
        // makes it go away. Meanwhile the app simply does not read a credential
        // it has no use for — see AppState.apiKey(for:).

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func getBlocking(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func removeBlocking(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    public struct KeychainError: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }
}
