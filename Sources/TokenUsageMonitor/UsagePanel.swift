import SwiftUI
import ServiceManagement

struct UsagePanel: View {
    @EnvironmentObject var store: UsageStore
    @AppStorage("showPercent") private var showPercent = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 18) {
                ProviderSection(name: "Claude", tint: Color(red: 0.85, green: 0.47, blue: 0.34),
                                status: store.claude)
                ProviderSection(name: "Codex", tint: Color.primary,
                                status: store.codex)
            }
            .padding(16)

            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 300)
        .onAppear { store.refreshIfStale() }
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: store.isRefreshing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let t = [store.claude.updatedAt, store.codex.updatedAt].compactMap({ $0 }).max() {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Toggle("Show percentage in menu bar", isOn: $showPercent)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Divider()
                Button("Open Claude usage page") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                Button("Open Codex usage page") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/settings/usage?tab=overview")!) }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
        }
    }
}

struct ProviderSection: View {
    let name: String
    let tint: Color
    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(name).font(.system(size: 12, weight: .semibold))
                if let plan = status.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if status.windows.isEmpty && status.error == nil {
                Text("Loading…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            ForEach(status.windows) { w in
                WindowRow(window: w, tint: tint)
            }

            if let extra = status.extra {
                Text(extra).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let err = status.error {
                Label(err, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct WindowRow: View {
    let window: LimitWindow
    let tint: Color

    private var barColor: Color {
        if window.usedPercent >= 90 { return .red }
        if window.usedPercent >= 75 { return .orange }
        return tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 12))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            Bar(value: window.usedPercent / 100, color: barColor)
            HStack {
                Text(resetText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                if let p = window.paceRatio, p > 1.15, window.usedPercent >= 20 {
                    Text("Ahead of pace").font(.system(size: 10.5)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var resetText: String {
        guard let r = window.resetsAt else { return "\(Int(window.usedPercent.rounded()))% used" }
        let secs = r.timeIntervalSinceNow
        if secs <= 0 { return "Resetting soon" }
        let d = Int(secs) / 86400, h = Int(secs) % 86400 / 3600, m = Int(secs) % 3600 / 60
        let rel: String
        if d > 0 { rel = "\(d)d \(h)h" }
        else if h > 0 { rel = "\(h)h \(m)m" }
        else { rel = "\(max(m, 1))m" }
        let abs: String
        if Calendar.current.isDateInToday(r) {
            abs = r.formatted(date: .omitted, time: .shortened)
        } else {
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("EEEjmm")
            abs = f.string(from: r)
        }
        return "Resets in \(rel) · \(abs)"
    }
}

struct Bar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color)
                    .frame(width: max(value > 0 ? 4 : 0, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 5)
    }
}
