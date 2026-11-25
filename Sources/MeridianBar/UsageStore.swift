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
    /// Fable route from the model router; nil on plain Meridian or any failure.
    private(set) var modelRoutes: ModelRoutes?
    private(set) var lastSuccess: Date?
    private(set) var offline = true
    private(set) var switchError: String?
    private(set) var accounts: [ManagedAccount] = []
    private(set) var accountError: String?
    private(set) var accountNotice: String?
    private(set) var accountOperation: String?

    private var misses = 0
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private let accountManager = AccountManager()
    private let notifier = UsageNotifier()
    private let isPreview: Bool

    init() {
        isPreview = false
    }

    /// Staged store for `--render-preview` (docs screenshots) — never polls.
    init(
        preview quota: QuotaAll, profiles: ProfilesList, health: Health?,
        accounts: [ManagedAccount] = [], modelRoutes: ModelRoutes? = nil
    ) {
        isPreview = true
        self.quota = quota
        self.profiles = profiles
        self.health = health
        self.lastSuccess = Date()
        self.offline = false
        self.accounts = accounts
        self.modelRoutes = modelRoutes
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
            primaryWindow: primaryWindow, aliasOverrides: Self.aliasOverrides(),
            fableProfile: modelRoutes?.fable
        )
    }

    var canManageAccounts: Bool { !isPreview && accountOperation == nil }

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

    /// Single flight: a call that arrives during a refresh waits for it
    /// instead of starting another.
    func refresh() async {
        if isPreview { return }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        async let accountsRequest: Void = refreshAccounts()
        await refreshMeridian()
        await accountsRequest
    }

    private func refreshAccounts() async {
        do {
            accounts = try await accountManager.accounts()
            if accountOperation == nil { accountError = nil }
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func refreshMeridian() async {
        let client = MeridianClient.configured()
        async let quotaReq = client.quotaAll()
        async let profilesReq = client.profilesList()
        async let healthReq = client.health()
        async let routesReq = client.modelRoutes()
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
        // Health and routes are best-effort garnish; their failure must not
        // mark us offline. Plain Meridian answers 404 for routes.
        health = try? await healthReq
        modelRoutes = try? await routesReq
    }

    func switchProfile(to id: String) async {
        guard let account = accounts.first(where: { $0.name == id }) else {
            switchError = "Account details are unavailable. Refresh and try again."
            return
        }
        activateAccount(account)
    }

    func addAccount(name: String) {
        runAccountAction("Signing in to Claude. Complete sign-in in your browser.") {
            try await self.accountManager.add(name: name)
        }
    }

    func loginAccount(_ account: ManagedAccount) {
        runAccountAction("Signing in to \(account.name). Complete sign-in in your browser.") {
            try await self.accountManager.login(account)
        }
    }

    func activateAccount(_ account: ManagedAccount) {
        runAccountAction("Switching to \(account.name)…") {
            try await self.accountManager.activate(
                account, baseURL: MeridianClient.configured().baseURL)
        }
    }

    func logoutAccount(_ account: ManagedAccount) {
        runAccountAction("Signing out of \(account.name)…") {
            try await self.accountManager.logout(account)
        }
    }

    func removeAccount(_ account: ManagedAccount) {
        runAccountAction("Removing \(account.name)…") {
            try await self.accountManager.remove(account)
        }
    }

    func cancelAccountOperation() {
        accountTask?.cancel()
        Task { await accountManager.cancelLogin() }
    }

    private func runAccountAction(
        _ message: String, operation: @escaping @MainActor () async throws -> Void
    ) {
        guard canManageAccounts else { return }
        accountOperation = message
        accountError = nil
        accountNotice = nil
        switchError = nil
        accountTask = Task {
            var failure: String?
            do {
                try await operation()
                try Task.checkCancellation()
                accountNotice = "Account updated. New CLI sessions use the selected login."
            } catch is CancellationError {
                accountNotice = "Operation cancelled."
            } catch {
                failure = error.localizedDescription
            }
            await refresh()
            accountError = failure ?? accountError
            accountOperation = nil
            accountTask = nil
        }
    }
}
