import Foundation
import Testing

@testable import MeridianBar

// Fixtures mirror the live captures in okf/01 (Meridian 1.60.0), redacted.

private let quotaAllJSON = """
    {"profiles":[
      {"id":"jeanpaul","error":null,"fetchedAt":1786035002549,"windows":[
        {"type":"five_hour","utilization":0,"resetsAt":1786040400453},
        {"type":"seven_day","utilization":0.91,"resetsAt":1786064400453},
        {"type":"seven_day_fable","utilization":1,"resetsAt":1786064400453}]},
      {"id":"jeanpnr","error":null,"fetchedAt":1786035002884,"windows":[
        {"type":"five_hour","utilization":0,"resetsAt":1786036799726},
        {"type":"seven_day","utilization":0.52,"resetsAt":1786366799726}]},
      {"id":"jean_reinhold","error":null,"fetchedAt":1786035002893,"windows":[
        {"type":"five_hour","utilization":0.04,"resetsAt":1786051200795},
        {"type":"seven_day","utilization":0.32,"resetsAt":1786269600000},
        {"type":"seven_day_fable","utilization":0.34,"resetsAt":1786269600000}]}
    ]}
    """

private let profilesListJSON = """
    {"profiles":[
      {"id":"jeanpaul","type":"claude-max","isActive":true,"email":"a@example.com","subscriptionType":"max","loggedIn":true},
      {"id":"jeanpnr","type":"claude-max","isActive":false,"email":"b@example.com","subscriptionType":"max","loggedIn":true},
      {"id":"jean_reinhold","type":"claude-max","isActive":false,"email":"c@example.com","subscriptionType":"max","loggedIn":true}],
     "activeProfile":"jeanpaul","routing":"priority",
     "profileOrder":["jean_reinhold","jeanpaul","jeanpnr"],"exhausted":[]}
    """

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@Suite struct StatusThresholds {
    @Test func meridianThresholds() {
        #expect(UsageLogic.status(utilization: nil) == .ok)
        #expect(UsageLogic.status(utilization: 0) == .ok)
        #expect(UsageLogic.status(utilization: 0.59) == .ok)
        #expect(UsageLogic.status(utilization: 0.60) == .warn)
        #expect(UsageLogic.status(utilization: 0.849) == .warn)
        #expect(UsageLogic.status(utilization: 0.85) == .critical)
        #expect(UsageLogic.status(utilization: 0.99) == .critical)
        #expect(UsageLogic.status(utilization: 1.0) == .blocked)
    }
}

@Suite struct WindowLabels {
    @Test func knownAndFallback() {
        #expect(UsageLogic.windowLabel("five_hour") == "5h")
        #expect(UsageLogic.windowLabel("seven_day_fable") == "7d Fable")
        // Unknown types must render, never crash or vanish (okf/01).
        #expect(UsageLogic.windowLabel("seven_day_omelette") == "Seven Day Omelette")
    }
}

@Suite struct Aliases {
    @Test func stripsCommonPrefix() {
        let map = UsageLogic.aliases(for: ["jeanpaul", "jeanpnr", "jean_reinhold"])
        #expect(map["jeanpaul"] == "paul")
        #expect(map["jeanpnr"] == "pnr")
        #expect(map["jean_reinhold"] == "rein")
    }

    @Test func singleProfileKeepsName() {
        #expect(UsageLogic.aliases(for: ["work"])["work"] == "work")
    }

    @Test func collisionsStayUnique() {
        let map = UsageLogic.aliases(for: ["longname_a", "longname_b", "other"])
        #expect(Set(map.values).count == 3)
    }
}

@Suite struct Countdown {
    @Test func formats() {
        let now = Date(timeIntervalSince1970: 1_786_035_000)
        func at(_ seconds: Double) -> Double { (1_786_035_000 + seconds) * 1000 }
        #expect(UsageLogic.resetCountdown(resetsAtMs: at(8 * 3600 + 5 * 60), now: now) == "in 8h 05m")
        #expect(UsageLogic.resetCountdown(resetsAtMs: at(25 * 3600), now: now) == "in 1d 1h")
        #expect(UsageLogic.resetCountdown(resetsAtMs: at(120), now: now) == "in 2m")
        #expect(UsageLogic.resetCountdown(resetsAtMs: at(-5), now: now) == "resetting…")
        #expect(UsageLogic.resetCountdown(resetsAtMs: nil, now: now) == nil)
    }
}

@Suite struct Percent {
    @Test func roundsAndClamps() {
        #expect(UsageLogic.percent(0.91) == 91)
        #expect(UsageLogic.percent(1.0) == 100)
        #expect(UsageLogic.percent(1.2) == 100)
        #expect(UsageLogic.percent(nil) == nil)
    }
}

@Suite struct Segments {
    @Test func liveShapeEndToEnd() throws {
        let quota: QuotaAll = try decode(quotaAllJSON)
        let profiles: ProfilesList = try decode(profilesListJSON)
        let segs = UsageLogic.segments(quota: quota, profiles: profiles)

        // Meridian's profileOrder wins.
        #expect(segs.map(\.id) == ["jean_reinhold", "jeanpaul", "jeanpnr"])

        let byId = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0) })
        // Primary window (7d Fable) leads the number; color is worst-window.
        #expect(byId["jeanpaul"]?.percent == 100)
        #expect(byId["jeanpaul"]?.status == .blocked)
        #expect(byId["jean_reinhold"]?.percent == 34)
        #expect(byId["jean_reinhold"]?.status == .ok)
        // No fable window → falls back to the worst window.
        #expect(byId["jeanpnr"]?.percent == 52)
        #expect(byId["jeanpnr"]?.status == .ok)
        // Active profile flagged.
        #expect(byId["jeanpaul"]?.isActive == true)
        #expect(byId["jean_reinhold"]?.isActive == false)
    }

    @Test func exhaustedOverridesStatus() throws {
        let quota: QuotaAll = try decode(quotaAllJSON)
        var profiles: ProfilesList = try decode(profilesListJSON)
        profiles.exhausted = ["jeanpnr"]
        let segs = UsageLogic.segments(quota: quota, profiles: profiles)
        #expect(segs.first { $0.id == "jeanpnr" }?.status == .blocked)
    }

    @Test func quotaWithoutProfilesStillRenders() throws {
        let quota: QuotaAll = try decode(quotaAllJSON)
        let segs = UsageLogic.segments(quota: quota, profiles: nil)
        #expect(segs.count == 3)
        #expect(segs.allSatisfy { !$0.alias.isEmpty })
    }
}

@Suite struct Decoding {
    @Test func healthToleratesExtraFields() throws {
        let health: Health = try decode(
            """
            {"status":"healthy","version":"1.60.0","mode":"internal",
             "auth":{"loggedIn":true,"email":"x@example.com","subscriptionType":"max",
                     "renewalRequiredSoon":false,"unknownField":1}}
            """)
        #expect(health.status == "healthy")
        #expect(health.auth?.renewalRequiredSoon == false)
    }
}
