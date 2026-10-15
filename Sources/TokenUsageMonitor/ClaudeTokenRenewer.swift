import Foundation

/// Keeps Claude Code's keychain token from ageing out — by letting the official
/// `claude` CLI renew it, never by calling the OAuth refresh endpoint ourselves.
///
/// Why: the access token only lives a few hours and only the standalone CLI
/// renews it (lazily, at start-up). If you work in claude.ai / the desktop app
/// and don't open a terminal, the keychain item just rots and the usage
/// endpoint starts returning 401.
///
/// How (same trick Codenotch uses): `claude -p` with stdin = /dev/null goes
/// through its whole start-up — where it renews the token if it's within ~5
/// minutes of expiry — then exits non-zero with "Input must be provided…".
/// No prompt is ever sent, so no conversation, no transcript, no usage.
///
/// That behaviour isn't a documented interface, so success is judged by the
/// *outcome*: only if the keychain's `expiresAt` actually moved. One attempt per
/// token + a cooldown, so a CLI that stops renewing can't cause a launch loop.
actor ClaudeTokenRenewer {
    static let shared = ClaudeTokenRenewer()

    /// Must stay under the CLI's own 5-minute gate, or the launch is a no-op.
    static let margin: TimeInterval = 4 * 60
    static let cooldown: TimeInterval = 10 * 60
    static let timeout: TimeInterval = 30
    /// No `--mcp-config` + strict = no MCP servers started; no transcript written.
    static let arguments = ["-p", "--no-session-persistence", "--strict-mcp-config"]

    private var knownExpiry: Date?
    private var attemptedFor: Date?
    private var lastAttempt: Date?
    private var isRunning = false
    /// Why the last attempt didn't work, for the UI. nil after a success.
    private(set) var lastFailure: String?

    private var cliLookedUp = false
    private var cachedCLI: URL?
    private var cli: URL? {
        if !cliLookedUp { cachedCLI = ClaudeCLILocator.find(); cliLookedUp = true }
        return cachedCLI
    }

    /// Called by the fetcher whenever it has read the credential.
    func note(expiry: Date?) { knownExpiry = expiry }

    nonisolated func isNearExpiry(_ expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) < Self.margin
    }

    /// Timer entry point: uses the expiry already in hand, so idle ticks cost
    /// no keychain read and no subprocess.
    func tick() async {
        // Nothing read yet — e.g. launched while the usage endpoint is in 429
        // backoff, so the fetcher never ran. Read the keychain once ourselves,
        // otherwise renewal would stay blind for the whole backoff.
        if knownExpiry == nil {
            knownExpiry = ClaudeFetcher.loadCredentials()?.expiresAt
            if let e = knownExpiry { NSLog("TokenUsageMonitor: Claude token expires %@", "\(e)") }
        }
        guard isNearExpiry(knownExpiry) else { return }
        // Confirm against the keychain first — the user may have run `claude`
        // themselves since we last looked.
        let fresh = ClaudeFetcher.loadCredentials()?.expiresAt
        knownExpiry = fresh
        guard isNearExpiry(fresh), let fresh else { return }
        _ = await renew(current: fresh)
    }

    /// Try to renew a token that expires at `current`. Returns the new expiry
    /// on success, nil if skipped or failed.
    func renew(current: Date, now: Date = Date()) async -> Date? {
        guard !isRunning else { return nil }
        guard current != attemptedFor else { return nil }                 // one attempt per token
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.cooldown { return nil }
        isRunning = true
        defer { isRunning = false }
        lastAttempt = now
        attemptedFor = current

        guard let cli else {
            lastFailure = "No standalone `claude` CLI found to renew the token automatically."
            return nil
        }
        NSLog("TokenUsageMonitor: Claude token expires %@; renewing via %@", "\(current)", cli.path)
        await Self.run(cli)

        let after = ClaudeFetcher.loadCredentials()?.expiresAt
        knownExpiry = after
        guard let after, after > current else {
            lastFailure = "Automatic renewal via `claude` didn't refresh the token."
            NSLog("TokenUsageMonitor: renewal ran but expiry did not move (%@)", "\(String(describing: after))")
            return nil
        }
        lastFailure = nil
        NSLog("TokenUsageMonitor: Claude token renewed, now expires %@", "\(after)")
        return after
    }

    private static func run(_ cli: URL) async {
        let p = Process()
        p.executableURL = cli
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // A Finder-launched app has a bare PATH; an npm-installed `claude` is a
        // `#!/usr/bin/env node` script and needs node on it.
        let extra = [cli.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        // A fixed scratch dir, never `/` (which is the cwd when launched from
        // Finder) — otherwise hooks/settings lookups can trip folder-access prompts.
        if let dir = try? scratchDirectory() {
            p.currentDirectoryURL = dir
            env["PWD"] = dir.path
        }
        p.environment = env
        p.standardInput = FileHandle.nullDevice      // the whole trick: immediate EOF
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            NSLog("TokenUsageMonitor: could not launch claude: %@", "\(error)")
            return
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning {
            p.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }

    private static func scratchDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TokenUsageMonitor/claude-renew", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Finds the standalone Claude Code CLI — deliberately *not* the copy bundled in
/// the Claude desktop app, which keeps its token in the app's own store and
/// never writes the login keychain (renewing with it would change nothing here).
enum ClaudeCLILocator {
    static let desktopOwned = "/Library/Application Support/Claude/"

    static func find() -> URL? {
        let home = NSHomeDirectory()
        var paths = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/usr/bin/claude",
        ]
        paths += nvmCandidates(home: home)
        for p in paths { if let u = usable(p) { return u } }
        // Last resort: ask the user's login shell (slow, so only once).
        if let p = loginShellLookup(), let u = usable(p) { return u }
        return nil
    }

    private static func usable(_ path: String) -> URL? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard !resolved.path.contains(desktopOwned) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `~/.nvm/versions/node/<v>/bin/claude`, newest Node first.
    private static func nvmCandidates(home: String) -> [String] {
        let dir = "\(home)/.nvm/versions/node"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(dir)/\($0)/bin/claude" }
    }

    private static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.hasPrefix("/") == true) ? s : nil
    }
}
