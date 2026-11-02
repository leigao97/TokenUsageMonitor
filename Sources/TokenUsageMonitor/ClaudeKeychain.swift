import Foundation
import Security
import CryptoKit

/// Reads Claude Code's OAuth credential out of the login keychain.
///
/// Two things make the obvious `security find-generic-password -s
/// "Claude Code-credentials" -w` unreliable:
///
/// 1. **Duplicates.** Claude Code can leave several items under the same
///    service, and `security` returns one with no ordering guarantee — possibly
///    an old, expired one.
/// 2. **Suffixed service names.** When `CLAUDE_CONFIG_DIR` is set in the shell
///    Claude Code runs from (even pointing at the default `~/.claude`), it files
///    the token under `Claude Code-credentials-<first 8 hex of SHA-256(dir)>`.
///
/// So: enumerate every candidate item's *attributes* (never prompts — the ACL
/// guards the data, not the metadata), sort newest-modified first across all
/// candidate services, and read each one's data by service + account through
/// `/usr/bin/security` (the tool Claude Code writes with, so no prompt).
enum ClaudeKeychain {
    static let baseService = "Claude Code-credentials"

    struct Item {
        let service: String
        let account: String?
        let modifiedAt: Date?
    }

    /// Suffixed name(s) first, bare name last. A GUI app rarely sees the
    /// user's CLAUDE_CONFIG_DIR, so the default `~/.claude` is always tried too.
    static func services() -> [String] {
        var dirs: [String] = []
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { dirs.append(d) }
        dirs.append(NSHomeDirectory() + "/.claude")
        var out: [String] = []
        for d in dirs {
            let path = d.hasSuffix("/") ? String(d.dropLast()) : d
            let hex = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
            let s = "\(baseService)-\(hex.prefix(8))"
            if !out.contains(s) { out.append(s) }
        }
        out.append(baseService)
        return out
    }

    /// Every candidate item across all services, newest first. Attributes only.
    static func items() -> [Item] {
        var all: [Item] = []
        for service in services() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { continue }
            let raw = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
            all += raw.map { Item(service: service,
                                  account: $0[kSecAttrAccount as String] as? String,
                                  modifiedAt: $0[kSecAttrModificationDate as String] as? Date) }
        }
        return all.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// Raw JSON strings to try, newest item first.
    static func candidates() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let found = items()
        for item in found {
            let key = item.service + "\u{0}" + (item.account ?? "")
            guard seen.insert(key).inserted else { continue }
            if let s = securityRead(service: item.service, account: item.account) { out.append(s) }
        }
        // Enumeration found nothing (or nothing readable): fall back to the old read.
        if out.isEmpty {
            for service in services() {
                if let s = securityRead(service: service, account: nil) { out.append(s) }
            }
        }
        return out
    }

    /// One log line describing what's in the keychain — no secrets, just shape.
    static func diagnostics() -> String {
        let found = items()
        let list = found.map { "\($0.service)[\($0.account ?? "?")] mdat=\($0.modifiedAt.map { "\($0)" } ?? "?")" }
        return "keychain items: \(found.count) " + list.joined(separator: "; ")
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
