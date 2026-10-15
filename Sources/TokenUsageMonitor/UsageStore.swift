import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude = ProviderStatus()
    @Published var codex = ProviderStatus()
    @Published var isRefreshing = false

    /// Claude's usage endpoint rate-limits aggressively; keep polling slow.
    private let interval: TimeInterval = 300
    private var timer: Timer?
    private var lastRefresh: Date = .distantPast

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
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
        async let c = Self.run(ClaudeFetcher.fetch)
        async let x = Self.run(CodexFetcher.fetch)
        claude = merge(old: claude, new: await c)
        codex = merge(old: codex, new: await x)
        isRefreshing = false
    }

    private static func run(_ f: @escaping () async throws -> ProviderStatus) async -> Result<ProviderStatus, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    /// On failure keep the last good data and just attach the error.
    private func merge(old: ProviderStatus, new: Result<ProviderStatus, Error>) -> ProviderStatus {
        switch new {
        case .success(let s): return s
        case .failure(let e):
            var s = old
            s.error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            return s
        }
    }

    /// For the menu bar icon: the most-used window of each provider.
    var claudeLevel: Double? { claude.maxUsed }
    var codexLevel: Double? { codex.maxUsed }
}
