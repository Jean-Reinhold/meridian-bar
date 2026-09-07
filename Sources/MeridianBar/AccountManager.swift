import Foundation

// Claude and Codex account management behind the menu bar.
//
// Claude accounts are Meridian profiles (`~/.config/meridian/profiles.json`,
// okf/01) plus the default Claude CLI login in `~/.claude`. Every mutation
// goes through the official CLIs: `meridian profile add|remove`,
// `claude auth login|logout|status`. Routing changes use the Meridian HTTP
// surface recorded in okf/01 (`profiles/list`, `settings/api/routing`,
// `profiles/active`).
//
// Codex accounts are copies of the file-based CLI login (`~/.codex/auth.json`)
// kept in app-owned CODEX_HOME directories under
// `~/Library/Application Support/MeridianBar/CodexAccounts/<name>`
// (0700 directories, 0600 files). Sign-in always runs the official
// `codex login` inside a fresh isolated home, so a cancelled or failed
// sign-in can never touch the CLI's current credentials. Activation copies a
// saved account's file over `~/.codex/auth.json` atomically, after preserving
// whatever the CLI currently holds.
//
// Credentials never appear in errors, logs, or UserDefaults.

enum AccountProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

struct ManagedAccount: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: AccountProvider
    var email: String? = nil
    var isActive = false
    var isLoggedIn = false
    var canRemove = true
    var supportsLogin = true
}

enum AccountManagerError: LocalizedError, Equatable {
    case invalidName
    case duplicateName(String)
    case alreadySaved(String)
    case toolNotFound(CLITool)
    case loginInProgress
    case loginCancelled
    case loginTimedOut
    case loginFailed(AccountProvider)
    case loginUnsupported(String)
    case accountNotFound
    case cannotRemove(String)
    case notLoggedIn(String)
    case notRoutable(String)
    case identityMismatch(String)
    case unsupportedCredentialStore(String)
    case unrecognizedCredentials
    case credentialsChangedExternally
    case meridianUnavailable
    case profileNotRegistered(String)
    case routingUpdatedButSwitchFailed(String)
    case commandFailed(String)
    case storageFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Use 1 to 64 letters, digits, hyphens, or underscores for the account name."
        case .duplicateName(let name):
            "An account named \"\(name)\" already exists."
        case .alreadySaved(let name):
            "That sign-in belongs to the saved account \"\(name)\". Nothing was changed."
        case .toolNotFound(let tool):
            "The \(tool.rawValue) command line tool was not found. Install it or add it to PATH."
        case .loginInProgress:
            "Another sign-in is still running. Finish or cancel it first."
        case .loginCancelled:
            "Sign-in was cancelled. Nothing was changed."
        case .loginTimedOut:
            "Sign-in timed out before the browser flow completed. Nothing was changed."
        case .loginFailed(let provider):
            "\(provider.title) sign-in did not complete. Nothing was changed."
        case .loginUnsupported(let name):
            "\"\(name)\" uses a long-lived token and cannot sign in through the browser."
        case .accountNotFound:
            "That account no longer exists. Refresh the list and try again."
        case .cannotRemove(let name):
            "\"\(name)\" is the tool's own login and cannot be removed here. Sign out instead."
        case .notLoggedIn(let name):
            "\"\(name)\" has no saved sign-in. Sign in before activating it."
        case .notRoutable(let name):
            "\"\(name)\" is not a Meridian profile, so Meridian cannot route to it."
        case .identityMismatch(let name):
            "The browser sign-in belongs to a different account than \"\(name)\". The sign-in was discarded."
        case .unsupportedCredentialStore(let store):
            "Codex stores its credentials in \"\(store)\", not in auth.json. Set cli_auth_credentials_store = \"file\" in ~/.codex/config.toml to switch accounts here."
        case .unrecognizedCredentials:
            "The current Codex auth.json has an unrecognized format. It was left untouched."
        case .credentialsChangedExternally:
            "The Codex login changed while switching. Refresh and try again."
        case .meridianUnavailable:
            "Meridian did not respond. Check that the proxy is running."
        case .profileNotRegistered(let id):
            "Meridian does not know the profile \"\(id)\". Refresh and try again."
        case .routingUpdatedButSwitchFailed(let id):
            "\"\(id)\" was moved to the top of the routing order, but Meridian refused to make it the active profile."
        case .commandFailed(let action):
            "Could not \(action). The command line tool reported a failure."
        case .storageFailure(let action):
            "Could not \(action) in the app's account storage."
        }
    }
}

/// Identity extracted from a Codex auth.json without retaining tokens.
struct CodexIdentity: Equatable, Sendable {
    var accountId: String? = nil
    var email: String? = nil
    var planType: String? = nil

    /// Stable comparison key: workspace id, else email, else "api-key".
    var key: String {
        if let accountId, !accountId.isEmpty { return "account:\(accountId)" }
        if let email, !email.isEmpty { return "email:\(email.lowercased())" }
        return "api-key"
    }
}

enum CodexAuthFile {
    private static let authClaim = "https://api.openai.com/auth"
    private static let profileClaim = "https://api.openai.com/profile"

    /// Reads identity claims from the id/access token; nil when the file holds no login.
    static func identity(in data: Data) -> CodexIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let tokens = object["tokens"] as? [String: Any] {
            let idClaims = claims(of: tokens["id_token"] as? String)
            let accessClaims = claims(of: tokens["access_token"] as? String)
            if idClaims != nil || accessClaims != nil {
                let auth =
                    (idClaims?[authClaim] as? [String: Any]) ?? (accessClaims?[authClaim] as? [String: Any])
                let profileEmail = (accessClaims?[profileClaim] as? [String: Any])?["email"] as? String
                return CodexIdentity(
                    accountId: (tokens["account_id"] as? String) ?? auth?["chatgpt_account_id"] as? String,
                    email: (idClaims?["email"] as? String) ?? profileEmail,
                    planType: auth?["chatgpt_plan_type"] as? String)
            }
        }
        if let key = object["OPENAI_API_KEY"] as? String, !key.isEmpty {
            return CodexIdentity(planType: "api-key")
        }
        return nil
    }

    /// Decoded payload of a JWT, unverified: display and expiry metadata only.
    static func claims(of jwt: String?) -> [String: Any]? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}

actor AccountManager {
    private let home: URL
    private let runner: any CLIProcessRunning
    private let locator: CLIToolLocator
    private let environment: [String: String]
    private var pendingLogin: Task<CLIProcessResult, Error>?

    private static let loginTimeout: Duration = .seconds(600)
    private static let codexCredentialKeys = ["OPENAI_API_KEY", "CODEX_HOME", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN"]
    private static let claudeCredentialKeys = [
        "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "MERIDIAN_CLAUDE_PATH",
    ]
    private static let codexFileStoreOverride = "cli_auth_credentials_store=\"file\""
    private static let claudeDefaultID = "claude:default"
    private static let claudeProfilePrefix = "claude:profile:"
    private static let codexCurrentID = "codex:current"
    private static let codexSavedPrefix = "codex:saved:"

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runner: any CLIProcessRunning = SystemProcessRunner(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.runner = runner
        self.environment = environment
        locator = CLIToolLocator(home: home, environment: environment)
    }

    // MARK: - Public API

    func accounts() async throws -> [ManagedAccount] {
        let claude = await claudeAccounts()
        return claude + codexAccounts()
    }

    func add(provider: AccountProvider, name: String) async throws {
        guard Self.isValidName(name) else { throw AccountManagerError.invalidName }
        switch provider {
        case .claude: try await addClaudeProfile(named: name)
        case .codex: try await addCodexAccount(named: name)
        }
    }

    func login(_ account: ManagedAccount) async throws {
        switch try reference(for: account) {
        case .claudeDefault:
            try await claudeLogin(configDir: claudeDefaultDir)
        case .claudeProfile(let id):
            let profile = try meridianProfile(id)
            guard !profile.usesOAuthToken else { throw AccountManagerError.loginUnsupported(id) }
            try await claudeLogin(configDir: configDir(of: profile))
        case .codexCurrent:
            try await loginCurrentCodex()
        case .codexSaved(let name):
            try await loginSavedCodex(named: name)
        }
    }

    func activate(_ account: ManagedAccount, baseURL: URL) async throws {
        switch try reference(for: account) {
        case .claudeDefault:
            throw AccountManagerError.notRoutable(account.name)
        case .claudeProfile(let id):
            _ = try meridianProfile(id)
            try await activateClaudeProfile(id, baseURL: baseURL)
        case .codexCurrent:
            return  // already the CLI's login by definition
        case .codexSaved(let name):
            try activateSavedCodex(named: name)
        }
    }

    func logout(_ account: ManagedAccount) async throws {
        switch try reference(for: account) {
        case .claudeDefault:
            try await claudeLogout(configDir: claudeDefaultDir)
        case .claudeProfile(let id):
            let profile = try meridianProfile(id)
            guard !profile.usesOAuthToken else { throw AccountManagerError.loginUnsupported(id) }
            try await claudeLogout(configDir: configDir(of: profile))
        case .codexCurrent:
            try await logoutCurrentCodex()
        case .codexSaved(let name):
            try await logoutSavedCodex(named: name)
        }
    }

    func remove(_ account: ManagedAccount) async throws {
        switch try reference(for: account) {
        case .claudeDefault, .codexCurrent:
            throw AccountManagerError.cannotRemove(account.name)
        case .claudeProfile(let id):
            _ = try meridianProfile(id)
            try await removeClaudeProfile(id)
        case .codexSaved(let name):
            try removeSavedCodex(named: name)
        }
    }

    /// Terminates the pending browser sign-in, if any. The awaiting caller
    /// receives `AccountManagerError.loginCancelled`.
    func cancelLogin() {
        pendingLogin?.cancel()
    }

    /// Location of the auth.json backing a Codex account, for explicit
    /// per-account consumers (OMP connect/disconnect). Validates that the
    /// selection still exists and returns a path only; contents stay on disk.
    func codexAuthFile(_ account: ManagedAccount) throws -> URL {
        switch try reference(for: account) {
        case .codexCurrent:
            return codexHome.appendingPathComponent("auth.json")
        case .codexSaved(let name):
            guard let saved = savedCodexAccount(named: name) else { throw AccountManagerError.accountNotFound }
            return saved.directory.appendingPathComponent("auth.json")
        case .claudeDefault, .claudeProfile:
            throw AccountManagerError.accountNotFound
        }
    }

    /// Identity of a Codex account's saved sign-in; nil for Claude accounts
    /// or when the account has no login.
    func codexIdentity(_ account: ManagedAccount) -> CodexIdentity? {
        switch try? reference(for: account) {
        case .codexCurrent:
            if case .present(let snapshot) = currentCodexAuth() { return snapshot.identity }
            return nil
        case .codexSaved(let name):
            return savedCodexAccount(named: name)?.identity
        case .claudeDefault, .claudeProfile, .none:
            return nil
        }
    }

    // MARK: - Ids and names

    private enum AccountReference {
        case claudeDefault
        case claudeProfile(String)
        case codexCurrent
        case codexSaved(String)
    }

    private func reference(for account: ManagedAccount) throws -> AccountReference {
        let id = account.id
        if id == Self.claudeDefaultID { return .claudeDefault }
        if id == Self.codexCurrentID { return .codexCurrent }
        if id.hasPrefix(Self.claudeProfilePrefix) {
            let name = String(id.dropFirst(Self.claudeProfilePrefix.count))
            guard Self.isValidName(name) else { throw AccountManagerError.accountNotFound }
            return .claudeProfile(name)
        }
        if id.hasPrefix(Self.codexSavedPrefix) {
            let name = String(id.dropFirst(Self.codexSavedPrefix.count))
            guard Self.isValidName(name) else { throw AccountManagerError.accountNotFound }
            return .codexSaved(name)
        }
        throw AccountManagerError.accountNotFound
    }

    /// Meridian's profile rule (`[a-zA-Z0-9_-]+`), also our directory rule.
    static func isValidName(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count) && name.allSatisfy(isNameCharacter)
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    // MARK: - Process helpers

    private func tool(_ tool: CLITool) throws -> URL {
        guard let url = locator.locate(tool) else { throw AccountManagerError.toolNotFound(tool) }
        return url
    }

    private nonisolated func baseEnvironment(stripping keys: [String]) -> [String: String] {
        var env = environment
        for key in keys { env.removeValue(forKey: key) }
        env["HOME"] = home.path
        env["PATH"] = locator.pathValue
        return env
    }

    private nonisolated func claudeEnvironment(configDir: URL?) -> [String: String] {
        var env = baseEnvironment(stripping: Self.claudeCredentialKeys)
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir.path }
        return env
    }

    private nonisolated func codexEnvironment(home codexHome: URL) -> [String: String] {
        var env = baseEnvironment(stripping: Self.codexCredentialKeys)
        env["CODEX_HOME"] = codexHome.path
        return env
    }

    /// Runs a browser sign-in as the single pending login; `cancelLogin` kills it.
    private func runLogin(_ spec: CLIProcessSpec) async throws -> CLIProcessResult {
        guard pendingLogin == nil else { throw AccountManagerError.loginInProgress }
        let runner = self.runner
        let task = Task.detached { try await runner.run(spec) }
        pendingLogin = task
        defer { pendingLogin = nil }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch let failure as CLIProcessFailure {
            switch failure {
            case .cancelled: throw AccountManagerError.loginCancelled
            case .timedOut: throw AccountManagerError.loginTimedOut
            case .launchFailed(let name): throw AccountManagerError.commandFailed("start \(name)")
            }
        } catch is CancellationError {
            throw AccountManagerError.loginCancelled
        }
    }

    /// Runs a short non-interactive command; failures map to `commandFailed(action)`.
    private nonisolated func runCommand(_ spec: CLIProcessSpec, action: String) async throws -> CLIProcessResult {
        do {
            return try await runner.run(spec)
        } catch {
            throw AccountManagerError.commandFailed(action)
        }
    }

    // MARK: - Claude

    private var claudeDefaultDir: URL { home.appendingPathComponent(".claude") }
    private var meridianConfigDir: URL { home.appendingPathComponent(".config/meridian") }
    private var meridianProfilesFile: URL { meridianConfigDir.appendingPathComponent("profiles.json") }
    private var meridianSettingsFile: URL { meridianConfigDir.appendingPathComponent("settings.json") }
    private var meridianProfilesDir: URL { meridianConfigDir.appendingPathComponent("profiles") }

    private struct MeridianProfile: Sendable {
        var id: String
        var claudeConfigDir: String?
        var usesOAuthToken: Bool
    }

    private struct MeridianSettings: Decodable {
        var routing: String?
        var profileOrder: [String]?
        var activeProfile: String?
    }

    private struct ClaudeAuthStatus: Sendable {
        var loggedIn = false
        var email: String? = nil
        var subscriptionType: String? = nil
    }

    private func readMeridianProfiles() -> [MeridianProfile] {
        guard let data = try? Data(contentsOf: meridianProfilesFile),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry -> MeridianProfile? in
            guard let id = entry["id"] as? String else { return nil }
            let usesToken = entry["oauthToken"] != nil || (entry["type"] as? String) == "oauth-token"
            return MeridianProfile(
                id: id, claudeConfigDir: entry["claudeConfigDir"] as? String, usesOAuthToken: usesToken)
        }
    }

    private func readMeridianSettings() -> MeridianSettings {
        guard let data = try? Data(contentsOf: meridianSettingsFile),
            let settings = try? JSONDecoder().decode(MeridianSettings.self, from: data)
        else { return MeridianSettings() }
        return settings
    }

    private func meridianProfile(_ id: String) throws -> MeridianProfile {
        guard let profile = readMeridianProfiles().first(where: { $0.id == id }) else {
            throw AccountManagerError.accountNotFound
        }
        return profile
    }

    private func configDir(of profile: MeridianProfile) -> URL {
        profile.claudeConfigDir.map { URL(fileURLWithPath: $0) }
            ?? meridianProfilesDir.appendingPathComponent(profile.id)
    }

    private func claudeAccounts() async -> [ManagedAccount] {
        let profiles = readMeridianProfiles()
        let settings = readMeridianSettings()
        // Under priority routing the head of profileOrder steers traffic, not
        // activeProfile (okf/01). Report what actually serves requests.
        let routedID =
            settings.routing == "priority"
            ? (settings.profileOrder?.first ?? settings.activeProfile) : settings.activeProfile
        let defaultPath = claudeDefaultDir.standardizedFileURL.path
        let defaultImported = profiles.contains { profile in
            profile.claudeConfigDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path == defaultPath } ?? false
        }

        var ordered: [MeridianProfile] = []
        for id in settings.profileOrder ?? [] {
            if let profile = profiles.first(where: { $0.id == id }) { ordered.append(profile) }
        }
        for profile in profiles where !ordered.contains(where: { $0.id == profile.id }) { ordered.append(profile) }

        var statusDirs: [(id: String, dir: URL)] = []
        if !defaultImported { statusDirs.append((Self.claudeDefaultID, claudeDefaultDir)) }
        for profile in ordered where !profile.usesOAuthToken {
            statusDirs.append((Self.claudeProfilePrefix + profile.id, configDir(of: profile)))
        }
        let statuses = await withTaskGroup(of: (String, ClaudeAuthStatus).self) { group in
            for entry in statusDirs {
                group.addTask { (entry.id, await self.claudeAuthStatus(configDir: entry.dir)) }
            }
            var result: [String: ClaudeAuthStatus] = [:]
            for await (id, status) in group { result[id] = status }
            return result
        }

        var accounts: [ManagedAccount] = []
        if !defaultImported {
            let status = statuses[Self.claudeDefaultID] ?? ClaudeAuthStatus()
            accounts.append(
                ManagedAccount(
                    id: Self.claudeDefaultID, name: "Claude CLI (default)", provider: .claude,
                    email: status.email, isActive: false, isLoggedIn: status.loggedIn,
                    canRemove: false, supportsLogin: true))
        }
        for profile in ordered {
            let id = Self.claudeProfilePrefix + profile.id
            if profile.usesOAuthToken {
                accounts.append(
                    ManagedAccount(
                        id: id, name: profile.id, provider: .claude, email: nil,
                        isActive: profile.id == routedID, isLoggedIn: true,
                        canRemove: true, supportsLogin: false))
            } else {
                let status = statuses[id] ?? ClaudeAuthStatus()
                accounts.append(
                    ManagedAccount(
                        id: id, name: profile.id, provider: .claude, email: status.email,
                        isActive: profile.id == routedID, isLoggedIn: status.loggedIn,
                        canRemove: true, supportsLogin: true))
            }
        }
        return accounts
    }

    /// `claude auth status --json` for one config dir. Exit status is 1 when
    /// logged out but the JSON is still printed, so only the body matters.
    private nonisolated func claudeAuthStatus(configDir: URL) async -> ClaudeAuthStatus {
        guard let claude = locator.locate(.claude) else { return ClaudeAuthStatus() }
        var spec = CLIProcessSpec(
            executable: claude, arguments: ["auth", "status", "--json"],
            environment: claudeEnvironment(configDir: configDir))
        spec.timeout = .seconds(15)
        guard let result = try? await runner.run(spec),
            let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        else { return ClaudeAuthStatus() }
        return ClaudeAuthStatus(
            loggedIn: object["loggedIn"] as? Bool ?? false,
            email: object["email"] as? String,
            subscriptionType: object["subscriptionType"] as? String)
    }

    private func addClaudeProfile(named name: String) async throws {
        guard !readMeridianProfiles().contains(where: { $0.id == name }) else {
            throw AccountManagerError.duplicateName(name)
        }
        let meridian = try tool(.meridian)
        let claude = try tool(.claude)
        var env = claudeEnvironment(configDir: nil)
        env["MERIDIAN_CLAUDE_PATH"] = claude.path
        var spec = CLIProcessSpec(executable: meridian, arguments: ["profile", "add", name], environment: env)
        spec.keepsStdinOpen = true
        spec.timeout = Self.loginTimeout
        // Meridian offers to import the default ~/.claude login and treats an
        // empty answer as yes. Decline so the new profile gets its own OAuth.
        spec.promptReplies = [CLIPromptReply(prompt: "Import as profile", reply: "n\n")]
        let result = try await runLogin(spec)
        guard result.succeeded, readMeridianProfiles().contains(where: { $0.id == name }) else {
            throw AccountManagerError.loginFailed(.claude)
        }
    }

    private func claudeLogin(configDir: URL) async throws {
        let claude = try tool(.claude)
        var spec = CLIProcessSpec(
            executable: claude, arguments: ["auth", "login"], environment: claudeEnvironment(configDir: configDir))
        spec.keepsStdinOpen = true
        spec.timeout = Self.loginTimeout
        let result = try await runLogin(spec)
        guard result.succeeded, await claudeAuthStatus(configDir: configDir).loggedIn else {
            throw AccountManagerError.loginFailed(.claude)
        }
    }

    private func claudeLogout(configDir: URL) async throws {
        let claude = try tool(.claude)
        let spec = CLIProcessSpec(
            executable: claude, arguments: ["auth", "logout"], environment: claudeEnvironment(configDir: configDir))
        let result = try await runCommand(spec, action: "sign out of Claude")
        guard result.succeeded else { throw AccountManagerError.commandFailed("sign out of Claude") }
    }

    private func removeClaudeProfile(_ id: String) async throws {
        let meridian = try tool(.meridian)
        var env = claudeEnvironment(configDir: nil)
        if let claude = locator.locate(.claude) { env["MERIDIAN_CLAUDE_PATH"] = claude.path }
        var spec = CLIProcessSpec(executable: meridian, arguments: ["profile", "remove", id], environment: env)
        spec.timeout = .seconds(60)
        let result = try await runCommand(spec, action: "remove the Meridian profile")
        guard result.succeeded, !readMeridianProfiles().contains(where: { $0.id == id }) else {
            throw AccountManagerError.commandFailed("remove the Meridian profile")
        }
    }

    /// Endpoints per okf/01: GET profiles/list, PUT settings/api/routing
    /// (priority routing only), POST profiles/active.
    private func activateClaudeProfile(_ id: String, baseURL: URL) async throws {
        let client = MeridianClient(baseURL: baseURL)
        let list: ProfilesList
        do {
            list = try await client.profilesList()
        } catch {
            throw AccountManagerError.meridianUnavailable
        }
        guard list.profiles.contains(where: { $0.id == id }) else {
            throw AccountManagerError.profileNotRegistered(id)
        }
        var routingUpdated = false
        if list.routing == "priority" {
            let known = list.profileOrder ?? list.profiles.map(\.id)
            try await putRoutingOrder([id] + known.filter { $0 != id }, baseURL: baseURL)
            routingUpdated = true
        }
        do {
            try await client.switchProfile(id)
        } catch {
            throw routingUpdated
                ? AccountManagerError.routingUpdatedButSwitchFailed(id)
                : AccountManagerError.commandFailed("switch the active Meridian profile")
        }
    }

    private nonisolated func putRoutingOrder(_ order: [String], baseURL: URL) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("settings/api/routing"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["profileOrder": order])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        let response: URLResponse
        do {
            response = try await URLSession(configuration: config).data(for: request).1
        } catch {
            throw AccountManagerError.meridianUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AccountManagerError.commandFailed("update the Meridian routing order")
        }
    }

    // MARK: - Codex

    private var codexHome: URL {
        environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
    }
    private var currentCodexAuthFile: URL { codexHome.appendingPathComponent("auth.json") }
    private var codexAccountsDir: URL {
        home.appendingPathComponent("Library/Application Support/MeridianBar/CodexAccounts")
    }

    private struct CodexAuthSnapshot: Sendable {
        var data: Data
        var identity: CodexIdentity
    }

    private enum CurrentCodexAuth {
        case absent
        case unrecognized
        case present(CodexAuthSnapshot)
    }

    private struct SavedCodexAccount: Sendable {
        var name: String
        var directory: URL
        var authData: Data?
        var identity: CodexIdentity?
        var metadata: CodexAccountMetadata?
    }

    private struct CodexAccountMetadata: Codable, Sendable {
        var name: String
        var accountId: String?
        var email: String?
        var planType: String?
        var savedAt: Date
    }

    private func currentCodexAuth() -> CurrentCodexAuth {
        guard let data = try? Data(contentsOf: currentCodexAuthFile) else { return .absent }
        guard let identity = CodexAuthFile.identity(in: data) else { return .unrecognized }
        return .present(CodexAuthSnapshot(data: data, identity: identity))
    }

    private func savedCodexAccounts() -> [SavedCodexAccount] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: codexAccountsDir.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names.sorted().compactMap { name -> SavedCodexAccount? in
            guard Self.isValidName(name) else { return nil }
            let directory = codexAccountsDir.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            let authData = try? Data(contentsOf: directory.appendingPathComponent("auth.json"))
            let metadata = (try? Data(contentsOf: directory.appendingPathComponent("metadata.json")))
                .flatMap { try? decoder.decode(CodexAccountMetadata.self, from: $0) }
            return SavedCodexAccount(
                name: name, directory: directory, authData: authData,
                identity: authData.flatMap(CodexAuthFile.identity(in:)), metadata: metadata)
        }
    }

    private func savedCodexAccount(named name: String) -> SavedCodexAccount? {
        savedCodexAccounts().first { $0.name == name }
    }

    private func codexAccounts() -> [ManagedAccount] {
        let current = currentCodexAuth()
        var currentIdentity: CodexIdentity?
        if case .present(let snapshot) = current { currentIdentity = snapshot.identity }
        var accounts: [ManagedAccount] = []
        var matchedCurrent = false
        for saved in savedCodexAccounts() {
            let isActive = currentIdentity != nil && saved.identity?.key == currentIdentity?.key
            matchedCurrent = matchedCurrent || isActive
            accounts.append(
                ManagedAccount(
                    id: Self.codexSavedPrefix + saved.name, name: saved.name, provider: .codex,
                    email: saved.identity?.email ?? saved.metadata?.email,
                    isActive: isActive, isLoggedIn: saved.identity != nil,
                    canRemove: true, supportsLogin: true))
        }
        if !matchedCurrent {
            accounts.insert(
                ManagedAccount(
                    id: Self.codexCurrentID, name: "Codex CLI (current)", provider: .codex,
                    email: currentIdentity?.email, isActive: currentIdentity != nil,
                    isLoggedIn: currentIdentity != nil, canRemove: false, supportsLogin: true),
                at: 0)
        }
        return accounts
    }

    /// Runs `codex login` in a fresh app-owned CODEX_HOME. On success the
    /// staging directory holds a validated auth.json; the caller moves or
    /// deletes it. Any failure deletes the staging directory.
    private func runIsolatedCodexLogin() async throws -> (directory: URL, snapshot: CodexAuthSnapshot) {
        let codex = try tool(.codex)
        try ensurePrivateDirectory(codexAccountsDir)
        let staging = codexAccountsDir.appendingPathComponent(".pending-\(UUID().uuidString)")
        try ensurePrivateDirectory(staging)
        var spec = CLIProcessSpec(
            executable: codex, arguments: ["login", "-c", Self.codexFileStoreOverride],
            environment: codexEnvironment(home: staging))
        spec.keepsStdinOpen = true
        spec.timeout = Self.loginTimeout
        do {
            let result = try await runLogin(spec)
            guard result.succeeded,
                let data = try? Data(contentsOf: staging.appendingPathComponent("auth.json")),
                let identity = CodexAuthFile.identity(in: data)
            else { throw AccountManagerError.loginFailed(.codex) }
            return (staging, CodexAuthSnapshot(data: data, identity: identity))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func addCodexAccount(named name: String) async throws {
        let target = codexAccountsDir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw AccountManagerError.duplicateName(name)
        }
        if case .present(let current) = currentCodexAuth() { try preserveCurrentCodexLogin(current) }
        let login = try await runIsolatedCodexLogin()
        do {
            if let owner = savedCodexAccounts().first(where: { $0.identity?.key == login.snapshot.identity.key }) {
                throw AccountManagerError.alreadySaved(owner.name)
            }
            guard !FileManager.default.fileExists(atPath: target.path) else {
                throw AccountManagerError.duplicateName(name)
            }
            try writeSecretFile(login.snapshot.data, to: login.directory.appendingPathComponent("auth.json"))
            try writeMetadata(name: name, identity: login.snapshot.identity, in: login.directory)
            do {
                try FileManager.default.moveItem(at: login.directory, to: target)
            } catch {
                throw AccountManagerError.storageFailure("save the account")
            }
        } catch {
            try? FileManager.default.removeItem(at: login.directory)
            throw error
        }
    }

    private func loginSavedCodex(named name: String) async throws {
        guard let saved = savedCodexAccount(named: name) else { throw AccountManagerError.accountNotFound }
        let login = try await runIsolatedCodexLogin()
        defer { try? FileManager.default.removeItem(at: login.directory) }
        if let existing = saved.identity, existing.key != login.snapshot.identity.key {
            throw AccountManagerError.identityMismatch(name)
        }
        try writeSecretFile(login.snapshot.data, to: saved.directory.appendingPathComponent("auth.json"))
        try writeMetadata(name: name, identity: login.snapshot.identity, in: saved.directory)
        // If this account is what the CLI uses right now, hand it the fresh
        // tokens too; a non-file store is left alone (not silently altered).
        if case .present(let current) = currentCodexAuth(),
            current.identity.key == login.snapshot.identity.key,
            (try? ensureCodexFileStore()) != nil
        {
            try installCurrentCodexAuth(login.snapshot.data)
        }
    }

    private func loginCurrentCodex() async throws {
        try ensureCodexFileStore()
        let login = try await runIsolatedCodexLogin()
        defer { try? FileManager.default.removeItem(at: login.directory) }
        switch currentCodexAuth() {
        case .present(let current) where current.identity.key != login.snapshot.identity.key:
            try preserveCurrentCodexLogin(current)
        case .unrecognized:
            throw AccountManagerError.unrecognizedCredentials
        default:
            break
        }
        try installCurrentCodexAuth(login.snapshot.data)
        if let saved = savedCodexAccounts().first(where: { $0.identity?.key == login.snapshot.identity.key }) {
            try writeSecretFile(login.snapshot.data, to: saved.directory.appendingPathComponent("auth.json"))
            try writeMetadata(name: saved.name, identity: login.snapshot.identity, in: saved.directory)
        }
    }

    private func activateSavedCodex(named name: String) throws {
        try ensureCodexFileStore()
        guard let target = savedCodexAccount(named: name) else { throw AccountManagerError.accountNotFound }
        guard let targetData = target.authData, let targetIdentity = target.identity else {
            throw AccountManagerError.notLoggedIn(name)
        }
        let before: CodexAuthSnapshot?
        switch currentCodexAuth() {
        case .absent: before = nil
        case .unrecognized: throw AccountManagerError.unrecognizedCredentials
        case .present(let snapshot): before = snapshot
        }
        if let before {
            try preserveCurrentCodexLogin(before)
            if before.identity.key == targetIdentity.key { return }
        }
        // Guard against the CLI refreshing tokens between preserve and replace.
        let now = try? Data(contentsOf: currentCodexAuthFile)
        guard now == before?.data else { throw AccountManagerError.credentialsChangedExternally }
        try installCurrentCodexAuth(targetData)
    }

    private func logoutSavedCodex(named name: String) async throws {
        guard let saved = savedCodexAccount(named: name) else { throw AccountManagerError.accountNotFound }
        let codex = try tool(.codex)
        let spec = CLIProcessSpec(
            executable: codex, arguments: ["logout", "-c", Self.codexFileStoreOverride],
            environment: codexEnvironment(home: saved.directory))
        _ = try? await runner.run(spec)
        let authFile = saved.directory.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: authFile.path) {
            do {
                try FileManager.default.removeItem(at: authFile)
            } catch {
                throw AccountManagerError.storageFailure("remove the saved sign-in")
            }
        }
    }

    /// Signs the CLI itself out through `codex logout` in its own home, with
    /// whatever credential store the user configured.
    private func logoutCurrentCodex() async throws {
        let codex = try tool(.codex)
        let spec = CLIProcessSpec(
            executable: codex, arguments: ["logout"], environment: codexEnvironment(home: codexHome))
        let result = try await runCommand(spec, action: "sign out of Codex")
        guard result.succeeded else { throw AccountManagerError.commandFailed("sign out of Codex") }
    }

    private func removeSavedCodex(named name: String) throws {
        guard let saved = savedCodexAccount(named: name) else { throw AccountManagerError.accountNotFound }
        let root = codexAccountsDir.standardizedFileURL.path + "/"
        guard saved.directory.standardizedFileURL.path.hasPrefix(root) else {
            throw AccountManagerError.storageFailure("remove the account")
        }
        do {
            try FileManager.default.removeItem(at: saved.directory)
        } catch {
            throw AccountManagerError.storageFailure("remove the account")
        }
    }

    /// Keeps the CLI's current login as a saved account: refreshes the saved
    /// copy that shares its identity, or imports it under a derived name.
    private func preserveCurrentCodexLogin(_ current: CodexAuthSnapshot) throws {
        let saved = savedCodexAccounts()
        if let match = saved.first(where: { $0.identity?.key == current.identity.key }) {
            guard match.authData != current.data else { return }
            try writeSecretFile(current.data, to: match.directory.appendingPathComponent("auth.json"))
            try writeMetadata(name: match.name, identity: current.identity, in: match.directory)
            return
        }
        let name = Self.uniqueImportName(for: current.identity, taken: saved.map(\.name))
        let directory = codexAccountsDir.appendingPathComponent(name)
        try ensurePrivateDirectory(directory)
        try writeSecretFile(current.data, to: directory.appendingPathComponent("auth.json"))
        try writeMetadata(name: name, identity: current.identity, in: directory)
    }

    static func uniqueImportName(for identity: CodexIdentity, taken: [String]) -> String {
        let local = identity.email?.split(separator: "@").first.map(String.init) ?? ""
        var slug = ""
        var lastWasDash = true
        for character in local.lowercased() {
            if isNameCharacter(character), character != "-" {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "imported" }
        slug = String(slug.prefix(32))
        guard taken.contains(slug) else { return slug }
        var counter = 2
        while taken.contains("\(slug)-\(counter)") { counter += 1 }
        return "\(slug)-\(counter)"
    }

    /// Codex reads `cli_auth_credentials_store` from config.toml; only the
    /// file store keeps credentials in auth.json where activation can act.
    private func ensureCodexFileStore() throws {
        guard let text = try? String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        else { return }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }  // end of top-level keys
            guard line.hasPrefix("cli_auth_credentials_store") else { continue }
            var value = line.drop(while: { $0 != "=" }).dropFirst()
            if let hash = value.firstIndex(of: "#") { value = value[..<hash] }
            let store = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if store != "file" { throw AccountManagerError.unsupportedCredentialStore(store) }
        }
    }

    /// Replaces ~/.codex/auth.json atomically with 0600 permissions.
    private func installCurrentCodexAuth(_ data: Data) throws {
        try ensurePrivateDirectory(codexHome)
        try writeSecretFile(data, to: currentCodexAuthFile)
    }

    // MARK: - Storage primitives

    private func writeMetadata(name: String, identity: CodexIdentity, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadata = CodexAccountMetadata(
            name: name, accountId: identity.accountId, email: identity.email, planType: identity.planType,
            savedAt: Date())
        guard let data = try? encoder.encode(metadata) else {
            throw AccountManagerError.storageFailure("write account metadata")
        }
        try writeSecretFile(data, to: directory.appendingPathComponent("metadata.json"))
    }

    /// Creates the directory 0700 if missing; existing directories keep their mode.
    private func ensurePrivateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw AccountManagerError.storageFailure("create a directory") }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AccountManagerError.storageFailure("create a directory")
        }
    }

    /// Writes to a 0600 temp file beside the destination, then renames over it.
    private func writeSecretFile(_ data: Data, to destination: URL) throws {
        let action = "write \(destination.lastPathComponent)"
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AccountManagerError.storageFailure(action) }
        var complete = false
        defer {
            close(fd)
            if !complete { unlink(temp.path) }
        }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n <= 0 { break }
                offset += n
            }
            return offset
        }
        guard written == data.count, fsync(fd) == 0 else { throw AccountManagerError.storageFailure(action) }
        guard rename(temp.path, destination.path) == 0 else { throw AccountManagerError.storageFailure(action) }
        complete = true
    }
}
