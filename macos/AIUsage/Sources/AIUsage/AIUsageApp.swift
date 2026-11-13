import Foundation
import UsageCore
#if os(macOS)
import AppKit
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() async {
        let arguments = Set(CommandLine.arguments.dropFirst())
        // No CLI flags accept keys, URLs or identities. Overrides use environment variables.
        guard arguments.isSubset(of: ["--demo", "--check", "--demo-screenshot"]),
              !(arguments.contains("--check") && arguments.count > 1),
              !arguments.contains("--demo-screenshot") || arguments.contains("--demo") else {
            exit(2)
        }
        if arguments.contains("--check") {
            let result: RefreshSnapshot
            do {
                let configuration = try ConnectionConfiguration.environment()
                result = await RefreshEngine(configuration: configuration).refresh()
            } catch {
                result = RefreshSnapshot(connectionFailure: .configuration)
            }
            print(result.checkSummary)
            exit(result.connectionFailure == nil && result.usageErrors == 0 ? 0 : 1)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        if arguments.contains("--demo-screenshot") {
            let renderer = ImageRenderer(content: UsagePanel(store: UsageStore(demo: true), capture: true))
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-demo.png")
            do { try data.write(to: path); print(path.path) } catch { exit(1) }
            exit(0)
        }
        AIUsageApp.main()
    }
}

@MainActor
struct AIUsageApp: App {
    @StateObject private var store = UsageStore(demo: CommandLine.arguments.contains("--demo"))
    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Label("AI Usage", systemImage: "chart.bar.xaxis")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = RefreshSnapshot()
    @Published private(set) var refreshing = false
    let demo: Bool
    private var engine: RefreshEngine?
    private var refreshTask: Task<Void, Never>?

    init(demo: Bool) {
        self.demo = demo
        if demo { snapshot = DemoData.snapshot(); return }
        do { engine = RefreshEngine(configuration: try ConnectionConfiguration.environment()) }
        catch { snapshot = RefreshSnapshot(connectionFailure: .configuration); return }
        // App lifetime, independent of opening the menu. No network work in view lifecycle callbacks.
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    deinit { refreshTask?.cancel() }
    func refresh() async {
        guard !refreshing else { return }
        if demo { snapshot = DemoData.snapshot(); return }
        guard let engine else { return }
        refreshing = true
        defer { refreshing = false }
        snapshot = await engine.refresh()
    }
}

@MainActor
struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var capture = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if capture {
                    accountContent(now: context.date)
                } else {
                    ScrollView { accountContent(now: context.date) }
                        .frame(height: 540)
                }
                Divider()
                HStack {
                    Text("Auto-refresh every 5 min · Pacific time").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                }.padding(12)
            }
            .frame(width: 460)
            .background(.background)
        }
    }

    private func accountContent(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let failure = store.snapshot.connectionFailure {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if store.snapshot.accounts.isEmpty {
                ContentUnavailableView("No accounts loaded", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text(store.snapshot.connectionFailure == nil
                                            ? "The proxy reported no Claude or Codex accounts."
                                            : "Check the local proxy connection and management key file, then refresh."))
            }
            ForEach(Provider.allCases, id: \.self) { provider in
                let accounts = store.snapshot.accounts.filter { $0.credential.provider == provider }
                if !accounts.isEmpty {
                    HStack {
                        Text(provider.title).font(.title3.bold())
                        Text("\(accounts.count) accounts").foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(accounts) { account in
                        AccountCard(account: account, now: now)
                    }
                }
            }
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AI Usage").font(.title2.bold())
                if store.demo { Text("DEMO").font(.caption.bold()).foregroundStyle(.secondary) }
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage") }
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(store.refreshing)
                    .keyboardShortcut("r")
                    .help("Refresh account usage")
            }
            if let date = store.snapshot.attemptedAt {
                Text("Last attempt: \(DisplayTime.absolute(date))").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(store.refreshing ? "Loading usage…" : "Usage has not been refreshed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.demo { Text("Synthetic accounts · no network access").font(.caption).foregroundStyle(.secondary) }
        }.padding(16)
    }
}

@MainActor
struct AccountCard: View {
    let account: AccountState
    let now: Date
    @State private var showDetails = false
    private var status: AccountStatus { account.status(at: now) }
    private var historical: Bool {
        account.isStale(at: now) || account.failure != nil || account.credential.loginNeeded || account.credential.disabled
    }
    private var color: Color {
        switch status {
        case .loginNeeded, .exhausted: .red
        case .stale, .modelLimited, .unavailable, .connectionError: .orange
        case .reported: .primary
        case .unknown, .disabled: .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.credential.label).font(.headline).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                Text(status.rawValue).font(.caption.bold()).foregroundStyle(color)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if historical, account.reading != nil {
                Label("Previous reading · current capacity unknown", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = account.failure {
                Text(failure.message).font(.caption).foregroundStyle(.secondary)
            }
            if let reading = account.reading {
                ForEach(reading.windows.filter(\.isOverall)) { window in
                    WindowRow(window: window, now: now, historical: historical)
                }
                let extra = reading.windows.filter { !$0.isOverall }
                if !extra.isEmpty || !reading.limitedScopes.isEmpty {
                    DisclosureGroup("Model-specific limits", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(extra) { window in WindowRow(window: window, now: now, historical: historical) }
                            if !reading.limitedScopes.isEmpty {
                                Text("Reported limit reached: \(reading.limitedScopes.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                }
                if let resets = reading.resets {
                    let expired = resets.validUntil.map { $0 <= now } ?? false
                    let qualifier = historical || expired ? "Last reported reset counts" : "Reset counts"
                    VStack(alignment: .leading, spacing: 3) {
                        Text(qualifier).font(.caption.bold())
                        if let available = resets.available { Text("\(available) available") }
                        if let usable = resets.usableNow { Text("\(usable) applicable now\(historical || expired ? " at last update" : "")") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                Text("Updated: \(DisplayTime.absolute(reading.fetchedAt))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(["5-hour", "Weekly"], id: \.self) { label in
                    HStack { Text(label); Spacer(); Text("Not reported") }
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

@MainActor
struct WindowRow: View {
    let window: UsageWindow
    let now: Date
    let historical: Bool
    private var percent: String {
        window.usedPercent.map { String(format: "%.1f%% USED", $0) } ?? "Not reported"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(.subheadline)
                Spacer()
                Text(percent).font(.caption.monospacedDigit().bold())
                    .foregroundStyle(window.usedPercent == 100 ? Color.red : Color.primary)
            }
            if let used = window.usedPercent {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(historical || window.resetPassed(at: now) ? Color.secondary : used == 100 ? Color.red : Color.accentColor)
                            .frame(width: geometry.size.width * used / 100)
                    }
                }
                .frame(height: 6)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(window.label), \(percent)\(historical ? ", previous reading" : "")")
            }
            if let reset = window.resetAt {
                Text(window.resetPassed(at: now) ? DisplayTime.countdown(to: reset, now: now) : "Resets \(DisplayTime.countdown(to: reset, now: now))")
                Text(DisplayTime.absolute(reset))
            } else {
                Text("Reset not reported")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
#else
@main
enum UnsupportedPlatform {
    static func main() {
        // The core is portable for focused parser tests; the application requires macOS 14+.
        print("AI Usage requires macOS 14 or later.")
    }
}
#endif
