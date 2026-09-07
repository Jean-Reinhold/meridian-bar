import Foundation
import Testing

@testable import MeridianBar

// Fixtures mirror the rollout records and the live quota shape recorded in
// okf/01 (verified 2026-09-07) with synthetic ids, tokens, and emails.

private let berlin = TimeZone(identifier: "Europe/Berlin")!
private let berlinCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = berlin
    return c
}()
/// 2026-09-07 12:00 in Berlin; the local day spans 2026-09-06T22:00Z to 2026-09-07T22:00Z.
private let noon = Date(timeIntervalSince1970: 1_788_775_200)

private func tokenCount(_ ts: String, input: Int, cached: Int, output: Int, total: Int) -> String {
    """
    {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(total)},"last_token_usage":{"input_tokens":1,"cached_input_tokens":1,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":1},"model_context_window":258400},"rate_limits":null}}
    """
}

private func sessionMeta(_ id: String, _ ts: String) -> String {
    """
    {"timestamp":"\(ts)","type":"session_meta","payload":{"id":"\(id)","timestamp":"\(ts)","cwd":"/tmp","originator":"codex_cli_rs","cli_version":"0.0.0","source":"cli","base_instructions":{"text":"not consumption"}}}
    """
}

private struct CodexHome {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func rollout(_ relative: String, lines: [String], trailingNewline: Bool = true) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = lines.joined(separator: "\n")
        if trailingNewline, !lines.isEmpty { text += "\n" }
        try Data(text.utf8).write(to: file)
        return file
    }

    func auth(accountId: String, email: String, plan: String = "pro") throws {
        let claims = """
            {"email":"\(email)","https://api.openai.com/auth":{"chatgpt_account_id":"\(accountId)","chatgpt_plan_type":"\(plan)"}}
            """
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        let file = """
            {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"last_refresh":"2026-09-07T00:00:00Z",
             "tokens":{"id_token":"\(jwt)","access_token":"test-access-\(accountId)","refresh_token":"r","account_id":"\(accountId)"}}
            """
        try Data(file.utf8).write(to: url.appendingPathComponent("auth.json"))
    }

    func client(quotaURL: URL = CodexUsageClient.quotaURL, now: Date = noon) -> CodexUsageClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return CodexUsageClient(
            codexHome: url, quotaURL: quotaURL, sessionConfiguration: cfg, calendar: berlinCalendar,
            now: { now })
    }
}

/// Per-URL stub so parallel tests never share state. Records the last
/// request per URL for header assertions.
private final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]

    static func set(_ url: URL, _ handler: @escaping Handler) {
        lock.withLock { handlers[url.absoluteString] = handler }
    }

    static func lastRequest(_ url: URL) -> URLRequest? {
        lock.withLock { requests[url.absoluteString] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.requests[key] = request
            return Self.handlers[key]
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubURL() -> URL { URL(string: "https://stub.invalid/\(UUID().uuidString)/usage")! }

private let liveShapedQuota = """
    {"user_id":"u","account_id":"acct-1","email":"live@example.com","plan_type":"pro",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":4,"limit_window_seconds":604800,"reset_after_seconds":260005,"reset_at":1789048219},
       "secondary_window":null},
     "code_review_rate_limit":null,
     "additional_rate_limits":[{"limit_name":"GPT-6 Astra","metered_feature":"x",
       "rate_limit":{"allowed":true,"limit_reached":false,
         "primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":1788806215},
         "secondary_window":{"used_percent":12.5,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":1789393015}},
       "normal_model_slug":null}],
     "model_usage":{"gpt-6-astra":{"available":true}},
     "credits":{"has_credits":false,"unlimited":false,"balance":"0"},
     "rate_limit_reached_type":null,"promo":null,"unknown_future_field":{"a":1}}
    """

@Suite struct CodexLocalUsage {
    @Test func cumulativeTotalsCountOnce() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.rollout(
            "sessions/2026/09/07/rollout-a.jsonl",
            lines: [
                sessionMeta("s1", "2026-09-07T08:00:00.000Z"),
                tokenCount("2026-09-07T08:00:01.000Z", input: 100, cached: 60, output: 20, total: 120),
                tokenCount("2026-09-07T08:00:02.000Z", input: 100, cached: 60, output: 20, total: 120),
                tokenCount("2026-09-07T08:00:03.000Z", input: 250, cached: 200, output: 50, total: 300),
            ])

        let snap = await home.client().snapshot()
        let expected = CodexTokenUsage(inputTokens: 250, cachedInputTokens: 200, outputTokens: 50, totalTokens: 300)
        #expect(snap.today == expected)
        #expect(snap.allTime == expected)
        #expect(snap.sessionCount == 1)
        #expect(snap.lastActivity == Date(timeIntervalSince1970: 1_788_768_003))
        #expect(snap.localError == nil)
    }

    @Test func localDayBoundarySplitsDeltas() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.rollout(
            "sessions/2026/09/06/rollout-a.jsonl",
            lines: [
                sessionMeta("s1", "2026-09-06T21:00:00.000Z"),
                tokenCount("2026-09-06T21:59:30.000Z", input: 80, cached: 0, output: 20, total: 100),
                tokenCount("2026-09-06T22:00:30.000Z", input: 140, cached: 10, output: 40, total: 180),
            ])

        let snap = await home.client().snapshot()
        #expect(snap.today == CodexTokenUsage(inputTokens: 60, cachedInputTokens: 10, outputTokens: 20, totalTokens: 80))
        #expect(snap.allTime == CodexTokenUsage(inputTokens: 140, cachedInputTokens: 10, outputTokens: 40, totalTokens: 180))
    }

    @Test func malformedAndTruncatedRecordsAreSkipped() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.rollout(
            "sessions/2026/09/07/rollout-a.jsonl",
            lines: [
                sessionMeta("s1", "2026-09-07T08:00:00.000Z"),
                "this is not json token_count",
                #"{"timestamp":"2026-09-07T08:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}"#,
                #"{"timestamp":"2026-09-07T08:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{}}}}"#,
                tokenCount("2026-09-07T08:00:03.000Z", input: 30, cached: 0, output: 10, total: 40),
                #"{"timestamp":"2026-09-07T08:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000"#,
            ], trailingNewline: false)
        try home.rollout("sessions/2026/09/07/rollout-empty.jsonl", lines: [])
        try home.rollout("archived_sessions/notes.txt", lines: ["ignored"])

        let snap = await home.client().snapshot()
        #expect(snap.today == CodexTokenUsage(inputTokens: 30, cachedInputTokens: 0, outputTokens: 10, totalTokens: 40))
        #expect(snap.sessionCount == 1)
        #expect(snap.localError == nil)
    }

    @Test func partialTailIsCountedOnceAfterItCompletes() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        let full = tokenCount("2026-09-07T08:00:02.000Z", input: 90, cached: 0, output: 10, total: 100)
        let cut = full.index(full.startIndex, offsetBy: full.count - 40)
        let file = try home.rollout(
            "sessions/2026/09/07/rollout-a.jsonl",
            lines: [
                sessionMeta("s1", "2026-09-07T08:00:00.000Z"),
                tokenCount("2026-09-07T08:00:01.000Z", input: 30, cached: 0, output: 10, total: 40),
                String(full[..<cut]),
            ], trailingNewline: false)
        let client = home.client()

        let first = await client.snapshot()
        #expect(first.today.totalTokens == 40)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let rest = String(full[cut...]) + "\n"
            + tokenCount("2026-09-07T08:00:03.000Z", input: 130, cached: 20, output: 20, total: 150) + "\n"
        try handle.write(contentsOf: Data(rest.utf8))
        try handle.close()

        let second = await client.snapshot()
        #expect(second.today == CodexTokenUsage(inputTokens: 130, cachedInputTokens: 20, outputTokens: 20, totalTokens: 150))
        #expect(second.sessionCount == 1)
    }

    @Test func truncatedFileIsReparsed() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        let path = "sessions/2026/09/07/rollout-a.jsonl"
        try home.rollout(
            path,
            lines: [
                sessionMeta("s1", "2026-09-07T08:00:00.000Z"),
                tokenCount("2026-09-07T08:00:01.000Z", input: 200, cached: 0, output: 100, total: 300),
                tokenCount("2026-09-07T08:00:02.000Z", input: 400, cached: 0, output: 100, total: 500),
            ])
        let client = home.client()
        let before = await client.snapshot()
        #expect(before.allTime.totalTokens == 500)

        try home.rollout(path, lines: [tokenCount("2026-09-07T09:00:00.000Z", input: 20, cached: 0, output: 10, total: 30)])
        let after = await client.snapshot()
        #expect(after.allTime.totalTokens == 30)
    }

    @Test func archivedCopyOfSameSessionCountsOnce() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.rollout(
            "sessions/2026/09/07/rollout-a.jsonl",
            lines: [
                sessionMeta("s1", "2026-09-07T08:00:00.000Z"),
                tokenCount("2026-09-07T08:00:01.000Z", input: 90, cached: 0, output: 10, total: 100),
            ])
        try home.rollout(
            "archived_sessions/rollout-a.jsonl",
            lines: [
                sessionMeta("s1", "2026-09-07T08:00:00.000Z"),
                tokenCount("2026-09-07T08:00:01.000Z", input: 90, cached: 0, output: 10, total: 100),
                tokenCount("2026-09-07T08:00:05.000Z", input: 240, cached: 100, output: 20, total: 260),
            ])
        try home.rollout(
            "sessions/2026/09/07/rollout-b.jsonl",
            lines: [
                sessionMeta("s2", "2026-09-07T09:00:00.000Z"),
                tokenCount("2026-09-07T09:00:01.000Z", input: 5, cached: 0, output: 5, total: 10),
            ])

        let snap = await home.client().snapshot()
        #expect(snap.allTime.totalTokens == 270)
        #expect(snap.sessionCount == 2)
    }
}

@Suite struct CodexQuota {
    @Test func missingLoginStillReportsLocalUsage() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.rollout(
            "sessions/2026/09/07/rollout-a.jsonl",
            lines: [tokenCount("2026-09-07T08:00:01.000Z", input: 30, cached: 0, output: 10, total: 40)])

        let snap = await home.client(quotaURL: stubURL()).snapshot()
        #expect(snap.isLoggedIn == false)
        #expect(snap.windows.isEmpty)
        #expect(snap.quotaError != nil)
        #expect(snap.quotaUpdatedAt == nil)
        #expect(snap.today.totalTokens == 40)
    }

    @Test func decodesLiveShapeIntoWindows() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.auth(accountId: "acct-1", email: "a@example.com")
        let url = stubURL()
        StubProtocol.set(url) { _ in (200, Data(liveShapedQuota.utf8)) }

        let snap = await home.client(quotaURL: url).snapshot()
        #expect(snap.isLoggedIn)
        #expect(snap.quotaError == nil)
        #expect(snap.quotaUpdatedAt == noon)
        #expect(snap.plan == "pro")
        #expect(snap.email == "live@example.com")
        #expect(
            snap.windows == [
                QuotaWindow(type: "seven_day", utilization: 0.04, resetsAt: 1_789_048_219_000),
                QuotaWindow(type: "gpt_6_astra_five_hour", utilization: 0, resetsAt: 1_788_806_215_000),
                QuotaWindow(type: "gpt_6_astra_seven_day", utilization: 0.125, resetsAt: 1_789_393_015_000),
            ])
        let request = try #require(StubProtocol.lastRequest(url))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-acct-1")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
    }

    @Test func expiredAuthIsNotZeroUsage() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.auth(accountId: "acct-1", email: "a@example.com")
        let url = stubURL()
        StubProtocol.set(url) { _ in (401, Data(#"{"detail":"expired"}"#.utf8)) }

        let snap = await home.client(quotaURL: url).snapshot()
        #expect(snap.isLoggedIn)
        #expect(snap.windows.isEmpty)
        #expect(snap.quotaUpdatedAt == nil)
        #expect(snap.quotaError?.contains("expired") == true)
        #expect(snap.email == "a@example.com")
        #expect(snap.plan == "pro")
    }

    @Test func staleQuotaSurvivesOnlyForSameAccount() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.auth(accountId: "acct-1", email: "a@example.com")
        let url = stubURL()
        StubProtocol.set(url) { _ in (200, Data(liveShapedQuota.utf8)) }
        let client = home.client(quotaURL: url)
        let fresh = await client.snapshot()
        #expect(fresh.windows.count == 3)

        StubProtocol.set(url) { _ in (500, Data()) }
        let stale = await client.snapshot()
        #expect(stale.windows == fresh.windows)
        #expect(stale.quotaUpdatedAt == noon)
        #expect(stale.quotaError != nil)

        try home.auth(accountId: "acct-2", email: "b@example.com", plan: "plus")
        let switched = await client.snapshot()
        #expect(switched.windows.isEmpty)
        #expect(switched.quotaUpdatedAt == nil)
        #expect(switched.email == "b@example.com")
        #expect(switched.plan == "plus")
        #expect(switched.quotaError != nil)
    }

    @Test func localFailureDoesNotHideQuota() async throws {
        let home = try CodexHome()
        defer { home.remove() }
        try home.auth(accountId: "acct-1", email: "a@example.com")
        try Data("not a directory".utf8).write(to: home.url.appendingPathComponent("sessions"))
        let url = stubURL()
        StubProtocol.set(url) { _ in (200, Data(liveShapedQuota.utf8)) }

        let snap = await home.client(quotaURL: url).snapshot()
        #expect(snap.localError != nil)
        #expect(snap.windows.count == 3)
        #expect(snap.quotaError == nil)
    }
}
