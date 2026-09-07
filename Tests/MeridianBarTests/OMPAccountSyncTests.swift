import Foundation
import SQLite3
import Testing

@testable import MeridianBar

// OMP integration runs against a throwaway HOME with a hand-built copy of
// OMP's credential table and a scripted `omp`. No real omp runs and no real
// credential is read.

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func jwt(_ claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "\(base64URL(Data("{\"alg\":\"none\"}".utf8))).\(base64URL(payload)).sig"
}

private let expiry = 1_800_000_000.0

private func codexAuth(email: String, accountId: String, apiKeyOnly: Bool = false) -> Data {
    var object: [String: Any] = ["auth_mode": apiKeyOnly ? "apikey" : "chatgpt", "last_refresh": "2026-09-07T00:00:00Z"]
    if apiKeyOnly {
        object["OPENAI_API_KEY"] = "sk-test"
    } else {
        object["tokens"] = [
            "id_token": jwt([
                "email": email,
                "https://api.openai.com/auth": ["chatgpt_account_id": accountId, "chatgpt_plan_type": "plus"],
            ]),
            "access_token": jwt(["exp": expiry]),
            "refresh_token": "refresh-\(accountId)",
            "account_id": accountId,
        ]
    }
    return try! JSONSerialization.data(withJSONObject: object)
}

private struct Call: Equatable, Sendable {
    var arguments: [String]
    var stagedFiles: [String]
}

/// Records every omp invocation and inspects the staging directory before it
/// is deleted, since the real CLI would read the file at that moment.
private final class FakeRunner: CLIProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Call] = []
    var importOutput = Data("{\"dryRun\":false,\"imported\":[{\"provider\":\"openai-codex\"}],\"plan\":[],\"skipped\":[]}\n".utf8)
    var logoutSucceeds = true

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ spec: CLIProcessSpec) async throws -> CLIProcessResult {
        var staged: [String] = []
        if spec.arguments.first == "auth-broker", spec.arguments.dropFirst().first == "import" {
            let dir = spec.arguments[2]
            staged = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            #expect(spec.arguments.contains("--provider=openai-codex"))
        }
        lock.withLock { recorded.append(Call(arguments: spec.arguments, stagedFiles: staged)) }
        if spec.arguments.dropFirst().first == "logout" {
            return CLIProcessResult(exitStatus: logoutSucceeds ? 0 : 1, wasSignaled: false, stdout: Data(), stderr: Data())
        }
        return CLIProcessResult(exitStatus: 0, wasSignaled: false, stdout: importOutput, stderr: Data())
    }
}

private struct Sandbox {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-omp-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(
            atPath: bin.appendingPathComponent("omp").path, contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".omp/agent"), withIntermediateDirectories: true)
    }

    func destroy() { try? FileManager.default.removeItem(at: home) }

    var environment: [String: String] { ["PATH": home.appendingPathComponent("bin").path, "HOME": home.path] }

    /// Writes OMP's `auth_credentials` table with the columns the real store uses.
    func writePool(_ rows: [(provider: String, email: String, accountId: String, disabled: String?)]) {
        var db: OpaquePointer?
        let path = home.appendingPathComponent(".omp/agent/agent.db").path
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(
            db,
            """
            CREATE TABLE IF NOT EXISTS auth_credentials (
                id INTEGER PRIMARY KEY AUTOINCREMENT, provider TEXT NOT NULL, credential_type TEXT NOT NULL,
                data TEXT NOT NULL, disabled_cause TEXT DEFAULT NULL, identity_key TEXT DEFAULT NULL,
                created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0);
            """, nil, nil, nil)
        for row in rows {
            let data = "{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\",\"expires\":1,\"email\":\"\(row.email)\",\"accountId\":\"\(row.accountId)\"}"
            let disabled = row.disabled.map { "'\($0)'" } ?? "NULL"
            let sql = "INSERT INTO auth_credentials (provider, credential_type, data, disabled_cause) VALUES ('\(row.provider)', 'oauth', '\(data)', \(disabled));"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    func writeConfig(_ yaml: String) throws {
        try Data(yaml.utf8).write(to: home.appendingPathComponent(".omp/agent/config.yml"))
    }

    func authFile(_ name: String, _ data: Data) throws -> URL {
        let url = home.appendingPathComponent("accounts/\(name)/auth.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func sync(_ runner: FakeRunner) -> OMPAccountSync {
        OMPAccountSync(home: home, runner: runner, environment: environment)
    }
}

@Suite struct OMPCredentialExportTests {
    @Test func codexAuthBecomesImportableDocument() throws {
        let data = codexAuth(email: "alice@example.com", accountId: "acct-alice")
        let document = try #require(OMPCredentialExport.importDocument(fromCodexAuth: data))
        let object = try #require(JSONSerialization.jsonObject(with: document) as? [String: Any])
        #expect(object["type"] as? String == "codex")
        #expect(object["refresh_token"] as? String == "refresh-acct-alice")
        #expect(object["email"] as? String == "alice@example.com")
        #expect(object["account_id"] as? String == "acct-alice")
        // OMP parses `expired`; it must be the access token's exp claim.
        let expired = try #require(ISO8601DateFormatter().date(from: object["expired"] as! String))
        #expect(abs(expired.timeIntervalSince1970 - expiry) < 1)
    }

    @Test func apiKeyLoginCannotJoinPool() {
        #expect(OMPCredentialExport.importDocument(fromCodexAuth: codexAuth(email: "", accountId: "", apiKeyOnly: true)) == nil)
    }

    @Test func importOutcomeParsing() {
        let banner = "Syncing session files...\n"
        #expect(
            OMPCredentialExport.importOutcome(stdout: Data((banner + "{\"imported\":[{\"provider\":\"openai-codex\"}],\"skipped\":[]}\n").utf8))
                == .imported)
        #expect(
            OMPCredentialExport.importOutcome(stdout: Data("{\"imported\":[],\"skipped\":[{\"file\":\"x\",\"reason\":\"missing access_token or refresh_token\"}]}\n".utf8))
                == .skipped("missing access_token or refresh_token"))
        #expect(OMPCredentialExport.importOutcome(stdout: Data("{\"error\":\"boom\",\"file\":\"x\"}\n".utf8)) == .failed("boom"))
        #expect(OMPCredentialExport.importOutcome(stdout: Data(banner.utf8)) == .unreadable)
    }

    @Test func brokerDetectionInConfig() {
        #expect(OMPCredentialExport.brokerConfigured(inConfigYAML: "auth:\n  broker:\n    url: https://broker.example\n"))
        #expect(OMPCredentialExport.brokerConfigured(inConfigYAML: "\"auth.broker.url\": https://broker.example\n"))
        #expect(!OMPCredentialExport.brokerConfigured(inConfigYAML: "auth:\n  broker:\n    url:\n"))
        #expect(!OMPCredentialExport.brokerConfigured(inConfigYAML: "# auth:\n#  broker:\n#    url: x\nmemory:\n  backend: off\n"))
        // `broker.url` under another section is not the auth broker.
        #expect(!OMPCredentialExport.brokerConfigured(inConfigYAML: "proxy:\n  broker:\n    url: https://x\nauth:\n  other: 1\n"))
    }
}

@Suite struct OMPAccountSyncTests {
    @Test func statusReadsActivePoolIdentitiesOnly() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        box.writePool([
            ("openai-codex", "alice@example.com", "acct-alice", nil),
            ("openai-codex", "gone@example.com", "acct-gone", "logged out by user"),
            ("anthropic", "claude@example.com", "acct-claude", nil),
        ])
        let status = await box.sync(FakeRunner()).status()
        #expect(status.isManageable)
        #expect(status.entries.map(\.accountId) == ["acct-alice"])
        #expect(status.contains(CodexIdentity(accountId: "acct-alice", email: "alice@example.com")))
        #expect(!status.contains(CodexIdentity(accountId: "acct-gone", email: "gone@example.com")))
    }

    @Test func missingStoreIsAnEmptyPool() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        let status = await box.sync(FakeRunner()).status()
        #expect(status.isManageable)
        #expect(status.entries.isEmpty)
    }

    @Test func brokerConfigurationBlocksManagement() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        try box.writeConfig("auth:\n  broker:\n    url: https://broker.example\n")
        let status = await box.sync(FakeRunner()).status()
        #expect(status.error == .brokerConfigured)
        #expect(!status.isManageable)
    }

    @Test func connectStagesCredentialAndCleansUp() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        let runner = FakeRunner()
        let file = try box.authFile("work", codexAuth(email: "alice@example.com", accountId: "acct-alice"))
        try await box.sync(runner).connect(name: "work", authFile: file)
        let call = try #require(runner.calls.first)
        #expect(call.arguments.prefix(2) == ["auth-broker", "import"])
        #expect(call.stagedFiles == ["codex-work.json"])
        // The staged copy of the credential must not outlive the import.
        #expect(!FileManager.default.fileExists(atPath: call.arguments[2]))
    }

    @Test func connectSurfacesSkipReason() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        let runner = FakeRunner()
        runner.importOutput = Data("{\"imported\":[],\"skipped\":[{\"file\":\"x\",\"reason\":\"cannot parse expired\"}]}\n".utf8)
        let file = try box.authFile("work", codexAuth(email: "alice@example.com", accountId: "acct-alice"))
        await #expect(throws: OMPSyncError.importFailed("cannot parse expired")) {
            try await box.sync(runner).connect(name: "work", authFile: file)
        }
    }

    @Test func disconnectClearsProviderAndReimportsTheRest() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        box.writePool([
            ("openai-codex", "alice@example.com", "acct-alice", nil),
            ("openai-codex", "bob@example.com", "acct-bob", nil),
        ])
        let runner = FakeRunner()
        let bobFile = try box.authFile("bob", codexAuth(email: "bob@example.com", accountId: "acct-bob"))
        try await box.sync(runner).disconnect(
            identity: CodexIdentity(accountId: "acct-alice", email: "alice@example.com"),
            keeping: [("bob", bobFile, CodexIdentity(accountId: "acct-bob", email: "bob@example.com"))])
        #expect(runner.calls.map { Array($0.arguments.prefix(2)) } == [["auth-broker", "logout"], ["auth-broker", "import"]])
        #expect(runner.calls[0].arguments == ["auth-broker", "logout", "openai-codex"])
        #expect(runner.calls[1].stagedFiles == ["codex-bob.json"])
    }

    @Test func disconnectRefusesWhenPoolHasUnmanagedAccounts() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        box.writePool([
            ("openai-codex", "alice@example.com", "acct-alice", nil),
            ("openai-codex", "cli-only@example.com", "acct-cli", nil),
        ])
        let runner = FakeRunner()
        await #expect(throws: OMPSyncError.unmanagedCredentials(["cli-only@example.com"])) {
            try await box.sync(runner).disconnect(
                identity: CodexIdentity(accountId: "acct-alice", email: "alice@example.com"), keeping: [])
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func disconnectIsNoOpWhenNotPooled() async throws {
        let box = try Sandbox()
        defer { box.destroy() }
        box.writePool([("openai-codex", "bob@example.com", "acct-bob", nil)])
        let runner = FakeRunner()
        try await box.sync(runner).disconnect(
            identity: CodexIdentity(accountId: "acct-alice", email: "alice@example.com"), keeping: [])
        #expect(runner.calls.isEmpty)
    }
}
