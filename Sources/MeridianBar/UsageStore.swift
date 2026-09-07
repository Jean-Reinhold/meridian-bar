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
    private(set) var codex = CodexUsageSnapshot()
    private(set) var accounts: [ManagedAccount] = []
    private(set) var accountError: String?
    private(set) var accountNotice: String?
    private(set) var accountOperation: String?
    /// OMP's `openai-codex` pool and which of our Codex accounts are in it.
    private(set) var omp = OMPPoolStatus()
    private(set) var ompRoutedAccountIDs: Set<String> = []

    private var misses = 0
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    /// Identity keys auto-sync already tried this launch, so a failing
    /// import is reported once instead of every poll.
    private var ompAutoSyncAttempted: Set<String> = []
    private let codexClient = CodexUsageClient()
    private let accountManager = AccountManager()
    private let ompSync = OMPAccountSync()
    private let notifier = UsageNotifier()
    private let isPreview: Bool

    init() {
        isPreview = false
    }

    /// Staged store for `--render-preview` (docs screenshots) — never polls.
    init(
        preview quota: QuotaAll, profiles: ProfilesList, health: Health?,
        codex: CodexUsageSnapshot = .init(), accounts: [ManagedAccount] = []
    ) {
        isPreview = true
        self.quota = quota
        self.profiles = profiles
        self.health = health
        self.lastSuccess = Date()
        self.offline = false
        self.codex = codex
        self.accounts = accounts
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

    var canManageAccounts: Bool { !isPreview && accountOperation == nil }

    /// Keep OMP's OpenAI pool equal to the Codex accounts saved here (default on).
    var ompSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ompSyncEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "ompSyncEnabled")
            ompAutoSyncAttempted.removeAll()
            Task { await refresh() }
        }
    }

    func isRoutedInOMP(_ account: ManagedAccount) -> Bool {
        ompRoutedAccountIDs.contains(account.id)
    }

    var codexSegment: ProfileSegment? {
        guard codex.isLoggedIn || codex.lastActivity != nil else { return nil }
        return UsageLogic.codexSegment(windows: codex.windows)
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
        async let codexRequest = codexClient.snapshot()
        async let accountsRequest: Void = refreshAccounts()
        await refreshMeridian()
        codex = await codexRequest
        await accountsRequest
    }

    private func refreshAccounts() async {
        do {
            accounts = try await accountManager.accounts()
            if accountOperation == nil { accountError = nil }
        } catch {
            accountError = error.localizedDescription
        }
        await refreshOMP()
    }

    /// Reads OMP's pool, then (when enabled) imports saved Codex accounts
    /// that are missing from it. Rows already in the pool are left alone so
    /// a token OMP refreshed is never overwritten by an older copy.
    private func refreshOMP() async {
        omp = await ompSync.status()
        var routed: Set<String> = []
        var identities: [(ManagedAccount, CodexIdentity)] = []
        for account in accounts where account.provider == .codex {
            guard let identity = await accountManager.codexIdentity(account) else { continue }
            identities.append((account, identity))
            if omp.contains(identity) { routed.insert(account.id) }
        }
        ompRoutedAccountIDs = routed
        guard ompSyncEnabled, omp.isManageable, accountOperation == nil else { return }
        var connectedAny = false
        for (account, identity) in identities
        where !routed.contains(account.id) && identity.planType != "api-key"
            && !ompAutoSyncAttempted.contains(identity.key)
        {
            ompAutoSyncAttempted.insert(identity.key)
            do {
                try await ompSync.connect(name: account.name, authFile: accountManager.codexAuthFile(account))
                connectedAny = true
            } catch {
                accountError = "OMP sync for \"\(account.name)\": \(error.localizedDescription)"
            }
        }
        if connectedAny {
            omp = await ompSync.status()
            for (account, identity) in identities where omp.contains(identity) { routed.insert(account.id) }
            ompRoutedAccountIDs = routed
        }
    }

    private func refreshMeridian() async {
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
        guard let account = accounts.first(where: { $0.provider == .claude && $0.name == id }) else {
            switchError = "Account details are unavailable. Refresh and try again."
            return
        }
        activateAccount(account)
    }

    func addAccount(provider: AccountProvider, name: String) {
        runAccountAction("Signing in to \(provider.title). Complete sign-in in your browser.") {
            try await self.accountManager.add(provider: provider, name: name)
            if provider == .codex { try await self.connectToOMP(named: name) }
        }
    }

    func loginAccount(_ account: ManagedAccount) {
        runAccountAction("Signing in to \(account.name). Complete sign-in in your browser.") {
            try await self.accountManager.login(account)
            // A fresh sign-in supersedes whatever OMP holds for this identity.
            if account.provider == .codex { try await self.connectToOMP(named: account.name) }
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
            try await self.disconnectFromOMP(account)
            try await self.accountManager.logout(account)
        }
    }

    func removeAccount(_ account: ManagedAccount) {
        runAccountAction("Removing \(account.name)…") {
            try await self.disconnectFromOMP(account)
            try await self.accountManager.remove(account)
        }
    }

    /// Imports every saved Codex sign-in that OMP does not have yet.
    func syncOMPNow() {
        runAccountAction("Updating OMP's OpenAI accounts…") {
            self.ompAutoSyncAttempted.removeAll()
            let status = await self.ompSync.status()
            if let error = status.error { throw error }
            for account in self.accounts where account.provider == .codex && account.isLoggedIn {
                guard let identity = await self.accountManager.codexIdentity(account),
                    identity.planType != "api-key", !status.contains(identity)
                else { continue }
                try await self.connectToOMP(named: account.name)
            }
        }
    }

    func cancelAccountOperation() {
        accountTask?.cancel()
        Task { await accountManager.cancelLogin() }
    }

    private func connectToOMP(named name: String) async throws {
        guard ompSyncEnabled else { return }
        let refreshed = try await accountManager.accounts()
        guard let account = refreshed.first(where: { $0.provider == .codex && $0.name == name }),
            account.isLoggedIn
        else { return }
        let status = await ompSync.status()
        guard status.isManageable else { return }
        try await ompSync.connect(name: name, authFile: accountManager.codexAuthFile(account))
    }

    /// Drops the account from OMP's pool before the sign-in is gone locally,
    /// so OMP never keeps a copy of a credential the user just removed.
    private func disconnectFromOMP(_ account: ManagedAccount) async throws {
        guard account.provider == .codex, ompSyncEnabled,
            let identity = await accountManager.codexIdentity(account)
        else { return }
        let status = await ompSync.status()
        guard status.isManageable, status.contains(identity) else { return }
        var keeping: [(name: String, authFile: URL, identity: CodexIdentity)] = []
        for other in accounts where other.provider == .codex && other.id != account.id && other.isLoggedIn {
            guard let otherIdentity = await accountManager.codexIdentity(other), otherIdentity.key != identity.key,
                let file = try? await accountManager.codexAuthFile(other)
            else { continue }
            keeping.append((other.name, file, otherIdentity))
        }
        try await ompSync.disconnect(identity: identity, keeping: keeping)
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
