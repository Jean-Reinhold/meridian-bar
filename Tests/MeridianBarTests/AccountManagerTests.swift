import Foundation
import Testing

@testable import MeridianBar

// Every test runs against a throwaway HOME and a scripted process runner:
// no real CLI runs, no real credential is read or written. Fixtures use
// example.com identities.

// MARK: - Fixtures

private struct Sandbox {
    let home: URL
    let bin: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-accounts-\(UUID().uuidString)", isDirectory: true)
        bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["claude", "meridian"] {
            let path = bin.appendingPathComponent(tool).path
            _ = FileManager.default.createFile(
                atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
        }
    }

    func destroy() { try? FileManager.default.removeItem(at: home) }

    var environment: [String: String] {
        [
            "PATH": bin.path, "HOME": home.path,
            "ANTHROPIC_API_KEY": "ant-should-be-stripped",
            "CLAUDE_CONFIG_DIR": "/nonexistent/should-be-replaced",
        ]
    }

    var meridianDir: URL { home.appendingPathComponent(".config/meridian") }

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

// MARK: - Tests

@Suite struct AccountNames {
    @Test func rejectsUnsafeNamesBeforeTouchingAnything() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let runner = FakeRunner { _ in .exit(0) }
        let manager = sandbox.manager(runner)

        for name in ["", "../escape", "a/b", "with space", ".hidden", "name;rm", "ünïcode", String(repeating: "a", count: 65)] {
            await #expect(throws: AccountManagerError.invalidName) {
                try await manager.add(name: name)
            }
        }
        #expect(runner.specs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.meridianDir.path))
    }

    @Test func craftedAccountIDsAreStale() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        let manager = sandbox.manager(quietRunner)
        let crafted = ManagedAccount(id: "claude:profile:../../escape", name: "x")
        await #expect(throws: AccountManagerError.accountNotFound) { try await manager.remove(crafted) }
        await #expect(throws: AccountManagerError.accountNotFound) {
            try await manager.activate(crafted, baseURL: URL(string: "http://127.0.0.1:1")!)
        }
    }
}

@Suite struct PendingLogin {
    @Test func cancelKillsPendingLoginAndBlocksASecond() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: "[]")
        let runner = FakeRunner { spec in
            guard spec.arguments.starts(with: ["profile", "add"]) else { return .exit(0) }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw CLIProcessFailure.cancelled
            }
            return .exit(0)
        }
        let manager = sandbox.manager(runner)

        let pending = Task { try await manager.add(name: "work") }
        for _ in 0..<200 where runner.specs(for: "meridian").isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!runner.specs(for: "meridian").isEmpty)
        await #expect(throws: AccountManagerError.loginInProgress) {
            try await manager.add(name: "second")
        }

        await manager.cancelLogin()
        await #expect(throws: AccountManagerError.loginCancelled) { try await pending.value }
        #expect(sandbox.meridianProfileIDs().isEmpty)
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
        let accounts = try await sandbox.manager(runner).accounts()

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
        let accounts = try await sandbox.manager(claudeStatusRunner()).accounts()
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

        try await manager.add(name: "work")

        let add = try #require(runner.specs(for: "meridian").first)
        #expect(add.arguments == ["profile", "add", "work"])
        #expect(add.keepsStdinOpen)
        #expect(add.promptReplies == [CLIPromptReply(prompt: "Import as profile", reply: "n\n")])
        #expect(add.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(add.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(add.environment["MERIDIAN_CLAUDE_PATH"] == sandbox.bin.appendingPathComponent("claude").path)
        #expect(add.timeout > .seconds(60))

        await #expect(throws: AccountManagerError.duplicateName("work")) {
            try await manager.add(name: "work")
        }
    }

    @Test func addFailsWhenMeridianDidNotRegisterProfile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: "[]")
        let manager = sandbox.manager(claudeStatusRunner())
        await #expect(throws: AccountManagerError.loginFailed) {
            try await manager.add(name: "work")
        }
    }

    @Test func loginAndLogoutUseExactConfigDir() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.destroy() }
        try sandbox.writeMeridian(profiles: meridianProfiles.replacingOccurrences(of: "HOME", with: sandbox.home.path))
        let runner = claudeStatusRunner()
        let manager = sandbox.manager(runner)
        let p1 = ManagedAccount(id: "claude:profile:p1", name: "p1")
        let fallback = ManagedAccount(id: "claude:default", name: "Claude CLI (default)")
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
            try await manager.login(ManagedAccount(id: "claude:profile:ci", name: "ci"))
        }
        await #expect(throws: AccountManagerError.cannotRemove("Claude CLI (default)")) {
            try await manager.remove(fallback)
        }
        await #expect(throws: AccountManagerError.accountNotFound) {
            try await manager.login(ManagedAccount(id: "claude:profile:ghost", name: "ghost"))
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
        try await manager.remove(ManagedAccount(id: "claude:profile:p1", name: "p1"))
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
