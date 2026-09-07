import Foundation
import SQLite3

// Routes OMP's OpenAI (GPT) traffic through the Codex accounts saved in this
// app. OMP keeps its own credential pool for the `openai-codex` provider in
// `~/.omp/agent/agent.db` and load-balances requests across every row. This
// file reads that pool (read-only SQLite, identity fields only) and changes
// it exclusively through the official CLI: `omp auth-broker import` adds or
// refreshes an account, `omp auth-broker logout openai-codex` clears the
// provider. There is no per-row removal command, so disconnecting one account
// means clearing the provider and re-importing the others; that only runs
// when every pooled row belongs to an account this app knows.
//
// A refresh token is copied, not shared: after import, OMP and the Codex CLI
// refresh independently. If one side's token stops working, "Sign in again"
// re-mints both copies.

/// One `openai-codex` credential OMP can route through.
struct OMPPoolEntry: Equatable, Sendable {
    var email: String?
    var accountId: String?

    /// Same shape as `CodexIdentity.key`, so pool rows match saved accounts.
    var key: String { CodexIdentity(accountId: accountId, email: email).key }
}

struct OMPPoolStatus: Equatable, Sendable {
    var toolFound = false
    var storeFound = false
    /// OMP is configured for a remote auth broker; the local store is not
    /// the pool it uses, so this app must not manage it.
    var brokerConfigured = false
    var entries: [OMPPoolEntry] = []
    var error: OMPSyncError?

    var isManageable: Bool { toolFound && !brokerConfigured && error == nil }

    func contains(_ identity: CodexIdentity) -> Bool {
        entries.contains { $0.key == identity.key }
    }
}

enum OMPSyncError: LocalizedError, Equatable {
    case toolNotFound
    case brokerConfigured
    case storeUnreadable
    case notLoggedIn(String)
    case exportFailed(String)
    case importFailed(String)
    case logoutFailed
    case unmanagedCredentials([String])

    var errorDescription: String? {
        switch self {
        case .toolNotFound:
            "The omp command line tool was not found. Install it or add it to PATH."
        case .brokerConfigured:
            "OMP uses a remote auth broker. Manage its OpenAI accounts with omp auth-broker instead."
        case .storeUnreadable:
            "OMP's credential store could not be read."
        case .notLoggedIn(let name):
            "\"\(name)\" has no saved sign-in, so there is nothing to route through OMP."
        case .exportFailed(let name):
            "The saved sign-in for \"\(name)\" is not a ChatGPT login OMP can use."
        case .importFailed(let reason):
            "OMP did not accept the account: \(reason)"
        case .logoutFailed:
            "OMP could not clear its OpenAI accounts. Nothing was re-imported."
        case .unmanagedCredentials(let names):
            "OMP also routes through accounts this app does not manage (\(names.joined(separator: ", "))). "
                + "Run `omp auth-broker logout openai-codex` to clear them, then sync again."
        }
    }
}

/// Pure conversions between a Codex `auth.json` and the CLIProxyAPI JSON that
/// `omp auth-broker import` accepts. Unit-tested; no I/O.
enum OMPCredentialExport {
    /// Import-ready JSON, or nil when the file holds no ChatGPT OAuth login
    /// (API-key logins have no refresh token and cannot join the pool).
    static func importDocument(fromCodexAuth data: Data, now: Date = Date()) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = object["tokens"] as? [String: Any],
            let access = tokens["access_token"] as? String, !access.isEmpty,
            let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty
        else { return nil }
        let identity = CodexAuthFile.identity(in: data)
        var document: [String: Any] = [
            "type": "codex",
            "access_token": access,
            "refresh_token": refresh,
            "expired": ISO8601DateFormatter().string(from: expiry(ofJWT: access) ?? now),
        ]
        if let idToken = tokens["id_token"] as? String, !idToken.isEmpty { document["id_token"] = idToken }
        if let email = identity?.email { document["email"] = email }
        if let accountId = identity?.accountId { document["account_id"] = accountId }
        if let lastRefresh = object["last_refresh"] as? String { document["last_refresh"] = lastRefresh }
        return try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }

    /// `exp` claim of a JWT as a date; nil when absent or malformed.
    static func expiry(ofJWT jwt: String) -> Date? {
        guard let exp = CodexAuthFile.claims(of: jwt)?["exp"] else { return nil }
        if let seconds = exp as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = exp as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        return nil
    }

    /// Outcome of `omp auth-broker import --json`. The CLI may print status
    /// lines before the JSON document, so every line is tried.
    enum ImportOutcome: Equatable {
        case imported
        case skipped(String)
        case failed(String)
        case unreadable
    }

    static func importOutcome(stdout: Data) -> ImportOutcome {
        var sawDocument = false
        for line in String(decoding: stdout, as: UTF8.self).split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let error = object["error"] as? String { return .failed(error) }
            guard object["imported"] != nil || object["skipped"] != nil else { continue }
            sawDocument = true
            if let skipped = object["skipped"] as? [[String: Any]], let first = skipped.first {
                return .skipped((first["reason"] as? String) ?? "unknown reason")
            }
            if let imported = object["imported"] as? [Any], !imported.isEmpty { return .imported }
        }
        return sawDocument ? .skipped("no credential was written") : .unreadable
    }

    /// True when OMP's config points at a remote broker (`auth.broker.url`),
    /// in nested or literal dotted-key form.
    static func brokerConfigured(inConfigYAML text: String) -> Bool {
        var depthStack: [(indent: Int, key: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            while let last = depthStack.last, last.indent >= indent { depthStack.removeLast() }
            let path = (depthStack.map(\.key) + [key]).joined(separator: ".")
            if path == "auth.broker.url", !value.isEmpty, value != "null", value != "~", value != "\"\"" {
                return true
            }
            depthStack.append((indent, key))
        }
        return false
    }
}

actor OMPAccountSync {
    private let home: URL
    private let runner: any CLIProcessRunning
    private let locator: CLIToolLocator
    private let environment: [String: String]

    private static let provider = "openai-codex"

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

    /// OMP's agent directory: `PI_CODING_AGENT_DIR`, else `~/.omp/agent`.
    private var agentDir: URL {
        if let override = environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return home.appendingPathComponent(".omp/agent")
    }

    private var databaseFile: URL { agentDir.appendingPathComponent("agent.db") }

    // MARK: - Status

    func status() -> OMPPoolStatus {
        var status = OMPPoolStatus()
        status.toolFound = locator.locate(.omp) != nil
        status.brokerConfigured = brokerConfigured()
        guard status.toolFound else {
            status.error = .toolNotFound
            return status
        }
        guard !status.brokerConfigured else {
            status.error = .brokerConfigured
            return status
        }
        guard FileManager.default.fileExists(atPath: databaseFile.path) else {
            // OMP has never stored a credential; the pool is simply empty.
            return status
        }
        status.storeFound = true
        do {
            status.entries = try readPool()
        } catch {
            status.error = .storeUnreadable
        }
        return status
    }

    private func brokerConfigured() -> Bool {
        if let url = environment["OMP_AUTH_BROKER_URL"], !url.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        for name in ["config.yml", "config.yaml"] {
            if let text = try? String(contentsOf: agentDir.appendingPathComponent(name), encoding: .utf8) {
                return OMPCredentialExport.brokerConfigured(inConfigYAML: text)
            }
        }
        return false
    }

    private enum StoreError: Error { case open, query }

    /// Identity fields of every active `openai-codex` OAuth row. Token values
    /// are decoded into a transient dictionary and dropped immediately.
    private func readPool() throws -> [OMPPoolEntry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseFile.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw StoreError.open
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let sql = """
            SELECT data FROM auth_credentials
            WHERE provider = ? AND credential_type = 'oauth' AND disabled_cause IS NULL
            ORDER BY id ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, Self.provider, -1, transient)
        var entries: [OMPPoolEntry] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw StoreError.query }
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let data = Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0)))
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            entries.append(
                OMPPoolEntry(email: object["email"] as? String, accountId: object["accountId"] as? String))
        }
        return entries
    }

    // MARK: - Mutations

    /// Adds or refreshes one account in OMP's pool. Re-importing an identity
    /// OMP already has replaces that row (identity-key matching in OMP).
    func connect(name: String, authFile: URL) async throws {
        let omp = try tool()
        guard let data = try? Data(contentsOf: authFile) else { throw OMPSyncError.notLoggedIn(name) }
        guard let document = OMPCredentialExport.importDocument(fromCodexAuth: data) else {
            throw OMPSyncError.exportFailed(name)
        }
        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("codex-\(name).json")
        guard FileManager.default.createFile(atPath: file.path, contents: document, attributes: [.posixPermissions: 0o600])
        else { throw OMPSyncError.importFailed("could not stage the credential") }

        let result = try await runner.run(
            CLIProcessSpec(
                executable: omp,
                arguments: ["auth-broker", "import", staging.path, "--provider=\(Self.provider)", "--json"],
                environment: ompEnvironment(), timeout: .seconds(60)))
        switch OMPCredentialExport.importOutcome(stdout: result.stdout) {
        case .imported where result.succeeded:
            return
        case .imported, .unreadable:
            throw OMPSyncError.importFailed(Self.tail(of: result.stderr) ?? "omp exited with status \(result.exitStatus)")
        case .skipped(let reason), .failed(let reason):
            throw OMPSyncError.importFailed(reason)
        }
    }

    /// Removes one identity from OMP's pool by clearing the provider and
    /// re-importing `keeping`. Refuses when the pool holds rows this app
    /// does not manage, so an OMP-only login is never dropped.
    func disconnect(identity: CodexIdentity, keeping: [(name: String, authFile: URL, identity: CodexIdentity)]) async throws
    {
        let omp = try tool()
        guard !brokerConfigured() else { throw OMPSyncError.brokerConfigured }
        let pool = (try? readPool()) ?? []
        guard pool.contains(where: { $0.key == identity.key }) else { return }
        let managed = Set(keeping.map(\.identity.key) + [identity.key])
        let unmanaged = pool.filter { !managed.contains($0.key) }
        guard unmanaged.isEmpty else {
            throw OMPSyncError.unmanagedCredentials(unmanaged.map { $0.email ?? $0.accountId ?? "unknown" })
        }
        let result = try await runner.run(
            CLIProcessSpec(
                executable: omp, arguments: ["auth-broker", "logout", Self.provider],
                environment: ompEnvironment(), timeout: .seconds(60)))
        guard result.succeeded else { throw OMPSyncError.logoutFailed }
        for account in keeping where pool.contains(where: { $0.key == account.identity.key }) {
            try await connect(name: account.name, authFile: account.authFile)
        }
    }

    // MARK: - Helpers

    private func tool() throws -> URL {
        guard let url = locator.locate(.omp) else { throw OMPSyncError.toolNotFound }
        return url
    }

    private func ompEnvironment() -> [String: String] {
        var env = environment
        env["PATH"] = locator.pathValue
        env["HOME"] = env["HOME"] ?? home.path
        env["NO_COLOR"] = "1"
        return env
    }

    private func makeStagingDirectory() throws -> URL {
        let base = home.appendingPathComponent("Library/Application Support/MeridianBar/CodexAccounts")
        let staging = base.appendingPathComponent(".omp-import-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw OMPSyncError.importFailed("could not create a staging directory")
        }
        return staging
    }

    private static func tail(of data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.split(separator: "\n").last else { return nil }
        return String(last)
    }
}
