import Foundation
import SwiftUI

/// Per-provider exponential backoff after HTTP 429.
/// The deadline is persisted so a relaunch doesn't immediately hit the endpoint again.
struct Backoff {
    static let base: TimeInterval = 300      // first wait: one polling interval
    static let cap: TimeInterval = 1800      // never wait longer than 30 minutes

    let key: String
    private(set) var delay: TimeInterval
    private(set) var until: Date

    init(key: String) {
        self.key = key
        let d = UserDefaults.standard
        delay = d.double(forKey: "\(key).backoffDelay")
        until = Date(timeIntervalSince1970: d.double(forKey: "\(key).backoffUntil"))
    }

    var isActive: Bool { until > Date() }

    mutating func hit(retryAfter: TimeInterval?) {
        delay = delay == 0 ? Self.base : min(delay * 2, Self.cap)
        let wait = max(delay, min(retryAfter ?? 0, Self.cap))
        until = Date().addingTimeInterval(wait)
        save()
    }

    mutating func reset() {
        guard delay != 0 else { return }
        delay = 0
        until = .distantPast
        save()
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(delay, forKey: "\(key).backoffDelay")
        d.set(until.timeIntervalSince1970, forKey: "\(key).backoffUntil")
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude = ProviderStatus()
    @Published var codex = ProviderStatus()
    @Published var isRefreshing = false

    /// Claude's usage endpoint rate-limits aggressively; keep polling slow.
    private let interval: TimeInterval = 300
    private var timer: Timer?
    /// Checks every minute whether Claude's keychain token is about to expire
    /// and, if so, has the `claude` CLI renew it (see ClaudeTokenRenewer).
    /// Idle ticks use the expiry already in memory: no keychain read, no process.
    private var renewTimer: Timer?
    private var lastRefresh: Date = .distantPast
    private var claudeBackoff = Backoff(key: "claude")
    private var codexBackoff = Backoff(key: "codex")

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        renewTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { await ClaudeTokenRenewer.shared.tick() }
        }
    }

    /// Called when the panel opens: refresh only if data is older than 60s.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 60 { Task { await refresh() } }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefresh = Date()
        async let c = poll(ClaudeFetcher.fetch, skip: claudeBackoff.isActive)
        async let x = poll(CodexFetcher.fetch, skip: codexBackoff.isActive)
        claude = apply(await c, to: claude, backoff: &claudeBackoff)
        codex = apply(await x, to: codex, backoff: &codexBackoff)
        isRefreshing = false
    }

    /// nil = skipped because the provider is still backing off.
    private nonisolated func poll(_ f: @escaping () async throws -> ProviderStatus,
                                  skip: Bool) async -> Result<ProviderStatus, Error>? {
        if skip { return nil }
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    /// On failure keep the last good data and just attach the error.
    private func apply(_ result: Result<ProviderStatus, Error>?, to old: ProviderStatus,
                       backoff: inout Backoff) -> ProviderStatus {
        switch result {
        case .none:
            var s = old
            s.error = rateLimitMessage(backoff)
            return s
        case .success(let s):
            backoff.reset()
            return s
        case .failure(let e):
            var s = old
            if case FetchError.rateLimited(let retryAfter) = e {
                backoff.hit(retryAfter: retryAfter)
                s.error = rateLimitMessage(backoff)
            } else {
                s.error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
            return s
        }
    }

    private func rateLimitMessage(_ b: Backoff) -> String {
        "Rate limited. Showing last data; retrying after \(b.until.formatted(date: .omitted, time: .shortened))."
    }

    /// For the menu bar icon: the most-used window of each provider.
    var claudeLevel: Double? { claude.maxUsed }
    var codexLevel: Double? { codex.maxUsed }
}
