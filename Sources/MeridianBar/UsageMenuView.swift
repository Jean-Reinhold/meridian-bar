import ServiceManagement
import SwiftUI

/// The dropdown: per-account cards, health footer, actions (okf/02 §2).
/// Liquid Glass on macOS 26+, material fallback below (okf/02 §5). The
/// window background is cleared so the glass refracts the desktop instead
/// of sitting on an opaque panel.
struct UsageMenuView: View {
    let store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 10) { content }
            } else {
                content
            }
        }
        .padding(12)
        .frame(width: 340)
        .clearWindowBackground()
        .task { await store.refresh() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let banner = offlineBanner {
                Label(banner, systemImage: "bolt.slash.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let err = store.switchError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            ForEach(store.segments, id: \.id) { segment in
                AccountCard(store: store, segment: segment)
            }
            if store.segments.isEmpty && !store.offline {
                Text("No profiles configured — run `meridian profile add <name>`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            footer
            actions
        }
    }

    private var offlineBanner: String? {
        guard store.offline else { return nil }
        if let t = store.lastSuccess {
            return "Meridian is not responding — showing data from \(t.formatted(date: .omitted, time: .shortened))"
        }
        return "Meridian is not responding"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.offline ? .red : (store.health?.status == "healthy" ? .green : .yellow))
                .frame(width: 8, height: 8)
            Text(store.offline ? "Offline" : "Operational")
            if let v = store.health?.version { Text("· Meridian \(v)") }
            if let t = store.lastSuccess {
                Text("· updated \(t.formatted(date: .omitted, time: .shortened))")
            }
            if store.health?.auth?.renewalRequiredSoon == true {
                Text("· token renewal soon").foregroundStyle(.yellow)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch on startup", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.callout)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Button("Refresh") { Task { await store.refresh() } }
                Button("Dashboard") {
                    NSWorkspace.shared.open(MeridianClient.configured().baseURL)
                }
                SettingsLink { Text("Settings…") }
                Button("About") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }
}

struct AccountCard: View {
    let store: UsageStore
    let segment: ProfileSegment

    private var info: ProfileInfo? {
        store.profiles?.profiles.first { $0.id == segment.id }
    }
    private var quota: ProfileQuota? {
        store.quota?.profiles.first { $0.id == segment.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            windows
            extraUsage
            if !segment.isActive {
                Button("Switch to \(segment.alias)") {
                    Task { await store.switchProfile(to: segment.id) }
                }
                .glassButton()
                .controlSize(.small)
            }
        }
        .padding(12)
        .glassCard()
        .opacity(store.offline ? 0.55 : 1)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(segment.alias).font(.headline)
                Text(segment.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if segment.isActive { Badge(text: "ACTIVE", color: .blue) }
                if let plan = info?.subscriptionType { Badge(text: plan, color: .gray) }
                if store.profiles?.exhausted?.contains(segment.id) == true {
                    Badge(text: "EXHAUSTED", color: .red)
                }
                if info?.loggedIn == false { Badge(text: "login required", color: .yellow) }
            }
            if let email = info?.email {
                Text(email).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var windows: some View {
        ForEach(quota?.windows ?? [], id: \.type) { w in
            let status = UsageLogic.status(utilization: w.utilization)
            HStack(spacing: 8) {
                Text(UsageLogic.windowLabel(w.type))
                    .font(.caption)
                    .frame(width: 64, alignment: .leading)
                ProgressView(value: min(max(w.utilization ?? 0, 0), 1))
                    .tint(Color(nsColor: MenuBarLabel.color(for: status)))
                Text(UsageLogic.percent(w.utilization).map { "\($0)%" } ?? "–")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            HStack {
                Spacer()
                if (w.utilization ?? 0) >= 1 {
                    Text("blocked").font(.caption2).foregroundStyle(.red)
                }
                if let reset = UsageLogic.resetCountdown(resetsAtMs: w.resetsAt) {
                    Text("resets \(reset)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var extraUsage: some View {
        if let eu = quota?.extraUsage, eu.isEnabled == true,
           let limit = eu.monthlyLimit, limit > 0 {
            let used = eu.usedCredits ?? 0
            let cur = eu.currency ?? "$"
            HStack(spacing: 8) {
                Text("Extra").font(.caption).frame(width: 64, alignment: .leading)
                ProgressView(value: min(max(eu.utilization ?? used / limit, 0), 1))
                Text("\(cur)\(used, specifier: "%.2f") / \(cur)\(limit, specifier: "%.2f")")
                    .font(.caption2.monospacedDigit())
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

extension View {
    /// Liquid Glass card on macOS 26+, material fallback below (okf/02 §5).
    @ViewBuilder func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
    }

    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Clears the MenuBarExtra window chrome so the glass cards refract
    /// the desktop rather than an opaque panel.
    @ViewBuilder func clearWindowBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.containerBackground(.clear, for: .window)
        } else {
            self
        }
    }
}
