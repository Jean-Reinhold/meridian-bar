import Foundation
import Testing

@testable import MeridianBar

// Every test runs against a throwaway HOME and a scripted process runner:
// no real CLI runs, no real credential is read or written. Fixtures use
// synthetic JWTs with example.com identities.

// MARK: - Fixtures

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func fakeJWT(email: String, accountId: String, plan: String = "plus") -> String {
    let claims: [String: Any] = [
        "email": email,
        "https://api.openai.com/auth": ["chatgpt_account_id": accountId, "chatgpt_plan_type": plan],
    ]
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    return "\(base64URL(Data("{\"alg\":\"none\"}".utf8))).\(base64URL(payload)).sig"
}

/// A Codex auth.json in the shape recorded in okf/01. `marker` varies the
/// access token so two files for one identity can differ byte-wise.
private func codexAuth(email: String, accountId: String, marker: String = "v1") -> Data {
    let object: [String: Any] = [
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": NSNull(),
        "tokens": [
            "id_token": fakeJWT(email: email, accountId: accountId),
            "access_token": "access-\(marker)",
            "refresh_token": "refresh-\(marker)",
            "account_id": accountId,
        ],
        "last_refresh": "2026-09-07T00:00:00Z",
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private let accountA = (email: "alice@example.com", id: "acct-alice")
private let accountB = (email: "bob@example.com", id: "acct-bob")

private struct Sandbox {
    let home: URL
    let bin: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-accounts-\(UUID().uuidString)", isDirectory: true)
        bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["claude", "codex", "meridian"] {
            let path = bin.appendingPathComponent(tool).path
            _ = FileManager.default.createFile(
                atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        }
    }

    func destroy() { try? FileManager.default.removeItem(at: home) }

    var environment: [String: String] {
        [
            "PATH": bin.path, "HOME": home.path,
            "OPENAI_API_KEY": "sk-should-be-stripped", "ANTHROPIC_API_KEY": "ant-should-be-stripped",
            "CLAUDE_CONFIG_DIR": "/nonexistent/should-be-replaced",
        ]
    }

    var codexAuthFile: URL { home.appendingPathComponent(".codex/auth.json") }
    var accountsDir: URL { home.appendingPathComponent("Library/Application Support/MeridianBar/CodexAccounts") }
    var meridianDir: URL { home.appendingPathComponent(".config/meridian") }

    func savedAuthFile(_ name: String) -> URL { accountsDir.appendingPathComponent("\(name)/auth.json") }

    func writeCurrentCodexAuth(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: codexAuthFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: codexAuthFile)
    }

    func writeCodexConfig(_ toml: String) throws {
        let dir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(toml.utf8).write(to: dir.appendingPathComponent("config.toml"))
    }

    func writeSavedCodexAccount(_ name: String, _ data: Data) throws {
        let dir = accountsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: dir.appendingPathComponent("auth.json"))
    }

    func writeMeridian(profiles: String, settings: String? = nil) throws {
        try FileManager.default.createDirectory(at: meridianDir, withIntermediateDirectories: true)
        try Data(profiles.utf8).write(to: meridianDir.appendingPathComponent("profiles.json"))
        if let settings {
            try Data(settings.utf8).write(to: meridianDir.appendingPathComponent("settings.json"))
        }
    }

    func meridianProfileIDs() -> [String] {
        guard let data = try? Data(contentsOf: meridianDir.appendingPathComponent("profiles.json")),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { $0["id"] as? String }
    }

    func entries(in url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    func mode(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    func manager(_ runner: FakeRunner) -> AccountManager {
        AccountManager(home: home, runner: runner, environment: environment)
    }
}

// MARK: - Scripted runner

private final class FakeRunner: CLIProcessRunning, @unchecked Sendable {
    typealias Handler = @Sendable (CLIProcessSpec) async throws -> CLIProcessResult

    private let lock = NSLock()
    private var recorded: [CLIProcessSpec] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    func run(_ spec: CLIProcessSpec) async throws -> CLIProcessResult {
        lock.withLock { recorded.append(spec) }
        return try await handler(spec)
    }

    var specs: [CLIProcessSpec] { lock.withLock { recorded } }

    func specs(for tool: String) -> [CLIProcessSpec] { specs.filter { $0.executable.lastPathComponent == tool } }
}

extension CLIProcessResult {
    fileprivate static func exit(_ status: Int32, stdout: String = "") -> CLIProcessResult {
        CLIProcessResult(exitStatus: status, wasSignaled: false, stdout: Data(stdout.utf8), stderr: Data())
    }
}

/// Answers `claude auth status` as logged out and everything else as success.
private let quietRunner = FakeRunner { spec in
    if spec.arguments.first == "auth" { return .exit(1, stdout: #"{"loggedIn": false}"#) }
    return .exit(0)
}

/// Simulates `codex login` writing the given auth into the isolated CODEX_HOME.
private func codexLoginRunner(writing auth: Data, status: Int32 = 0) -> FakeRunner {
    FakeRunner { spec in
        if spec.arguments.first == "login", let home = spec.environment["CODEX_HOME"] {
            let dir = URL(fileURLWithPath: home)
            try auth.write(to: dir.appendingPathComponent("auth.json"))
            return .exit(status)
        }
        if spec.arguments.first == "auth" { return .exit(1, stdout: #"{"loggedIn": false}"#) }
        return .exit(0)
    }
}

private func codex(_ accounts: [ManagedAccount]) -> [ManagedAccount] { accounts.filter { $0.provider == .codex } }

// MARK: - Tests

@Suite struct AccountNames {
    @Test func rejectsUnsafeNamesBeforeTouchingAnything() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let runner = FakeRunner { _ in .exit(0) }
        let manager = sandbox.manager(runner)

        for name in ["", "../escape", "a/b", "with space", ".hidden", "name;rm", "ünïcode", String(repeating: "a", count: 65)] {
            for provider in AccountProvider.allCases {
                await #expect(throws: AccountManagerError.invalidName) {
                    try await manager.add(provider: provider, name: name)
                }
            }
        }
        #expect(runner.specs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.accountsDir.path))
    }

    @Test func craftedAccountIDsAreStale() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let manager = sandbox.manager(quietRunner)
        let crafted = ManagedAccount(id: "codex:saved:../../escape", name: "x", provider: .codex)
        await #expect(throws: AccountManagerError.accountNotFound) { try await manager.remove(crafted) }
        await #expect(throws: AccountManagerError.accountNotFound) {
            try await manager.activate(crafted, baseURL: URL(string: "http://127.0.0.1:1")!)
        }
    }

    @Test func importNamesDeriveFromEmailAndStayUnique() {
        let identity = CodexIdentity(accountId: "x", email: "Jane.Doe+work@example.com")
        #expect(AccountManager.uniqueImportName(for: identity, taken: []) == "jane-doe-work")
        #expect(AccountManager.uniqueImportName(for: identity, taken: ["jane-doe-work"]) == "jane-doe-work-2")
        #expect(AccountManager.uniqueImportName(for: CodexIdentity(), taken: []) == "imported")
    }
}

@Suite struct CodexIdentityParsing {
    @Test func readsClaimsWithoutTokens() {
        let identity = CodexAuthFile.identity(in: codexAuth(email: accountA.email, accountId: accountA.id))
        #expect(identity == CodexIdentity(accountId: accountA.id, email: accountA.email, planType: "plus"))
        #expect(identity?.key == "account:\(accountA.id)")
    }

    @Test func apiKeyOnlyAndGarbage() {
        let apiKey = Data(#"{"OPENAI_API_KEY": "sk-test", "tokens": null}"#.utf8)
        #expect(CodexAuthFile.identity(in: apiKey) == CodexIdentity(planType: "api-key"))
        #expect(CodexAuthFile.identity(in: Data("not json".utf8)) == nil)
        #expect(CodexAuthFile.identity(in: Data(#"{"tokens": {"id_token": "broken"}}"#.utf8)) == nil)
    }
}

@Suite struct CodexListing {
    @Test func savedAccountMatchingCurrentIsActiveAndHidesCurrentEntry() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeCurrentCodexAuth(codexAuth(email: accountA.email, accountId: accountA.id, marker: "fresh"))
        try sandbox.writeSavedCodexAccount("work", codexAuth(email: accountA.email, accountId: accountA.id, marker: "old"))
        try sandbox.writeSavedCodexAccount("personal", codexAuth(email: accountB.email, accountId: accountB.id))

        let accounts = codex(try await sandbox.manager(quietRunner).accounts())
        #expect(accounts.map(\.id) == ["codex:saved:personal", "codex:saved:work"])
        let work = accounts.first { $0.name == "work" }
        #expect(work?.isActive == true)
        #expect(work?.isLoggedIn == true)
        #expect(work?.email == accountA.email)
        #expect(accounts.first { $0.name == "personal" }?.isActive == false)
    }

    @Test func unsavedCurrentLoginIsListedAsCurrent() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeCurrentCodexAuth(codexAuth(email: accountA.email, accountId: accountA.id))
        try sandbox.writeSavedCodexAccount("personal", codexAuth(email: accountB.email, accountId: accountB.id))

        let accounts = codex(try await sandbox.manager(quietRunner).accounts())
        let current = accounts.first { $0.id == "codex:current" }
        #expect(current?.isActive == true)
        #expect(current?.canRemove == false)
        #expect(current?.email == accountA.email)
        #expect(accounts.first { $0.name == "personal" }?.isActive == false)
    }

    @Test func loggedOutCliStillOffersCurrentEntry() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let accounts = codex(try await sandbox.manager(quietRunner).accounts())
        #expect(accounts.map(\.id) == ["codex:current"])
        #expect(accounts[0].isLoggedIn == false)
        #expect(accounts[0].isActive == false)
        #expect(accounts[0].supportsLogin)
    }
}

@Suite struct CodexLogin {
    @Test func failedLoginPersistsNothingAndRunsIsolated() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let current = codexAuth(email: accountA.email, accountId: accountA.id)
        try sandbox.writeCurrentCodexAuth(current)
        let runner = codexLoginRunner(writing: codexAuth(email: accountB.email, accountId: accountB.id), status: 1)
        let manager = sandbox.manager(runner)

        await #expect(throws: AccountManagerError.loginFailed(.codex)) {
            try await manager.add(provider: .codex, name: "work")
        }

        let login = try #require(runner.specs(for: "codex").first { $0.arguments.first == "login" })
        #expect(login.arguments == ["login", "-c", "cli_auth_credentials_store=\"file\""])
        #expect(login.keepsStdinOpen)
        let isolatedHome = try #require(login.environment["CODEX_HOME"])
        #expect(isolatedHome.hasPrefix(sandbox.accountsDir.path + "/.pending-"))
        #expect(login.environment["OPENAI_API_KEY"] == nil)
        #expect(login.environment["PATH"]?.contains(sandbox.bin.path) == true)

        #expect(try Data(contentsOf: sandbox.codexAuthFile) == current)
        #expect(!sandbox.entries(in: sandbox.accountsDir).contains { $0.hasPrefix(".pending-") })
        #expect(!FileManager.default.fileExists(atPath: sandbox.savedAuthFile("work").path))
    }

    @Test func successfulAddSavesAccountAndPreservesCurrentLogin() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let current = codexAuth(email: accountA.email, accountId: accountA.id)
        try sandbox.writeCurrentCodexAuth(current)
        let manager = sandbox.manager(codexLoginRunner(writing: codexAuth(email: accountB.email, accountId: accountB.id)))

        try await manager.add(provider: .codex, name: "work")

        #expect(try Data(contentsOf: sandbox.codexAuthFile) == current)
        #expect(sandbox.mode(of: sandbox.accountsDir.appendingPathComponent("work")) == 0o700)
        #expect(sandbox.mode(of: sandbox.savedAuthFile("work")) == 0o600)
        #expect(sandbox.mode(of: sandbox.accountsDir.appendingPathComponent("work/metadata.json")) == 0o600)
        #expect(!sandbox.entries(in: sandbox.accountsDir).contains { $0.hasPrefix(".pending-") })

        let accounts = codex(try await manager.accounts())
        #expect(accounts.map(\.id) == ["codex:saved:alice", "codex:saved:work"])
        #expect(accounts.first { $0.name == "alice" }?.isActive == true)
        #expect(accounts.first { $0.name == "work" }?.isActive == false)
        #expect(accounts.first { $0.name == "work" }?.email == accountB.email)
    }

    @Test func addRefusesIdentityThatIsAlreadySaved() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeSavedCodexAccount("personal", codexAuth(email: accountB.email, accountId: accountB.id))
        let manager = sandbox.manager(codexLoginRunner(writing: codexAuth(email: accountB.email, accountId: accountB.id)))

        await #expect(throws: AccountManagerError.alreadySaved("personal")) {
            try await manager.add(provider: .codex, name: "duplicate")
        }
        #expect(sandbox.entries(in: sandbox.accountsDir) == ["personal"])
    }

    @Test func savedReloginRejectsDifferentIdentity() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let original = codexAuth(email: accountA.email, accountId: accountA.id)
        try sandbox.writeSavedCodexAccount("work", original)
        let manager = sandbox.manager(codexLoginRunner(writing: codexAuth(email: accountB.email, accountId: accountB.id)))
        let work = ManagedAccount(id: "codex:saved:work", name: "work", provider: .codex)

        await #expect(throws: AccountManagerError.identityMismatch("work")) { try await manager.login(work) }
        #expect(try Data(contentsOf: sandbox.savedAuthFile("work")) == original)
        #expect(sandbox.entries(in: sandbox.accountsDir) == ["work"])
    }

    @Test func cancelKillsPendingLoginAndCleansStaging() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let runner = FakeRunner { spec in
            guard spec.arguments.first == "login" else { return .exit(0) }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw CLIProcessFailure.cancelled
            }
            return .exit(0)
        }
        let manager = sandbox.manager(runner)

        let pending = Task { try await manager.add(provider: .codex, name: "work") }
        for _ in 0..<200 where runner.specs(for: "codex").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!runner.specs(for: "codex").isEmpty)
        await #expect(throws: AccountManagerError.loginInProgress) {
            try await manager.add(provider: .codex, name: "second")
        }

        await manager.cancelLogin()
        await #expect(throws: AccountManagerError.loginCancelled) { try await pending.value }
        #expect(!sandbox.entries(in: sandbox.accountsDir).contains { $0.hasPrefix(".pending-") })
        #expect(!FileManager.default.fileExists(atPath: sandbox.savedAuthFile("work").path))
    }
}

@Suite struct CodexActivation {
    private let anyURL = URL(string: "http://127.0.0.1:3456")!

    @Test func switchPreservesRefreshedCredentialsThenReplaces() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let fresh = codexAuth(email: accountA.email, accountId: accountA.id, marker: "fresh")
        let personal = codexAuth(email: accountB.email, accountId: accountB.id)
        try sandbox.writeCurrentCodexAuth(fresh)
        try sandbox.writeSavedCodexAccount("work", codexAuth(email: accountA.email, accountId: accountA.id, marker: "stale"))
        try sandbox.writeSavedCodexAccount("personal", personal)
        let manager = sandbox.manager(quietRunner)

        try await manager.activate(ManagedAccount(id: "codex:saved:personal", name: "personal", provider: .codex), baseURL: anyURL)

        #expect(try Data(contentsOf: sandbox.codexAuthFile) == personal)
        #expect(sandbox.mode(of: sandbox.codexAuthFile) == 0o600)
        #expect(try Data(contentsOf: sandbox.savedAuthFile("work")) == fresh)
        let accounts = codex(try await manager.accounts())
        #expect(accounts.first { $0.name == "personal" }?.isActive == true)
        #expect(accounts.first { $0.name == "work" }?.isActive == false)
        #expect(!accounts.contains { $0.id == "codex:current" })
    }

    @Test func switchImportsUnsavedCurrentLogin() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let current = codexAuth(email: accountA.email, accountId: accountA.id)
        try sandbox.writeCurrentCodexAuth(current)
        try sandbox.writeSavedCodexAccount("personal", codexAuth(email: accountB.email, accountId: accountB.id))
        let manager = sandbox.manager(quietRunner)

        try await manager.activate(ManagedAccount(id: "codex:saved:personal", name: "personal", provider: .codex), baseURL: anyURL)

        #expect(try Data(contentsOf: sandbox.savedAuthFile("alice")) == current)
        #expect(sandbox.mode(of: sandbox.savedAuthFile("alice")) == 0o600)
    }

    @Test func activatingAlreadyActiveAccountOnlySyncsSavedCopy() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let fresh = codexAuth(email: accountA.email, accountId: accountA.id, marker: "fresh")
        try sandbox.writeCurrentCodexAuth(fresh)
        try sandbox.writeSavedCodexAccount("work", codexAuth(email: accountA.email, accountId: accountA.id, marker: "stale"))
        let manager = sandbox.manager(quietRunner)

        try await manager.activate(ManagedAccount(id: "codex:saved:work", name: "work", provider: .codex), baseURL: anyURL)

        #expect(try Data(contentsOf: sandbox.codexAuthFile) == fresh)
        #expect(try Data(contentsOf: sandbox.savedAuthFile("work")) == fresh)
    }

    @Test func refusesNonFileCredentialStore() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let current = codexAuth(email: accountA.email, accountId: accountA.id)
        try sandbox.writeCurrentCodexAuth(current)
        try sandbox.writeCodexConfig("model = \"gpt\"\ncli_auth_credentials_store = \"keyring\" # secure\n[features]\nx = true\n")
        try sandbox.writeSavedCodexAccount("personal", codexAuth(email: accountB.email, accountId: accountB.id))
        let manager = sandbox.manager(quietRunner)

        await #expect(throws: AccountManagerError.unsupportedCredentialStore("keyring")) {
            try await manager.activate(ManagedAccount(id: "codex:saved:personal", name: "personal", provider: .codex), baseURL: anyURL)
        }
        #expect(try Data(contentsOf: sandbox.codexAuthFile) == current)
    }

    @Test func fileStoreInsideSectionDoesNotCount() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeCurrentCodexAuth(codexAuth(email: accountA.email, accountId: accountA.id))
        try sandbox.writeCodexConfig("[profiles.x]\ncli_auth_credentials_store = \"keyring\"\n")
        let personal = codexAuth(email: accountB.email, accountId: accountB.id)
        try sandbox.writeSavedCodexAccount("personal", personal)
        let manager = sandbox.manager(quietRunner)

        try await manager.activate(ManagedAccount(id: "codex:saved:personal", name: "personal", provider: .codex), baseURL: anyURL)
        #expect(try Data(contentsOf: sandbox.codexAuthFile) == personal)
    }

    @Test func staleAndLoggedOutSelections() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeCurrentCodexAuth(codexAuth(email: accountA.email, accountId: accountA.id))
        try FileManager.default.createDirectory(
            at: sandbox.accountsDir.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let manager = sandbox.manager(quietRunner)

        await #expect(throws: AccountManagerError.accountNotFound) {
            try await manager.activate(ManagedAccount(id: "codex:saved:ghost", name: "ghost", provider: .codex), baseURL: anyURL)
        }
        await #expect(throws: AccountManagerError.notLoggedIn("empty")) {
            try await manager.activate(ManagedAccount(id: "codex:saved:empty", name: "empty", provider: .codex), baseURL: anyURL)
        }
    }

    @Test func removeAndLogoutTouchOnlyTheSelectedAccount() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let current = codexAuth(email: accountA.email, accountId: accountA.id)
        try sandbox.writeCurrentCodexAuth(current)
        try sandbox.writeSavedCodexAccount("work", current)
        try sandbox.writeSavedCodexAccount("personal", codexAuth(email: accountB.email, accountId: accountB.id))
        let runner = FakeRunner { spec in
            if spec.arguments.first == "auth" { return .exit(1, stdout: #"{"loggedIn": false}"#) }
            if spec.arguments.first == "logout", let home = spec.environment["CODEX_HOME"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
            }
            return .exit(0)
        }
        let manager = sandbox.manager(runner)

        try await manager.logout(ManagedAccount(id: "codex:saved:personal", name: "personal", provider: .codex))
        let logout = try #require(runner.specs(for: "codex").first { $0.arguments.first == "logout" })
        #expect(logout.environment["CODEX_HOME"] == sandbox.accountsDir.appendingPathComponent("personal").path)
        #expect(logout.arguments.contains("cli_auth_credentials_store=\"file\""))
        #expect(!FileManager.default.fileExists(atPath: sandbox.savedAuthFile("personal").path))
        #expect(FileManager.default.fileExists(atPath: sandbox.accountsDir.appendingPathComponent("personal").path))

        try await manager.remove(ManagedAccount(id: "codex:saved:work", name: "work", provider: .codex))
        #expect(!FileManager.default.fileExists(atPath: sandbox.accountsDir.appendingPathComponent("work").path))
        #expect(try Data(contentsOf: sandbox.codexAuthFile) == current)

        await #expect(throws: AccountManagerError.cannotRemove("Codex CLI (current)")) {
            try await manager.remove(ManagedAccount(id: "codex:current", name: "Codex CLI (current)", provider: .codex))
        }
        #expect(try Data(contentsOf: sandbox.codexAuthFile) == current)
    }

    @Test func authFileAccessorReturnsPathsOnly() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeSavedCodexAccount("work", codexAuth(email: accountA.email, accountId: accountA.id))
        let manager = sandbox.manager(quietRunner)

        let saved = try await manager.codexAuthFile(ManagedAccount(id: "codex:saved:work", name: "work", provider: .codex))
        #expect(saved.path == sandbox.savedAuthFile("work").path)
        let current = try await manager.codexAuthFile(ManagedAccount(id: "codex:current", name: "c", provider: .codex))
        #expect(current.path == sandbox.codexAuthFile.path)
        await #expect(throws: AccountManagerError.accountNotFound) {
            _ = try await manager.codexAuthFile(ManagedAccount(id: "codex:saved:ghost", name: "g", provider: .codex))
        }
        await #expect(throws: AccountManagerError.accountNotFound) {
            _ = try await manager.codexAuthFile(ManagedAccount(id: "claude:default", name: "d", provider: .claude))
        }
    }
}

private let meridianProfiles = """
    [
      {"id": "p1", "claudeConfigDir": "HOME/.config/meridian/profiles/p1"},
      {"id": "p2", "claudeConfigDir": "HOME/.config/meridian/profiles/p2"},
      {"id": "ci", "type": "oauth-token", "oauthToken": "sk-ant-oat01-fixture"}
    ]
    """

/// Reports each config dir as logged in with `<dirname>@example.com`.
private func claudeStatusRunner(extra: @escaping FakeRunner.Handler = { _ in .exit(0) }) -> FakeRunner {
    FakeRunner { spec in
        if spec.arguments.first == "auth", spec.arguments.dropFirst().first == "status" {
            let dir = URL(fileURLWithPath: spec.environment["CLAUDE_CONFIG_DIR"] ?? "/none").lastPathComponent
            return .exit(0, stdout: #"{"loggedIn": true, "email": "\#(dir)@example.com", "subscriptionType": "max"}"#)
        }
        return try await extra(spec)
    }
}

@Suite struct ClaudeAccounts {
    @Test func listingFollowsPriorityRoutingAndIncludesDefault() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(
            profiles: meridianProfiles.replacingOccurrences(of: "HOME", with: sandbox.home.path),
            settings: #"{"routing": "priority", "profileOrder": ["p2", "p1"], "activeProfile": "p1"}"#)
        let runner = claudeStatusRunner()
        let accounts = try await sandbox.manager(runner).accounts().filter { $0.provider == .claude }

        #expect(accounts.map(\.id) == ["claude:default", "claude:profile:p2", "claude:profile:p1", "claude:profile:ci"])
        let byName = Dictionary(uniqueKeysWithValues: accounts.map { ($0.name, $0) })
        #expect(byName["Claude CLI (default)"]?.canRemove == false)
        #expect(byName["Claude CLI (default)"]?.isActive == false)
        #expect(byName["Claude CLI (default)"]?.email == ".claude@example.com")
        #expect(byName["p2"]?.isActive == true)
        #expect(byName["p1"]?.isActive == false)
        #expect(byName["p1"]?.email == "p1@example.com")
        #expect(byName["ci"]?.supportsLogin == false)
        #expect(byName["ci"]?.isLoggedIn == true)

        let statuses = runner.specs(for: "claude")
        #expect(statuses.count == 3)
        #expect(statuses.allSatisfy { $0.arguments == ["auth", "status", "--json"] })
        #expect(statuses.allSatisfy { $0.environment["ANTHROPIC_API_KEY"] == nil })
        #expect(statuses.contains { $0.environment["CLAUDE_CONFIG_DIR"] == sandbox.home.appendingPathComponent(".claude").path })
        #expect(statuses.contains { $0.environment["CLAUDE_CONFIG_DIR"] == sandbox.meridianDir.appendingPathComponent("profiles/p1").path })
    }

    @Test func activeProfileRoutingUsesActiveProfile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(
            profiles: meridianProfiles.replacingOccurrences(of: "HOME", with: sandbox.home.path),
            settings: #"{"routing": "sticky", "profileOrder": ["p2", "p1"], "activeProfile": "p1"}"#)
        let accounts = try await sandbox.manager(claudeStatusRunner()).accounts()
        #expect(accounts.first { $0.name == "p1" }?.isActive == true)
        #expect(accounts.first { $0.name == "p2" }?.isActive == false)
    }

    @Test func importedDefaultIsNotListedTwice() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(
            profiles: #"[{"id": "main", "claudeConfigDir": "\#(sandbox.home.path)/.claude"}]"#)
        let accounts = try await sandbox.manager(claudeStatusRunner()).accounts().filter { $0.provider == .claude }
        #expect(accounts.map(\.id) == ["claude:profile:main"])
        #expect(accounts[0].canRemove)
    }

    @Test func addDeclinesImportPromptAndUsesMeridian() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: "[]")
        let runner = claudeStatusRunner { spec in
            if spec.arguments.starts(with: ["profile", "add"]) {
                try sandbox.writeMeridian(profiles: #"[{"id": "work", "claudeConfigDir": "\#(sandbox.home.path)/.config/meridian/profiles/work"}]"#)
            }
            return .exit(0)
        }
        let manager = sandbox.manager(runner)

        try await manager.add(provider: .claude, name: "work")

        let add = try #require(runner.specs(for: "meridian").first)
        #expect(add.arguments == ["profile", "add", "work"])
        #expect(add.keepsStdinOpen)
        #expect(add.promptReplies == [CLIPromptReply(prompt: "Import as profile", reply: "n\n")])
        #expect(add.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(add.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(add.environment["MERIDIAN_CLAUDE_PATH"] == sandbox.bin.appendingPathComponent("claude").path)
        #expect(add.timeout > .seconds(60))

        await #expect(throws: AccountManagerError.duplicateName("work")) {
            try await manager.add(provider: .claude, name: "work")
        }
    }

    @Test func addFailsWhenMeridianDidNotRegisterProfile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: "[]")
        let manager = sandbox.manager(claudeStatusRunner())
        await #expect(throws: AccountManagerError.loginFailed(.claude)) {
            try await manager.add(provider: .claude, name: "work")
        }
    }

    @Test func loginAndLogoutUseExactConfigDir() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: meridianProfiles.replacingOccurrences(of: "HOME", with: sandbox.home.path))
        let runner = claudeStatusRunner()
        let manager = sandbox.manager(runner)
        let p1 = ManagedAccount(id: "claude:profile:p1", name: "p1", provider: .claude)
        let fallback = ManagedAccount(id: "claude:default", name: "Claude CLI (default)", provider: .claude)
        let p1Dir = sandbox.meridianDir.appendingPathComponent("profiles/p1").path
        let defaultDir = sandbox.home.appendingPathComponent(".claude").path

        try await manager.login(p1)
        try await manager.logout(fallback)
        let login = try #require(runner.specs(for: "claude").first { $0.arguments == ["auth", "login"] })
        #expect(login.environment["CLAUDE_CONFIG_DIR"] == p1Dir)
        #expect(login.keepsStdinOpen)
        let logout = try #require(runner.specs(for: "claude").first { $0.arguments == ["auth", "logout"] })
        #expect(logout.environment["CLAUDE_CONFIG_DIR"] == defaultDir)

        await #expect(throws: AccountManagerError.loginUnsupported("ci")) {
            try await manager.login(ManagedAccount(id: "claude:profile:ci", name: "ci", provider: .claude))
        }
        await #expect(throws: AccountManagerError.cannotRemove("Claude CLI (default)")) {
            try await manager.remove(fallback)
        }
        await #expect(throws: AccountManagerError.accountNotFound) {
            try await manager.login(ManagedAccount(id: "claude:profile:ghost", name: "ghost", provider: .claude))
        }
    }

    @Test func removeUsesMeridianAndVerifiesRegistry() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: meridianProfiles.replacingOccurrences(of: "HOME", with: sandbox.home.path))
        let runner = claudeStatusRunner { spec in
            if spec.arguments.starts(with: ["profile", "remove"]) {
                try sandbox.writeMeridian(profiles: "[]")
            }
            return .exit(0)
        }
        let manager = sandbox.manager(runner)
        try await manager.remove(ManagedAccount(id: "claude:profile:p1", name: "p1", provider: .claude))
        #expect(runner.specs(for: "meridian").first?.arguments == ["profile", "remove", "p1"])
        #expect(sandbox.meridianProfileIDs().isEmpty)
    }
}

@Suite struct ProcessRunner {
    @Test func cancellationTerminatesChild() async throws {
        let spec = CLIProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
            keepsStdinOpen: true, timeout: .seconds(60))
        let started = ContinuousClock.now
        let task = Task { try await SystemProcessRunner().run(spec) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CLIProcessFailure.cancelled) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func timeoutTerminatesChild() async throws {
        var spec = CLIProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
        spec.timeout = .seconds(1)
        let started = ContinuousClock.now
        await #expect(throws: CLIProcessFailure.timedOut) { try await SystemProcessRunner().run(spec) }
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func outputKeepsOnlyTheTail() async throws {
        var spec = CLIProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "yes | head -c 200000; printf END"], environment: [:])
        spec.outputLimit = 4096
        let result = try await SystemProcessRunner().run(spec)
        #expect(result.succeeded)
        #expect(result.stdout.count <= 4096)
        #expect(String(decoding: result.stdout, as: UTF8.self).hasSuffix("END"))
    }

    @Test func promptReplyReachesStdin() async throws {
        var spec = CLIProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'Import? [Y/n] ' >&2; read answer; echo \"got:$answer\""], environment: [:])
        spec.promptReplies = [CLIPromptReply(prompt: "Import?", reply: "n\n")]
        spec.timeout = .seconds(5)
        let result = try await SystemProcessRunner().run(spec)
        #expect(result.succeeded)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("got:n"))
    }

    @Test func missingExecutableFailsToLaunch() async throws {
        let spec = CLIProcessSpec(
            executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], environment: [:])
        await #expect(throws: CLIProcessFailure.launchFailed("tool")) { try await SystemProcessRunner().run(spec) }
    }
}
