import Foundation

// Claude account management behind the menu bar.
//
// Accounts are Meridian profiles (`~/.config/meridian/profiles.json`,
// okf/01) plus the default Claude CLI login in `~/.claude`. Every mutation
// goes through the official CLIs: `meridian profile add|remove`,
// `claude auth login|logout|status`. Routing changes use the Meridian HTTP
// surface recorded in okf/01 (`profiles/list`, `settings/api/routing`,
// `profiles/active`).
//
// Credentials never appear in errors, logs, or UserDefaults.

struct ManagedAccount: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var email: String? = nil
    var isActive = false
    var isLoggedIn = false
    var canRemove = true
    var supportsLogin = true
}

enum AccountManagerError: LocalizedError, Equatable {
    case invalidName
    case duplicateName(String)
    case toolNotFound(CLITool)
    case loginInProgress
    case loginCancelled
    case loginTimedOut
    case loginFailed
    case loginUnsupported(String)
    case accountNotFound
    case cannotRemove(String)
    case notRoutable(String)
    case meridianUnavailable
    case profileNotRegistered(String)
    case routingUpdatedButSwitchFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "Use 1 to 64 letters, digits, hyphens, or underscores for the account name."
        case .duplicateName(let name):
            "An account named \"\(name)\" already exists."
        case .toolNotFound(let tool):
            "The \(tool.rawValue) command line tool was not found. Install it or add it to PATH."
        case .loginInProgress:
            "Another sign-in is still running. Finish or cancel it first."
        case .loginCancelled:
            "Sign-in was cancelled. Nothing was changed."
        case .loginTimedOut:
            "Sign-in timed out before the browser flow completed. Nothing was changed."
        case .loginFailed:
            "Claude sign-in did not complete. Nothing was changed."
        case .loginUnsupported(let name):
            "\"\(name)\" uses a long-lived token and cannot sign in through the browser."
        case .accountNotFound:
            "That account no longer exists. Refresh the list and try again."
        case .cannotRemove(let name):
            "\"\(name)\" is the tool's own login and cannot be removed here. Sign out instead."
        case .notRoutable(let name):
            "\"\(name)\" is not a Meridian profile, so Meridian cannot route to it."
        case .meridianUnavailable:
            "Meridian did not respond. Check that the proxy is running."
        case .profileNotRegistered(let id):
            "Meridian does not know the profile \"\(id)\". Refresh and try again."
        case .routingUpdatedButSwitchFailed(let id):
            "\"\(id)\" was moved to the top of the routing order, but Meridian refused to make it the active profile."
        case .commandFailed(let action):
            "Could not \(action). The command line tool reported a failure."
        }
    }
}

actor AccountManager {
    private let home: URL
    private let runner: any CLIProcessRunning
    private let locator: CLIToolLocator
    private let environment: [String: String]
    private var pendingLogin: Task<CLIProcessResult, Error>?

    private static let loginTimeout: Duration = .seconds(600)
    private static let claudeCredentialKeys = [
        "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
        "MERIDIAN_CLAUDE_PATH",
    ]
    private static let claudeDefaultID = "claude:default"
    private static let claudeProfilePrefix = "claude:profile:"

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
        await claudeAccounts()
    }

    func add(name: String) async throws {
        guard Self.isValidName(name) else { throw AccountManagerError.invalidName }
        try await addClaudeProfile(named: name)
    }

    func login(_ account: ManagedAccount) async throws {
        switch try reference(for: account) {
        case .claudeDefault:
            try await claudeLogin(configDir: claudeDefaultDir)
        case .claudeProfile(let id):
            let profile = try meridianProfile(id)
            guard !profile.usesOAuthToken else { throw AccountManagerError.loginUnsupported(id) }
            try await claudeLogin(configDir: configDir(of: profile))
        }
    }

    func activate(_ account: ManagedAccount, baseURL: URL) async throws {
        switch try reference(for: account) {
        case .claudeDefault:
            throw AccountManagerError.notRoutable(account.name)
        case .claudeProfile(let id):
            _ = try meridianProfile(id)
            try await activateClaudeProfile(id, baseURL: baseURL)
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
        }
    }

    func remove(_ account: ManagedAccount) async throws {
        switch try reference(for: account) {
        case .claudeDefault:
            throw AccountManagerError.cannotRemove(account.name)
        case .claudeProfile(let id):
            _ = try meridianProfile(id)
            try await removeClaudeProfile(id)
        }
    }

    /// Terminates the pending browser sign-in, if any. The awaiting caller
    /// receives `AccountManagerError.loginCancelled`.
    func cancelLogin() {
        pendingLogin?.cancel()
    }

    // MARK: - Ids and names

    private enum AccountReference {
        case claudeDefault
        case claudeProfile(String)
    }

    private func reference(for account: ManagedAccount) throws -> AccountReference {
        let id = account.id
        if id == Self.claudeDefaultID { return .claudeDefault }
        if id.hasPrefix(Self.claudeProfilePrefix) {
            let name = String(id.dropFirst(Self.claudeProfilePrefix.count))
            guard Self.isValidName(name) else { throw AccountManagerError.accountNotFound }
            return .claudeProfile(name)
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
                    id: Self.claudeDefaultID, name: "Claude CLI (default)",
                    email: status.email, isActive: false, isLoggedIn: status.loggedIn,
                    canRemove: false, supportsLogin: true))
        }
        for profile in ordered {
            let id = Self.claudeProfilePrefix + profile.id
            if profile.usesOAuthToken {
                accounts.append(
                    ManagedAccount(
                        id: id, name: profile.id, email: nil,
                        isActive: profile.id == routedID, isLoggedIn: true,
                        canRemove: true, supportsLogin: false))
            } else {
                let status = statuses[id] ?? ClaudeAuthStatus()
                accounts.append(
                    ManagedAccount(
                        id: id, name: profile.id, email: status.email,
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
            throw AccountManagerError.loginFailed
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
            throw AccountManagerError.loginFailed
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
}
