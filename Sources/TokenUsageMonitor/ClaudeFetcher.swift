import Foundation

/// Claude subscription limits.
/// Reuses Claude Code's OAuth credentials and calls the same endpoint behind the
/// claude.ai Usage page and Claude Code's `/usage`:
///   GET https://api.anthropic.com/api/oauth/usage
/// The endpoint is undocumented, so parsing is deliberately lenient.
enum ClaudeFetcher {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let relogin = "Claude session expired. Run `claude` once in a terminal to refresh it, then retry."

    struct Credentials { let token: String; let plan: String?; let expiresAt: Date? }

    static func loadCredentials() -> Credentials? {
        // 1) macOS Keychain (Claude Code's default store on macOS). Newest item
        //    first — there can be stale duplicates under the same service.
        for raw in ClaudeKeychain.candidates() {
            if let c = parse(Data(raw.utf8)) { return c }
        }
        // 2) Credentials file (Linux, older versions, custom CLAUDE_CONFIG_DIR)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [home.appendingPathComponent(".claude/.credentials.json")]
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            paths.insert(URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json"), at: 0)
        }
        for p in paths {
            if let d = try? Data(contentsOf: p), let c = parse(d) { return c }
        }
        return nil
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let obj = J.object(data),
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              // Claude Code sometimes blanks the item (accessToken "", expiresAt 0)
              // on sign-out; treat that as "no credential", not as a token.
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let plan = (oauth["rateLimitTier"] as? String) ?? (oauth["subscriptionType"] as? String)
        return Credentials(token: token, plan: plan.map(prettyPlan), expiresAt: J.date(oauth["expiresAt"]))
    }

    static func fetch() async throws -> ProviderStatus {
        guard var cred = loadCredentials() else {
            throw FetchError.notLoggedIn("No Claude Code login found. Run `claude` and sign in with your subscription.")
        }
        let renewer = ClaudeTokenRenewer.shared
        await renewer.note(expiry: cred.expiresAt)
        // Expired or about to: let the CLI renew it before we spend a request
        // on a token the server will reject.
        if await renewer.isNearExpiry(cred.expiresAt), let exp = cred.expiresAt {
            if await renewer.renew(current: exp) != nil, let fresh = loadCredentials() {
                cred = fresh
            } else if exp <= Date() {
                let why = await renewer.lastFailure
                throw FetchError.unauthorized([why, relogin].compactMap { $0 }.joined(separator: " "))
            }
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenUsageMonitor/1.0", forHTTPHeaderField: "User-Agent")
        let obj = try await HTTP.getJSON(req, reloginHint: relogin)

        var status = ProviderStatus(plan: cred.plan, updatedAt: Date())

        // Current format: a `limits` array matching the claude.ai Usage page,
        // including separately metered limits (e.g. per-model weekly caps).
        if let limits = obj["limits"] as? [[String: Any]] {
            for (i, l) in limits.enumerated() {
                guard let pct = J.double(l["percent"]) else { continue }
                let kind = l["kind"] as? String ?? ""
                let group = l["group"] as? String ?? ""
                let scope = l["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                let title: String
                switch kind {
                case "session": title = "Current session"
                case "weekly_all": title = "This week · All models"
                default:
                    let name = model ?? surface ?? kind
                    title = (group == "weekly" ? "This week · " : "") + name
                }
                status.windows.append(LimitWindow(
                    id: "limit\(i).\(kind)",
                    title: title,
                    usedPercent: pct,
                    resetsAt: J.date(l["resets_at"]),
                    windowSeconds: group == "session" ? 5 * 3600 : (group == "weekly" ? 7 * 86400 : nil)
                ))
            }
        }

        // Legacy format fallback: top-level `five_hour`, `seven_day`, ...
        if status.windows.isEmpty {
            for (key, value) in obj {
                guard let w = value as? [String: Any],
                      let used = J.double(w["utilization"]) else { continue }
                if key == "extra_usage" || key == "spending_limit" { continue }
                status.windows.append(LimitWindow(
                    id: key,
                    title: title(for: key),
                    usedPercent: used,
                    resetsAt: J.date(w["resets_at"]),
                    windowSeconds: key.hasPrefix("five_hour") ? 5 * 3600 : (key.hasPrefix("seven_day") ? 7 * 86400 : nil)
                ))
            }
            status.windows.sort { order($0.id) < order($1.id) || (order($0.id) == order($1.id) && $0.id < $1.id) }
        }

        if let extra = obj["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true,
           let used = J.double(extra["used_credits"]) {
            let limit = J.double(extra["monthly_limit"])
            status.extra = limit.map { String(format: "Extra usage $%.2f / $%.2f", used / 100, $0 / 100) }
                ?? String(format: "Extra usage $%.2f", used / 100)
        }
        if status.windows.isEmpty { throw FetchError.badResponse }
        return status
    }

    private static func order(_ key: String) -> Int {
        if key == "five_hour" { return 0 }
        if key == "seven_day" { return 1 }
        return 2
    }

    static func title(for key: String) -> String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "This week · All models"
        case "seven_day_omelette": return "This week · Claude Design"
        default:
            var rest = key
            var prefix = ""
            if key.hasPrefix("seven_day_") { prefix = "This week · "; rest = String(key.dropFirst("seven_day_".count)) }
            else if key.hasPrefix("five_hour_") { prefix = "5-hour · "; rest = String(key.dropFirst("five_hour_".count)) }
            let name = rest.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return prefix + name
        }
    }

    static func prettyPlan(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("max") && r.contains("20") { return "Max (20x)" }
        if r.contains("max") && r.contains("5") { return "Max (5x)" }
        if r.contains("max") { return "Max" }
        if r.contains("pro") { return "Pro" }
        if r.contains("team") { return "Team" }
        if r.contains("enterprise") { return "Enterprise" }
        return raw
    }
}
