import Foundation
import Testing

@testable import MeridianBar

// Fixture mirrors the live capture in okf/01 (verified 2026-08-06,
// Meridian 1.60.0), with generic ids/emails. Extra unknown fields included
// on purpose: decoding must tolerate Meridian minors adding fields.
private let quotaFixture = """
    {
      "profiles": [
        {"id": "jeanpaul", "error": null, "fetchedAt": 1786035002549, "futureField": 1,
         "windows": [
           {"type": "five_hour", "utilization": 0, "resetsAt": 1786040400453},
           {"type": "seven_day", "utilization": 0.91, "resetsAt": 1786064400453},
           {"type": "seven_day_fable", "utilization": 1, "resetsAt": 1786064400453}]},
        {"id": "jeanpnr", "error": null, "fetchedAt": 1786035002884,
         "windows": [
           {"type": "five_hour", "utilization": 0, "resetsAt": 1786036799726},
           {"type": "seven_day", "utilization": 0.52, "resetsAt": 1786366799726},
           {"type": "seven_day_fable", "utilization": 1, "resetsAt": 1786366799727}]},
        {"id": "jean_reinhold", "error": null, "fetchedAt": 1786035002893,
         "windows": [
           {"type": "five_hour", "utilization": 0.04, "resetsAt": 1786051200795},
           {"type": "seven_day", "utilization": 0.32, "resetsAt": 1786269600000},
           {"type": "seven_day_fable", "utilization": 0.34, "resetsAt": 1786269600000}]}
      ]
    }
    """

private let profilesFixture = """
    {
      "profiles": [
        {"id": "jeanpaul", "type": "claude-max", "isActive": true, "email": "a@example.com",
         "subscriptionType": "max", "loggedIn": true},
        {"id": "jeanpnr", "type": "claude-max", "isActive": false, "email": "b@example.com",
         "subscriptionType": "max", "loggedIn": true},
        {"id": "jean_reinhold", "type": "claude-max", "isActive": false, "email": "c@example.com",
         "subscriptionType": "max", "loggedIn": true}
      ],
      "activeProfile": "jeanpaul",
      "routing": "priority",
      "profileOrder": ["jean_reinhold", "jeanpaul", "jeanpnr"],
      "exhausted": []
    }
    """

private func decodeFixtures() throws -> (QuotaAll, ProfilesList) {
    let quota = try JSONDecoder().decode(QuotaAll.self, from: Data(quotaFixture.utf8))
    let profiles = try JSONDecoder().decode(ProfilesList.self, from: Data(profilesFixture.utf8))
    return (quota, profiles)
}

@Suite struct StatusThresholds {
    @Test func meridianThresholds() {
        #expect(UsageLogic.status(utilization: nil) == .ok)
        #expect(UsageLogic.status(utilization: 0.59) == .ok)
        #expect(UsageLogic.status(utilization: 0.6) == .warn)
        #expect(UsageLogic.status(utilization: 0.85) == .critical)
        #expect(UsageLogic.status(utilization: 1.0) == .blocked)
    }

    @Test func percentClampsAndRounds() {
        #expect(UsageLogic.percent(0.91) == 91)
        #expect(UsageLogic.percent(1.2) == 100)
        #expect(UsageLogic.percent(-0.1) == 0)
        #expect(UsageLogic.percent(nil) == nil)
    }
}

@Suite struct WindowLabels {
    @Test func knownAndFallback() {
        #expect(UsageLogic.windowLabel("seven_day_fable") == "7d Fable")
        #expect(UsageLogic.windowLabel("five_hour") == "5h")
        // Unknown types must render, never crash or show raw snake_case.
        #expect(UsageLogic.windowLabel("seven_day_omelette") == "Seven Day Omelette")
    }
}

@Suite struct Aliases {
    @Test func stripsCommonPrefix() {
        let a = UsageLogic.aliases(for: ["jeanpaul", "jeanpnr", "jean_reinhold"])
        #expect(a["jeanpaul"] == "paul")
        #expect(a["jeanpnr"] == "pnr")
        #expect(a["jean_reinhold"] == "rein")
    }

    @Test func singleProfileKeepsOwnName() {
        #expect(UsageLogic.aliases(for: ["work"]) == ["work": "work"])
    }

    @Test func emptyRestFallsBackToFullId() {
        // First id is entirely a prefix of the second.
        let a = UsageLogic.aliases(for: ["team", "teammate"])
        #expect(a["team"]?.isEmpty == false)
        #expect(a["teammate"]?.isEmpty == false)
        #expect(a["team"] != a["teammate"])
    }
}

@Suite struct ResetCountdown {
    let now = Date(timeIntervalSince1970: 1_786_035_000)

    private func at(secondsAhead: Double) -> Double {
        (now.timeIntervalSince1970 + secondsAhead) * 1000
    }

    @Test func formats() {
        #expect(UsageLogic.resetCountdown(resetsAtMs: at(secondsAhead: 30 * 60), now: now) == "in 30m")
        #expect(
            UsageLogic.resetCountdown(resetsAtMs: at(secondsAhead: 8 * 3600 + 5 * 60), now: now)
                == "in 8h 05m")
        #expect(
            UsageLogic.resetCountdown(resetsAtMs: at(secondsAhead: 50 * 3600), now: now)
                == "in 2d 2h")
        #expect(UsageLogic.resetCountdown(resetsAtMs: at(secondsAhead: -5), now: now) == "resetting…")
        #expect(UsageLogic.resetCountdown(resetsAtMs: nil, now: now) == nil)
    }
}

@Suite struct Segments {
    @Test func fablePrimaryWorstColorProfileOrder() throws {
        let (quota, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(quota: quota, profiles: profiles)

        // Meridian's profileOrder wins, not the profiles array order.
        #expect(segs.map(\.id) == ["jean_reinhold", "jeanpaul", "jeanpnr"])

        let byId = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0) })
        // Number = 7d Fable (owner decision), color = worst window.
        #expect(byId["jeanpaul"]?.percent == 100)
        #expect(byId["jeanpaul"]?.status == .blocked)
        #expect(byId["jean_reinhold"]?.percent == 34)
        #expect(byId["jean_reinhold"]?.status == .ok)
        #expect(byId["jeanpaul"]?.isActive == true)
        #expect(byId["jeanpnr"]?.isActive == false)
    }

    @Test func missingPrimaryFallsBackToWorst() throws {
        var (quota, profiles) = try decodeFixtures()
        // Strip fable windows: number must fall back to the worst window.
        quota.profiles = quota.profiles.map { p in
            var p = p
            p.windows = p.windows?.filter { $0.type != "seven_day_fable" }
            return p
        }
        let segs = UsageLogic.segments(quota: quota, profiles: profiles)
        let paul = segs.first { $0.id == "jeanpaul" }
        #expect(paul?.percent == 91)
        #expect(paul?.status == .critical)
    }

    @Test func exhaustedForcesBlocked() throws {
        let (quota, profiles) = try decodeFixtures()
        var p = profiles
        p.exhausted = ["jean_reinhold"]
        let segs = UsageLogic.segments(quota: quota, profiles: p)
        #expect(segs.first { $0.id == "jean_reinhold" }?.status == .blocked)
    }

    @Test func noDataStillListsProfiles() throws {
        let (_, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(quota: nil, profiles: profiles)
        #expect(segs.count == 3)
        #expect(segs.allSatisfy { $0.percent == nil && $0.status == .ok })
    }
}
