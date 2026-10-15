import Foundation
import Security

/// Reads Claude Code's OAuth credential out of the login keychain.
///
/// Claude Code can leave several items under `Claude Code-credentials` (it files
/// a new one on token rotation instead of always updating in place). A plain
/// `security find-generic-password -s <service> -w` returns *some* match with no
/// ordering guarantee, so it can hand back an old, expired duplicate while a
/// valid token sits right next to it.
///
/// So: enumerate every item's *attributes* (never prompts — the ACL guards the
/// data, not the metadata), sort newest-modified first, and read the data of
/// each one by service + account through `/usr/bin/security` (the tool Claude
/// Code writes with, so it's on the item's access list and doesn't prompt).
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    struct Item {
        let account: String?
        let modifiedAt: Date?
    }

    /// Every item under the service, newest first. Attributes only: no prompt.
    static func items(service: String = service) -> [Item] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        // One match may come back as a single dictionary rather than an array of one.
        let raw = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return raw
            .map { Item(account: $0[kSecAttrAccount as String] as? String,
                        modifiedAt: $0[kSecAttrModificationDate as String] as? Date) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// Raw JSON strings to try, newest item first, ending with the old
    /// "whatever security returns" read as a last resort.
    static func candidates(service: String = service) -> [String] {
        var out: [String] = []
        var seenAccounts = Set<String>()
        for item in items(service: service) {
            guard let account = item.account, seenAccounts.insert(account).inserted else { continue }
            if let s = securityRead(service: service, account: account) { out.append(s) }
        }
        if out.isEmpty, let s = securityRead(service: service, account: nil) { out.append(s) }
        return out
    }

    /// When the newest item was last written. Cheap (no prompt, no subprocess).
    static func newestModifiedAt(service: String = service) -> Date? {
        items(service: service).first?.modifiedAt
    }

    private static func securityRead(service: String, account: String?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        p.arguments = args + ["-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // drain before waiting
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }
}
