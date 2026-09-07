import Foundation

// Local Codex consumption and account-wide ChatGPT quota (okf/01, verified
// 2026-09-07). Two independent sources feed one immutable snapshot:
//
// - Local: `token_count` and `session_meta` records in `$CODEX_HOME/sessions`
//   and `archived_sessions`. Nothing else in a rollout is decoded, so user
//   text and tool output never enter this process.
// - Live: `GET https://chatgpt.com/backend-api/wham/usage` with the bearer
//   access token and `ChatGPT-Account-Id` from `auth.json`.
//
// Local token counts are consumption, not billed cost, and are never
// converted to money here.

/// Token counters as Codex reports them. `cachedInputTokens` is the cached
/// subset of `inputTokens`, not an additional amount.
struct CodexTokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var totalTokens: Int64 = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens)
    }

    static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }

    /// Growth from `previous` to `self`. Codex writes cumulative per-session
    /// totals, so the delta is the actual consumption since the last record.
    /// A counter that went backwards means the session restarted its
    /// counters; then the new total is counted from zero.
    func delta(since previous: Self) -> Self {
        if totalTokens < previous.totalTokens { return self }
        return Self(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            totalTokens: max(0, totalTokens - previous.totalTokens))
    }
}

struct CodexUsageSnapshot: Equatable, Sendable {
    var email: String?
    var plan: String?
    /// Account-wide quota windows: `utilization` 0–1, `resetsAt` epoch ms.
    /// Types: `five_hour`/`seven_day` for the main limit, `review_*` for code
    /// review, `<limit name>_*` for additional limits.
    var windows: [QuotaWindow]
    /// Local consumption during the current local calendar day.
    var today: CodexTokenUsage
    /// Local consumption across every rollout on disk.
    var allTime: CodexTokenUsage
    var sessionCount: Int
    var lastActivity: Date?
    /// When `windows` were last fetched successfully. Older than the snapshot
    /// when `quotaError` reports a stale refresh.
    var quotaUpdatedAt: Date?
    var quotaError: String?
    var localError: String?
    var isLoggedIn: Bool

    init(
        email: String? = nil,
        plan: String? = nil,
        windows: [QuotaWindow] = [],
        today: CodexTokenUsage = .init(),
        allTime: CodexTokenUsage = .init(),
        sessionCount: Int = 0,
        lastActivity: Date? = nil,
        quotaUpdatedAt: Date? = nil,
        quotaError: String? = nil,
        localError: String? = nil,
        isLoggedIn: Bool = false
    ) {
        self.email = email
        self.plan = plan
        self.windows = windows
        self.today = today
        self.allTime = allTime
        self.sessionCount = sessionCount
        self.lastActivity = lastActivity
        self.quotaUpdatedAt = quotaUpdatedAt
        self.quotaError = quotaError
        self.localError = localError
        self.isLoggedIn = isLoggedIn
    }
}

actor CodexUsageClient {
    static let quotaURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let codexHome: URL
    private let quotaURL: URL
    private let session: URLSession
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// `wham/usage` is rate limited per IP and OMP polls it too, so a fresh
    /// fetch happens at most every `quotaRefreshInterval` (default 5 min)
    /// and, after a failure, every `quotaRetryInterval` (default 1 min).
    private let quotaRefreshInterval: TimeInterval
    private let quotaRetryInterval: TimeInterval

    private var files: [String: SessionFileState] = [:]
    private var filesTimeZone: String
    private var lastQuota: QuotaMemory?
    private var lastQuotaAttempt: Date?
    private var lastQuotaError: String?

    /// `home` is the user home. With the default home, `CODEX_HOME` overrides
    /// the Codex directory the same way it does for the Codex CLI.
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let override = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? ""
        let codexHome =
            override.isEmpty
            ? home.appendingPathComponent(".codex", isDirectory: true)
            : URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        self.init(codexHome: codexHome)
    }

    /// Injection point for tests: explicit Codex directory, quota endpoint,
    /// URL protocol stubs, calendar, and clock.
    init(
        codexHome: URL,
        quotaURL: URL = CodexUsageClient.quotaURL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init,
        quotaRefreshInterval: TimeInterval = 300,
        quotaRetryInterval: TimeInterval = 60
    ) {
        self.codexHome = codexHome
        self.quotaURL = quotaURL
        sessionConfiguration.timeoutIntervalForRequest = 8
        sessionConfiguration.timeoutIntervalForResource = 10
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: sessionConfiguration)
        self.calendar = calendar
        self.now = now
        self.quotaRefreshInterval = quotaRefreshInterval
        self.quotaRetryInterval = quotaRetryInterval
        self.filesTimeZone = calendar.timeZone.identifier
    }

    /// `forceQuota` bypasses the fetch throttle (user-initiated refresh).
    func snapshot(forceQuota: Bool = false) async -> CodexUsageSnapshot {
        let auth = Self.loadAuth(at: codexHome.appendingPathComponent("auth.json"))
        let fetch = forceQuota || shouldFetchQuota(for: auth)
        async let quota = fetch ? Self.fetchQuota(session: session, url: quotaURL, auth: auth) : .cached

        let local = await loadLocal()
        let quotaResult = await quota
        if fetch, case .chatGPT = auth { lastQuotaAttempt = now() }
        return assemble(auth: auth, quota: quotaResult, local: local)
    }

    private func shouldFetchQuota(for auth: AuthState) -> Bool {
        guard case .chatGPT = auth else { return true }
        guard let remembered = lastQuota, remembered.accountId == auth.accountId,
            let attempt = lastQuotaAttempt
        else { return true }
        let interval = lastQuotaError == nil ? quotaRefreshInterval : quotaRetryInterval
        return now().timeIntervalSince(attempt) >= interval
    }

    // MARK: - Snapshot assembly

    private func assemble(auth: AuthState, quota: QuotaResult, local: LocalUsage) -> CodexUsageSnapshot {
        var snap = CodexUsageSnapshot(
            today: local.today,
            allTime: local.allTime,
            sessionCount: local.sessionCount,
            lastActivity: local.lastActivity,
            localError: local.error)

        let identity = auth.accountId
        if let remembered = lastQuota, remembered.accountId != identity {
            lastQuota = nil
        }

        switch auth {
        case .missing:
            snap.isLoggedIn = false
            snap.quotaError = "Codex is not logged in."
        case .apiKey:
            snap.isLoggedIn = true
            snap.quotaError = "Codex uses an API key; ChatGPT quota is unavailable."
        case .chatGPT(let creds):
            snap.isLoggedIn = true
            snap.email = creds.email
            snap.plan = creds.plan
        }

        switch quota {
        case .none:
            break
        case .success(let response):
            let fetchedAt = now()
            let windows = Self.windows(from: response, now: fetchedAt)
            lastQuota = QuotaMemory(
                accountId: identity, windows: windows, plan: response.planType,
                email: response.email, updatedAt: fetchedAt)
            lastQuotaError = nil
            snap.windows = windows
            snap.quotaUpdatedAt = fetchedAt
            if let plan = response.planType { snap.plan = plan }
            if let email = response.email { snap.email = email }
        case .failure(let reason):
            lastQuotaError = reason
            applyRemembered(to: &snap, identity: identity, error: reason)
        case .cached:
            applyRemembered(to: &snap, identity: identity, error: lastQuotaError)
        }
        return snap
    }

    /// Fills the snapshot from the last successful fetch for the same
    /// account; `error` explains why no fresh data replaced it.
    private func applyRemembered(to snap: inout CodexUsageSnapshot, identity: String?, error: String?) {
        if let remembered = lastQuota, remembered.accountId == identity, identity != nil {
            snap.windows = remembered.windows
            snap.quotaUpdatedAt = remembered.updatedAt
            if snap.plan == nil { snap.plan = remembered.plan }
            if snap.email == nil { snap.email = remembered.email }
            if let error { snap.quotaError = "\(error) Showing quota from the last successful refresh." }
        } else if let error {
            snap.quotaError = error
        }
    }

    // MARK: - Local rollouts

    private struct LocalUsage: Sendable {
        var today = CodexTokenUsage()
        var allTime = CodexTokenUsage()
        var sessionCount = 0
        var lastActivity: Date?
        var error: String?
    }

    private func loadLocal() async -> LocalUsage {
        if calendar.timeZone.identifier != filesTimeZone {
            files.removeAll()
            filesTimeZone = calendar.timeZone.identifier
        }

        var result = LocalUsage()
        let listing = Self.listRollouts(in: codexHome)
        result.error = listing.error

        // Parse changed files off the actor: a cold start streams every
        // rollout on disk (gigabytes), and that must not pin an executor.
        let calendar = self.calendar
        let work = listing.files.map { entry in (entry, files[entry.path]) }
        let parsed = await Task.detached(priority: .utility) {
            work.map { entry, cached in (entry.path, Self.refresh(entry, cached: cached, calendar: calendar)) }
        }.value

        var fresh: [String: SessionFileState] = [:]
        fresh.reserveCapacity(parsed.count)
        for (path, state) in parsed { fresh[path] = state }
        files = fresh

        // A rollout moved to archived_sessions mid-run may exist under both
        // roots until the next pass; count each session id once, preferring
        // the copy that has seen the most consumption.
        var bySession: [String: SessionAccumulator] = [:]
        for (path, state) in files {
            let acc = state.effective
            guard acc.sessionId != nil || acc.hasUsage else { continue }
            let key = acc.sessionId ?? path
            if let existing = bySession[key], existing.consumed.totalTokens >= acc.consumed.totalTokens {
                continue
            }
            bySession[key] = acc
        }

        let todayKey = DayKey(calendar: calendar, date: now())
        for acc in bySession.values {
            result.sessionCount += 1
            result.allTime += acc.consumed
            if let today = acc.byDay[todayKey] { result.today += today }
            if let activity = acc.lastActivity, result.lastActivity.map({ activity > $0 }) ?? true {
                result.lastActivity = activity
            }
        }
        return result
    }

    private struct RolloutEntry: Sendable {
        var path: String
        var size: UInt64
        var modified: Date
    }

    private static func listRollouts(in codexHome: URL) -> (files: [RolloutEntry], error: String?) {
        var entries: [RolloutEntry] = []
        var error: String?
        let fm = FileManager.default
        for name in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            guard isDir.boolValue else {
                error = "\(name) is not a directory."
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            guard
                let enumerator = fm.enumerator(
                    at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else {
                error = "Could not list \(name)."
                continue
            }
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                    let values = try? url.resourceValues(forKeys: Set(keys)),
                    values.isRegularFile == true
                else { continue }
                entries.append(
                    RolloutEntry(
                        path: url.path,
                        size: UInt64(values.fileSize ?? 0),
                        modified: values.contentModificationDate ?? .distantPast))
            }
        }
        return (entries, error)
    }

    // MARK: - Per-file incremental parsing

    private struct DayKey: Hashable, Sendable {
        var year: Int
        var month: Int
        var day: Int

        init(calendar: Calendar, date: Date) {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            year = c.year ?? 0
            month = c.month ?? 0
            day = c.day ?? 0
        }
    }

    private struct SessionAccumulator: Sendable {
        var sessionId: String?
        var lastTotal: CodexTokenUsage?
        var consumed = CodexTokenUsage()
        var byDay: [DayKey: CodexTokenUsage] = [:]
        var lastActivity: Date?
        var hasUsage: Bool { lastTotal != nil }

        mutating func apply(_ record: RolloutRecord, calendar: Calendar) {
            guard let payload = record.payload else { return }
            let stamp = (record.timestamp ?? payload.timestamp).flatMap(CodexUsageClient.parseDate)
            // `session_meta` is typed at the record level; usage events are
            // `event_msg` records typed in their payload.
            switch (record.type, payload.type) {
            case ("session_meta", _):
                if let id = payload.id, sessionId == nil { sessionId = id }
                touch(stamp)
            case ("event_msg", "token_count"):
                guard let raw = payload.info?.totalTokenUsage else { return }
                let total = raw.usage
                let delta = lastTotal.map(total.delta(since:)) ?? total
                lastTotal = total
                consumed += delta
                if let stamp {
                    byDay[DayKey(calendar: calendar, date: stamp), default: .init()] += delta
                }
                touch(stamp)
            default:
                return
            }
        }

        private mutating func touch(_ stamp: Date?) {
            guard let stamp else { return }
            if lastActivity.map({ stamp > $0 }) ?? true { lastActivity = stamp }
        }
    }

    private struct SessionFileState: Sendable {
        var size: UInt64
        var modified: Date
        /// Bytes consumed through the last newline; the region after it is
        /// re-read on the next pass so a line written in two parts is
        /// counted exactly once.
        var committedOffset: UInt64
        var committed: SessionAccumulator
        /// `committed` plus a trailing partial line when it already parses.
        var effective: SessionAccumulator
    }

    private static func refresh(_ entry: RolloutEntry, cached: SessionFileState?, calendar: Calendar)
        -> SessionFileState
    {
        if let cached, cached.size == entry.size, cached.modified == entry.modified {
            return cached
        }
        var state: SessionFileState
        if let cached, entry.size >= cached.committedOffset, entry.modified >= cached.modified {
            state = cached
        } else {
            state = SessionFileState(
                size: 0, modified: .distantPast, committedOffset: 0,
                committed: SessionAccumulator(), effective: SessionAccumulator())
        }
        state.size = entry.size
        state.modified = entry.modified

        guard let handle = FileHandle(forReadingAtPath: entry.path) else {
            state.effective = state.committed
            return state
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.committedOffset)
        } catch {
            state.committedOffset = 0
            state.committed = SessionAccumulator()
            state.effective = state.committed
            return state
        }

        var carry = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            let buffer = carry.isEmpty ? chunk : carry + chunk
            let consumed = buffer.withUnsafeBytes { raw -> Int in
                var start = 0
                while start < raw.count,
                    let nl = memchr(raw.baseAddress! + start, 0x0A, raw.count - start)
                {
                    let end = UnsafeRawPointer(nl) - raw.baseAddress!
                    if let record = decodeLine(raw[start..<end]) {
                        state.committed.apply(record, calendar: calendar)
                    }
                    start = end + 1
                }
                return start
            }
            state.committedOffset += UInt64(consumed)
            carry = consumed < buffer.count ? Data(buffer[(buffer.startIndex + consumed)...]) : Data()
        }

        state.effective = state.committed
        if !carry.isEmpty, let record = carry.withUnsafeBytes({ decodeLine($0[...]) }) {
            state.effective.apply(record, calendar: calendar)
        }
        return state
    }

    private static let tokenCountNeedle = Array("token_count".utf8)
    private static let sessionMetaNeedle = Array("session_meta".utf8)

    private static func contains(_ bytes: Slice<UnsafeRawBufferPointer>, _ needle: [UInt8]) -> Bool {
        guard bytes.count >= needle.count, let base = bytes.base.baseAddress else { return false }
        return needle.withUnsafeBytes { n in
            memmem(base + bytes.startIndex, bytes.count, n.baseAddress!, n.count) != nil
        }
    }

    /// Decodes one rollout line into the few fields consumption needs.
    /// Lines without a usage or session marker are never parsed as JSON.
    private static func decodeLine(_ bytes: Slice<UnsafeRawBufferPointer>) -> RolloutRecord? {
        var bytes = bytes
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        guard !bytes.isEmpty,
            contains(bytes, tokenCountNeedle) || contains(bytes, sessionMetaNeedle),
            let base = bytes.base.baseAddress
        else { return nil }
        let data = Data(bytes: base + bytes.startIndex, count: bytes.count)
        return try? JSONDecoder().decode(RolloutRecord.self, from: data)
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeISO8601 = Date.ISO8601FormatStyle()

    private static func parseDate(_ text: String) -> Date? {
        (try? fractionalISO8601.parse(text)) ?? (try? wholeISO8601.parse(text))
    }

    private struct RolloutRecord: Decodable, Sendable {
        var type: String?
        var timestamp: String?
        var payload: Payload?

        struct Payload: Decodable, Sendable {
            var type: String?
            var id: String?
            var timestamp: String?
            var info: Info?
        }

        struct Info: Decodable, Sendable {
            var totalTokenUsage: RawUsage?
            enum CodingKeys: String, CodingKey { case totalTokenUsage = "total_token_usage" }
        }

        struct RawUsage: Decodable, Sendable {
            var inputTokens: Int64?
            var cachedInputTokens: Int64?
            var outputTokens: Int64?
            var totalTokens: Int64?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case outputTokens = "output_tokens"
                case totalTokens = "total_tokens"
            }

            var usage: CodexTokenUsage {
                CodexTokenUsage(
                    inputTokens: inputTokens ?? 0,
                    cachedInputTokens: cachedInputTokens ?? 0,
                    outputTokens: outputTokens ?? 0,
                    totalTokens: totalTokens ?? 0)
            }
        }
    }

    // MARK: - auth.json

    private struct ChatGPTCredentials: Sendable {
        var accessToken: String
        var accountId: String?
        var email: String?
        var plan: String?
    }

    private enum AuthState: Sendable {
        case missing
        case apiKey
        case chatGPT(ChatGPTCredentials)

        var accountId: String? {
            if case .chatGPT(let creds) = self { return creds.accountId }
            return nil
        }
    }

    private struct AuthFile: Decodable {
        var authMode: String?
        var apiKey: String?
        var tokens: Tokens?

        enum CodingKeys: String, CodingKey {
            case authMode = "auth_mode"
            case apiKey = "OPENAI_API_KEY"
            case tokens
        }

        struct Tokens: Decodable {
            var accessToken: String?
            var accountId: String?
            var idToken: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
                case idToken = "id_token"
            }
        }
    }

    /// Unverified metadata claims from the id token. Only used for display
    /// and account-change detection; the server decides whether the login
    /// is valid.
    private struct IDTokenClaims: Decodable {
        var email: String?
        var auth: Auth?

        enum CodingKeys: String, CodingKey {
            case email
            case auth = "https://api.openai.com/auth"
        }

        struct Auth: Decodable {
            var chatgptAccountId: String?
            var chatgptPlanType: String?

            enum CodingKeys: String, CodingKey {
                case chatgptAccountId = "chatgpt_account_id"
                case chatgptPlanType = "chatgpt_plan_type"
            }
        }
    }

    private static func loadAuth(at url: URL) -> AuthState {
        guard let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(AuthFile.self, from: data)
        else { return .missing }
        guard let token = file.tokens?.accessToken, !token.isEmpty else {
            if let key = file.apiKey, !key.isEmpty { return .apiKey }
            return .missing
        }
        let claims = file.tokens?.idToken.flatMap(decodeClaims)
        return .chatGPT(
            ChatGPTCredentials(
                accessToken: token,
                accountId: file.tokens?.accountId ?? claims?.auth?.chatgptAccountId,
                email: claims?.email,
                plan: claims?.auth?.chatgptPlanType))
    }

    private static func decodeClaims(fromJWT jwt: String) -> IDTokenClaims? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONDecoder().decode(IDTokenClaims.self, from: data)
    }

    // MARK: - Live quota

    private struct QuotaMemory: Sendable {
        var accountId: String?
        var windows: [QuotaWindow]
        var plan: String?
        var email: String?
        var updatedAt: Date
    }

    private enum QuotaResult: Sendable {
        case none
        case cached
        case success(QuotaResponse)
        case failure(String)
    }

    /// Shape verified live 2026-09-07 (okf/01). Every field optional: the
    /// endpoint is undocumented and windows may be null.
    private struct QuotaResponse: Decodable, Sendable {
        var email: String?
        var planType: String?
        var rateLimit: RateLimit?
        var codeReviewRateLimit: RateLimit?
        var additionalRateLimits: [AdditionalLimit]?

        struct RateLimit: Decodable, Sendable {
            var primaryWindow: Window?
            var secondaryWindow: Window?
        }

        struct Window: Decodable, Sendable {
            var usedPercent: Double?
            var limitWindowSeconds: Double?
            var resetAfterSeconds: Double?
            var resetAt: Double?
        }

        struct AdditionalLimit: Decodable, Sendable {
            var limitName: String?
            var rateLimit: RateLimit?
        }
    }

    /// Refuses every redirect: credentials go to the fixed endpoint only.
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static func fetchQuota(session: URLSession, url: URL, auth: AuthState) async -> QuotaResult {
        guard case .chatGPT(let creds) = auth else { return .none }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = creds.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MeridianBar", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectBlocker())
        } catch {
            return .failure("ChatGPT quota unavailable: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure("ChatGPT quota unavailable: no HTTP response.")
        }
        switch http.statusCode {
        case 200..<300:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let decoded = try? decoder.decode(QuotaResponse.self, from: data) else {
                return .failure("ChatGPT quota response could not be decoded.")
            }
            return .success(decoded)
        case 401, 403:
            return .failure("Codex login expired or rejected; run codex login.")
        case 429:
            return .failure("ChatGPT quota rate limited (HTTP 429).")
        default:
            return .failure("ChatGPT quota unavailable (HTTP \(http.statusCode)).")
        }
    }

    private static func windows(from response: QuotaResponse, now: Date) -> [QuotaWindow] {
        var out: [QuotaWindow] = []
        func add(_ limit: QuotaResponse.RateLimit?, scope: String?) {
            guard let limit else { return }
            for (window, fallback) in [(limit.primaryWindow, "primary"), (limit.secondaryWindow, "secondary")] {
                guard let window else { continue }
                let duration = durationLabel(seconds: window.limitWindowSeconds) ?? fallback
                let type = scope.map { "\($0)_\(duration)" } ?? duration
                let resetsAt: Double? =
                    window.resetAt.map { $0 * 1000 }
                    ?? window.resetAfterSeconds.map { (now.timeIntervalSince1970 + $0) * 1000 }
                out.append(
                    QuotaWindow(type: type, utilization: window.usedPercent.map { $0 / 100 }, resetsAt: resetsAt))
            }
        }
        add(response.rateLimit, scope: nil)
        add(response.codeReviewRateLimit, scope: "review")
        for (index, extra) in (response.additionalRateLimits ?? []).enumerated() {
            add(extra.rateLimit, scope: slug(extra.limitName) ?? "additional_\(index + 1)")
        }
        return out
    }

    private static func durationLabel(seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let s = Int(seconds.rounded())
        switch s {
        case 18000: return "five_hour"
        case 604_800: return "seven_day"
        case _ where s % 86400 == 0: return "\(s / 86400)_day"
        case _ where s % 3600 == 0: return "\(s / 3600)_hour"
        default: return "\(max(1, s / 60))_minute"
        }
    }

    private static func slug(_ name: String?) -> String? {
        guard let name else { return nil }
        var out = ""
        var pendingSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !out.isEmpty { out.append("_") }
                pendingSeparator = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return out.isEmpty ? nil : out
    }
}
