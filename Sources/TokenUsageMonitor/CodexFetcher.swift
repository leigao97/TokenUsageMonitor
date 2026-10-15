import Foundation

/// Codex (ChatGPT plan) limits.
/// Reads ~/.codex/auth.json (written when you sign in to Codex CLI / app) and calls
/// the same endpoint behind ChatGPT's "Plan limits" page and Codex `/status`:
///   GET https://chatgpt.com/backend-api/wham/usage
enum CodexFetcher {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let relogin = "Codex session expired. Run `codex` once in a terminal to refresh it, then retry."

    struct Credentials { let token: String; let accountID: String? }

    static func authFile() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    }

    static func loadCredentials() -> Credentials? {
        guard let data = try? Data(contentsOf: authFile()),
              let obj = J.object(data),
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else { return nil }
        return Credentials(token: token, accountID: tokens["account_id"] as? String)
    }

    static func fetch() async throws -> ProviderStatus {
        guard let cred = loadCredentials() else {
            throw FetchError.notLoggedIn("No Codex login found. Run `codex` and sign in with ChatGPT.")
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(cred.token)", forHTTPHeaderField: "Authorization")
        if let id = cred.accountID { req.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs/0.50.0 (Mac OS; arm64)", forHTTPHeaderField: "User-Agent")
        let obj = try await HTTP.getJSON(req, reloginHint: relogin)

        var status = ProviderStatus(updatedAt: Date())
        if let plan = obj["plan_type"] as? String { status.plan = plan.capitalized }

        if let rl = obj["rate_limit"] as? [String: Any] {
            status.windows += windows(from: rl, prefix: "", idPrefix: "codex")
        }
        // Additional limits (e.g. separately metered models)
        if let extras = obj["additional_rate_limits"] as? [[String: Any]] {
            for (i, item) in extras.enumerated() {
                let name = (item["limit_name"] as? String) ?? (item["metered_feature"] as? String) ?? "Additional"
                if let rl = item["rate_limit"] as? [String: Any] {
                    status.windows += windows(from: rl, prefix: name + " · ", idPrefix: "extra\(i)")
                }
            }
        }
        if let credits = obj["credits"] as? [String: Any],
           (credits["has_credits"] as? Bool) == true,
           (credits["unlimited"] as? Bool) != true,
           let bal = J.double(credits["balance"]), bal > 0 {
            status.extra = String(format: "%.0f credits remaining", bal)
        }
        if status.windows.isEmpty { throw FetchError.badResponse }
        return status
    }

    private static func windows(from rl: [String: Any], prefix: String, idPrefix: String) -> [LimitWindow] {
        var out: [LimitWindow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = rl[key] as? [String: Any],
                  let used = J.double(w["used_percent"]) else { continue }
            let secs = J.double(w["limit_window_seconds"])
            var reset = J.date(w["reset_at"])
            if reset == nil, let after = J.double(w["reset_after_seconds"]) {
                reset = Date().addingTimeInterval(after)
            }
            out.append(LimitWindow(
                id: "\(idPrefix).\(key)",
                title: prefix + windowName(secs),
                usedPercent: used,
                resetsAt: reset,
                windowSeconds: secs
            ))
        }
        return out
    }

    static func windowName(_ secs: Double?) -> String {
        guard let s = secs else { return "Limit" }
        let h = s / 3600
        if abs(h - 5) < 0.5 { return "Current session" }
        if abs(h - 168) < 2 { return "Weekly limit" }
        if abs(h - 24) < 1 { return "Daily limit" }
        if h >= 24 { return String(format: "%.0f-day limit", h / 24) }
        return String(format: "%.0f-hour limit", h)
    }
}
