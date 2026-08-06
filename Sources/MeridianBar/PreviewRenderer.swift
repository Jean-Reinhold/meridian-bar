import AppKit
import SwiftUI

/// `MeridianBar --render-preview <dir>` renders the dropdown and the bar
/// label with staged data (no real accounts) for README screenshots,
/// then exits. Never touches the network.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        guard let i = CommandLine.arguments.firstIndex(of: "--render-preview"),
            CommandLine.arguments.indices.contains(i + 1)
        else { return }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        do {
            try render(into: URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render-preview failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private enum Failure: Error { case noImage }

    private static func render(into dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = stagedStore()

        // ImageRenderer drops AppKit-bridged controls (ProgressView,
        // Toggle), so the dropdown goes through a real hosting view.
        let view = UsageMenuView(store: store)
            .environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw Failure.noImage
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.noImage
        }
        try png.write(to: dir.appendingPathComponent("dropdown.png"))

        // The label sits on a dark pill so it reads on any README theme.
        let label = MenuBarLabel.render(segments: store.segments, offline: false)
        let pill = NSImage(
            size: NSSize(width: label.size.width + 24, height: 30), flipped: false
        ) { rect in
            NSColor(white: 0.11, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            label.draw(
                at: NSPoint(x: 12, y: (rect.height - label.size.height) / 2),
                from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        guard let pillCG = pill.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw Failure.noImage
        }
        try savePNG(pillCG, to: dir.appendingPathComponent("label.png"))
    }

    private static func savePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure.noImage
        }
        try data.write(to: url)
    }

    private static func stagedStore() -> UsageStore {
        let now = Date().timeIntervalSince1970 * 1000
        let hour = 3_600_000.0
        func w(_ type: String, _ u: Double, _ resetsInHours: Double) -> QuotaWindow {
            QuotaWindow(type: type, utilization: u, resetsAt: now + resetsInHours * hour)
        }
        let quota = QuotaAll(profiles: [
            ProfileQuota(
                id: "personal", error: nil, fetchedAt: now,
                windows: [
                    w("five_hour", 0.12, 3), w("seven_day", 0.48, 52),
                    w("seven_day_fable", 0.34, 52),
                ], extraUsage: nil),
            ProfileQuota(
                id: "work", error: nil, fetchedAt: now,
                windows: [
                    w("five_hour", 0.05, 2), w("seven_day", 0.66, 30),
                    w("seven_day_fable", 0.91, 30),
                ], extraUsage: nil),
            ProfileQuota(
                id: "team_eu", error: nil, fetchedAt: now,
                windows: [
                    w("five_hour", 0.4, 4), w("seven_day", 0.83, 61),
                    w("seven_day_fable", 1.0, 61),
                ], extraUsage: nil),
        ])
        let profiles = ProfilesList(
            profiles: [
                ProfileInfo(
                    id: "personal", type: "claude-max", isActive: false,
                    email: "personal@example.com", subscriptionType: "max", loggedIn: true,
                    lastSuccessAt: now),
                ProfileInfo(
                    id: "work", type: "claude-max", isActive: true,
                    email: "work@example.com", subscriptionType: "max", loggedIn: true,
                    lastSuccessAt: now),
                ProfileInfo(
                    id: "team_eu", type: "claude-max", isActive: false,
                    email: "team@example.com", subscriptionType: "max", loggedIn: true,
                    lastSuccessAt: now),
            ],
            activeProfile: "work", routing: "priority",
            profileOrder: ["personal", "work", "team_eu"], exhausted: ["team_eu"]
        )
        let health = Health(
            status: "healthy", version: "1.60.0",
            auth: HealthAuth(
                loggedIn: true, email: nil, subscriptionType: "max",
                renewalRequiredSoon: false, daysUntilRenewal: 30))
        return UsageStore(preview: quota, profiles: profiles, health: health)
    }
}
