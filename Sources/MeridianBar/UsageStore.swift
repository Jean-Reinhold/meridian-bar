import AppKit
import Foundation
import Observation

/// Single source of truth. State flows one way: client → store → views.
/// Polls every `pollInterval` seconds; two consecutive misses flip
/// `offline` so a single blip never flaps the bar (okf/02 §3).
@MainActor
@Observable
final class UsageStore {
    private(set) var quota: QuotaAll?
    private(set) var profiles: ProfilesList?
    private(set) var health: Health?
    private(set) var lastSuccess: Date?
    private(set) var offline = true
    private(set) var switchError: String?

    private var misses = 0
    private var pollTask: Task<Void, Never>?
    private let notifier = UsageNotifier()
    private let isPreview: Bool

    init() {
        isPreview = false
    }

    /// Staged store for `--render-preview` (docs screenshots) — never polls.
    init(preview quota: QuotaAll, profiles: ProfilesList, health: Health?) {
        isPreview = true
        self.quota = quota
        self.profiles = profiles
        self.health = health
        self.lastSuccess = Date()
        self.offline = false
    }

    var pollInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "pollInterval")
        return v >= 5 ? v : 60
    }

    var primaryWindow: String {
        UserDefaults.standard.string(forKey: "primaryWindow")
            ?? UsageLogic.defaultPrimaryWindow
    }

    var labelStyle: LabelStyle {
        LabelStyle(rawValue: UserDefaults.standard.string(forKey: "labelStyle") ?? "") ?? .segments
    }

    static func aliasOverrides() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: "aliasOverrides") ?? [:])
            .compactMapValues { $0 as? String }
    }

    var segments: [ProfileSegment] {
        UsageLogic.segments(
            quota: quota, profiles: profiles,
            primaryWindow: primaryWindow, aliasOverrides: Self.aliasOverrides()
        )
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.pollInterval ?? 60
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    func refresh() async {
        if isPreview { return }
        let client = MeridianClient.configured()
        async let quotaReq = client.quotaAll()
        async let profilesReq = client.profilesList()
        async let healthReq = client.health()
        do {
            let (q, p) = try await (quotaReq, profilesReq)
            quota = q
            profiles = p
            lastSuccess = Date()
            misses = 0
            offline = false
            notifier.process(quota: q)
        } catch {
            misses += 1
            if misses >= 2 { offline = true }
        }
        // Health is best-effort garnish; its failure must not mark us offline.
        health = try? await healthReq
    }

    func switchProfile(to id: String) async {
        do {
            try await MeridianClient.configured().switchProfile(id)
            switchError = nil
        } catch {
            switchError = "Could not switch profile — is Meridian up?"
        }
        await refresh()
    }
}
