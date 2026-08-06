import Foundation

// Response models for the Meridian surface documented in okf/01.
// Everything except ids is optional: Meridian minors may add/drop fields
// and a partial decode must never take the app down.

struct QuotaWindow: Codable, Equatable, Sendable {
    var type: String
    var utilization: Double?
    var resetsAt: Double?
}

struct ExtraUsage: Codable, Equatable, Sendable {
    var isEnabled: Bool?
    var monthlyLimit: Double?
    var usedCredits: Double?
    var utilization: Double?
    var currency: String?
}

struct ProfileQuota: Codable, Equatable, Sendable {
    var id: String
    var error: String?
    var fetchedAt: Double?
    var windows: [QuotaWindow]?
    var extraUsage: ExtraUsage?
}

struct QuotaAll: Codable, Equatable, Sendable {
    var profiles: [ProfileQuota]
}

struct ProfileInfo: Codable, Equatable, Sendable {
    var id: String
    var type: String?
    var isActive: Bool?
    var email: String?
    var subscriptionType: String?
    var loggedIn: Bool?
    var lastSuccessAt: Double?
}

struct ProfilesList: Codable, Equatable, Sendable {
    var profiles: [ProfileInfo]
    var activeProfile: String?
    var routing: String?
    var profileOrder: [String]?
    var exhausted: [String]?
}

struct HealthAuth: Codable, Equatable, Sendable {
    var loggedIn: Bool?
    var email: String?
    var subscriptionType: String?
    var renewalRequiredSoon: Bool?
    var daysUntilRenewal: Double?
}

struct Health: Codable, Equatable, Sendable {
    var status: String?
    var version: String?
    var auth: HealthAuth?
}

enum MeridianError: Error {
    case badStatus(Int)
}

struct MeridianClient: Sendable {
    let baseURL: URL
    private let session: URLSession

    static let defaultBaseURL = URL(string: "http://127.0.0.1:3456")!

    init(baseURL: URL) {
        self.baseURL = baseURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: cfg)
    }

    static func configured() -> MeridianClient {
        let raw = UserDefaults.standard.string(forKey: "baseURL")
        let url = raw.flatMap(URL.init(string:)) ?? defaultBaseURL
        return MeridianClient(baseURL: url)
    }

    func quotaAll() async throws -> QuotaAll { try await get("v1/usage/quota/all") }
    func profilesList() async throws -> ProfilesList { try await get("profiles/list") }
    func health() async throws -> Health { try await get("health") }

    func switchProfile(_ id: String) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("profiles/active"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["profile": id])
        let (_, resp) = try await session.data(for: req)
        try Self.check(resp)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, resp) = try await session.data(from: baseURL.appendingPathComponent(path))
        try Self.check(resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MeridianError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}
