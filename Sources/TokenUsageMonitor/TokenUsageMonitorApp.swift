import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu.
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokenUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = UsageStore()
    @AppStorage("showPercent") private var showPercent = false

    var body: some Scene {
        MenuBarExtra {
            UsagePanel()
                .environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: MenuBarIcon.make(outer: store.claudeLevel, inner: store.codexLevel))
                if showPercent, let m = [store.claudeLevel, store.codexLevel].compactMap({ $0 }).max() {
                    Text("\(Int(m.rounded()))%").monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
