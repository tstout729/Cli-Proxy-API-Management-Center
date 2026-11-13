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

private enum AccountFilter: String, CaseIterable {
    case all = "All accounts", claude = "Claude", codex = "Codex"
    func includes(_ account: AccountState) -> Bool {
        self == .all || account.credential.provider.rawValue == rawValue.lowercased()
    }
}

@MainActor
struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var capture = false
    @State private var filter = AccountFilter.all

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                filterBar
                HStack(spacing: 12) {
                    Text("ACCOUNT").frame(maxWidth: .infinity, alignment: .leading)
                    Text("5-HOUR USED").frame(width: 118, alignment: .leading)
                    Text("WEEKLY USED").frame(width: 118, alignment: .leading)
                    Spacer().frame(width: 16)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                Divider()
                if capture {
                    accountContent(now: context.date)
                } else {
                    ScrollView { accountContent(now: context.date) }.frame(height: 440)
                }
                Divider()
                HStack(spacing: 6) {
                    Circle().fill(store.snapshot.connectionFailure == nil ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("Shared team pool").font(.caption)
                    Text("· Pacific time · Refreshes every 5 min")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .keyboardShortcut("q")
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            .frame(width: 620)
            .background(.background)
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Usage").font(.system(size: 21, weight: .bold))
                if store.demo { Text("DEMO").font(.caption.bold()).foregroundStyle(.secondary) }
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage") }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain).disabled(store.refreshing)
                .accessibilityLabel("Refresh usage").help("Refresh usage (⌘R)")
                .keyboardShortcut("r")
            }
            HStack(spacing: 18) {
                summary("Accounts", value: store.snapshot.accounts.count, color: .primary)
                summary("Reporting", value: store.snapshot.usageSuccesses, color: .blue)
                summary("At limit", value: store.snapshot.accounts.filter { $0.status(at: now) == .exhausted }.count, color: .orange)
                summary("Sign-in needed", value: store.snapshot.accounts.filter { $0.status(at: now) == .loginNeeded }.count, color: .red)
                Spacer(minLength: 0)
            }
            if let failure = store.snapshot.connectionFailure {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if let date = store.snapshot.attemptedAt {
                Text(store.demo ? "Synthetic preview · no network access" : "Updated \(DisplayTime.absolute(date))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(store.refreshing ? "Connecting to the team pool…" : "Waiting for first refresh")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20)
    }

    private func summary(_ title: String, value: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(value)").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(AccountFilter.allCases, id: \.self) { item in
                Button { filter = item } label: {
                    Text(item.rawValue).font(.system(size: 12, weight: filter == item ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(filter == item ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(filter == item ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == item ? .isSelected : [])
            }
            Spacer()
        }.padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func accountContent(now: Date) -> some View {
        VStack(spacing: 0) {
            if store.snapshot.accounts.isEmpty {
                ContentUnavailableView("No accounts loaded", systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(store.snapshot.connectionFailure == nil
                        ? "The proxy reported no Claude or Codex accounts."
                        : "Check the proxy connection and management key, then refresh."))
                    .padding(24)
            }
            ForEach(store.snapshot.accounts.filter { filter.includes($0) }) { account in
                AccountRow(account: account, now: now)
                Divider().padding(.horizontal, 20)
            }
        }
    }
}

@MainActor
struct AccountRow: View {
    let account: AccountState
    let now: Date
    @State private var expanded = false
    private var status: AccountStatus { account.status(at: now) }
    private var historical: Bool {
        account.isStale(at: now) || account.failure != nil || account.credential.loginNeeded || account.credential.disabled
    }
    private var color: Color {
        switch status {
        case .loginNeeded, .exhausted: .red
        case .stale, .modelLimited, .unavailable, .connectionError: .orange
        case .reported: .green
        case .unknown, .disabled: .secondary
        }
    }
    private var statusLabel: String {
        switch status {
        case .reported: account.credential.provider.title
        case .unknown: "\(account.credential.provider.title) · Partial data"
        default: "\(account.credential.provider.title) · \(status.rawValue)"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.credential.label).font(.system(size: 12, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(statusLabel).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                compactMeter(.fiveHour)
                compactMeter(.weekly)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 16, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide account details" : "Show account details")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if historical, account.reading != nil {
                        Label("Previous reading · current capacity unknown", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    if let failure = account.failure { Text(failure.message).foregroundStyle(.secondary) }
                    if let reading = account.reading {
                        ForEach(reading.windows) { window in
                            HStack {
                                Text(window.label).frame(width: 130, alignment: .leading)
                                Text(window.usedPercent.map { String(format: "%.1f%% used", $0) } ?? "Not reported")
                                    .frame(width: 90, alignment: .leading)
                                Text(window.resetAt.map { DisplayTime.absolute($0) } ?? "Reset not reported")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !reading.limitedScopes.isEmpty {
                            Text("Model limit reached: \(reading.limitedScopes.joined(separator: ", "))")
                        }
                        if let resets = reading.resets {
                            let expired = resets.validUntil.map { $0 <= now } ?? false
                            HStack(spacing: 12) {
                                Text(historical || expired ? "Previous reset counts" : "Reset credits").fontWeight(.medium)
                                if let available = resets.available { Text("\(available) available") }
                                if let usable = resets.usableNow { Text("\(usable) applicable at last update") }
                            }.foregroundStyle(.secondary)
                        }
                        Text("Updated \(DisplayTime.absolute(reading.fetchedAt))").foregroundStyle(.secondary)
                    } else {
                        Text("Usage will appear after a successful account refresh.").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 10))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
    }

    private func compactMeter(_ period: WindowPeriod) -> some View {
        let window = account.reading?.windows.first { $0.isOverall && $0.period == period }
        return UsageMeter(window: window, now: now, historical: historical)
            .frame(width: 118, alignment: .leading)
    }
}

@MainActor
struct UsageMeter: View {
    let window: UsageWindow?
    let now: Date
    let historical: Bool
    private var color: Color {
        if historical { return .secondary }
        guard let used = window?.usedPercent else { return .secondary }
        return used >= 100 ? .red : used >= 80 ? .orange : .accentColor
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(window?.usedPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(window?.usedPercent == 100 ? .red : .primary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.13))
                    if let used = window?.usedPercent {
                        Capsule().fill(color).frame(width: geometry.size.width * used / 100)
                    }
                }
            }.frame(height: 4)
            Text(resetLabel).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(window?.resetAt.map { "Resets \(DisplayTime.absolute($0))" } ?? "Reset not reported")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window?.label ?? "Usage"), \(window?.usedPercent.map { String(format: "%.1f percent used", $0) } ?? "not reported")\(historical ? ", previous reading" : "")")
    }
    private var resetLabel: String {
        guard let reset = window?.resetAt else { return "Not reported" }
        if reset <= now { return "Refresh needed" }
        return "Resets \(DisplayTime.countdown(to: reset, now: now))"
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
