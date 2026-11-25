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
    @Test func weeklyUsageIsDistinctFromModelCaps() throws {
        let (quota, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(quota: quota, profiles: profiles, primaryWindow: "seven_day")

        // Meridian's profileOrder wins, not the profiles array order.
        #expect(segs.map(\.id) == ["jean_reinhold", "jeanpaul", "jeanpnr"])

        let byId = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0) })
        #expect(byId["jeanpaul"]?.percent == 91)
        #expect(byId["jeanpaul"]?.status == .blocked)
        #expect(byId["jean_reinhold"]?.percent == 32)
        #expect(byId["jean_reinhold"]?.status == .ok)
        #expect(byId["jeanpaul"]?.isActive == true)
        #expect(byId["jeanpnr"]?.isActive == false)
    }

    @Test func missingWeeklyQuotaNeverShowsFableAsWeeklyUsage() throws {
        var (quota, profiles) = try decodeFixtures()
        quota.profiles = quota.profiles.map { p in
            var p = p
            p.windows = p.windows?.filter { $0.type != "seven_day" }
            return p
        }
        let segs = UsageLogic.segments(quota: quota, profiles: profiles, primaryWindow: "seven_day")
        let paul = segs.first { $0.id == "jeanpaul" }
        #expect(paul?.percent == nil)
        #expect(paul?.weeklyPace == nil)
        #expect(paul?.status == .blocked)
    }

    @Test func exhaustedForcesBlocked() throws {
        let (quota, profiles) = try decodeFixtures()
        var p = profiles
        p.exhausted = [.init(id: "jean_reinhold")]
        let segs = UsageLogic.segments(quota: quota, profiles: p)
        #expect(segs.first { $0.id == "jean_reinhold" }?.status == .blocked)
    }

    @Test func noDataStillListsProfiles() throws {
        let (_, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(quota: nil, profiles: profiles)
        #expect(segs.count == 3)
        #expect(segs.allSatisfy { $0.percent == nil && $0.status == .ok })
    }

    @Test func missingTokenShowsLoginEvenWhenProfileClaimsLoggedIn() throws {
        let quota = QuotaAll(profiles: [
            ProfileQuota(id: "work", error: "no_token", windows: []),
            ProfileQuota(id: "home", windows: [QuotaWindow(type: "five_hour", utilization: 0)])
        ])
        let profiles = ProfilesList(profiles: [
            ProfileInfo(id: "work", loggedIn: true), ProfileInfo(id: "home", loggedIn: true)
        ])
        let segments = UsageLogic.segments(quota: quota, profiles: profiles)
        let missing = try #require(segments.first { $0.id == "work" })
        #expect(missing.needsLogin)
        #expect(missing.percent == nil)
        let label = MenuBarLabel.attributedText(segments: segments, offline: false).string
        #expect(label.contains("work login"))
    }

    @Test func signedOutProfileShowsLoginWithoutQuotaError() throws {
        let profiles = ProfilesList(profiles: [ProfileInfo(id: "work", loggedIn: false)])
        let segment = try #require(UsageLogic.segments(quota: nil, profiles: profiles).first)
        #expect(segment.needsLogin)
        #expect(MenuBarLabel.attributedText(
            segments: [segment], offline: false, style: .worst).string == "work login")
    }
}

@Suite struct FableRoute {
    @Test func marksOnlyTheFableRouteWithItsFablePercent() throws {
        let (quota, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(
            quota: quota, profiles: profiles, primaryWindow: "seven_day", fableProfile: "jean_reinhold")
        let byId = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0) })
        #expect(byId["jean_reinhold"]?.servesFable == true)
        #expect(byId["jean_reinhold"]?.fablePercent == 34)
        // The primary window still drives the main percent.
        #expect(byId["jean_reinhold"]?.percent == 32)
        #expect(segs.filter(\.servesFable).map(\.id) == ["jean_reinhold"])
        #expect(byId["jeanpaul"]?.fablePercent == nil)
    }

    @Test func missingFableWindowLeavesPercentUnknown() throws {
        let quota = QuotaAll(profiles: [
            ProfileQuota(id: "work", windows: [QuotaWindow(type: "seven_day", utilization: 0.2)])
        ])
        let segment = try #require(
            UsageLogic.segments(quota: quota, profiles: nil, fableProfile: "work").first)
        #expect(segment.servesFable)
        #expect(segment.fablePercent == nil)
        #expect(MenuBarLabel.attributedText(segments: [segment], offline: false).string.hasSuffix(" F–"))
    }

    @Test func noRouteMarksNothing() throws {
        let (quota, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(quota: quota, profiles: profiles, fableProfile: nil)
        #expect(segs.allSatisfy { !$0.servesFable && $0.fablePercent == nil })
    }

    @Test func labelShowsFableSuffixOnlyInSegmentsStyle() throws {
        let quota = QuotaAll(profiles: [
            ProfileQuota(id: "work", windows: [
                QuotaWindow(type: "seven_day", utilization: 0.34),
                QuotaWindow(type: "seven_day_fable", utilization: 0.67),
            ])
        ])
        let segments = UsageLogic.segments(quota: quota, profiles: nil, fableProfile: "work")
        let label = MenuBarLabel.attributedText(segments: segments, offline: false).string
        #expect(label.contains("work 34%"))
        #expect(label.hasSuffix(" F67%"))
        let worst = MenuBarLabel.attributedText(segments: segments, offline: false, style: .worst).string
        #expect(!worst.contains("F67%"))
        #expect(worst == "work 34%")
    }
}

@Suite struct ExhaustedDecoding {
    // Meridian 1.60.0 sends objects; captures ≤2026-08-06 sent bare id
    // strings (okf/01) — both must decode.
    @Test func objectAndLegacyStringShapes() throws {
        let json = """
            {"profiles": [], "exhausted": [
              {"id": "jean_reinhold", "until": 1786122000000, "reason": "rate_limit_error"},
              "jeanpnr"
            ]}
            """
        let list = try JSONDecoder().decode(ProfilesList.self, from: Data(json.utf8))
        #expect(list.exhausted?.map(\.id) == ["jean_reinhold", "jeanpnr"])
        #expect(list.exhausted?.first?.until == 1_786_122_000_000)
        #expect(list.exhausted?.first?.reason == "rate_limit_error")
    }
}

@Suite struct Transitions {
    private func t(_ pairs: [(String, UsageStatus, UsageStatus)]) -> [UsageTransition] {
        var old: [String: UsageStatus] = [:]
        var new: [String: UsageStatus] = [:]
        for (key, from, to) in pairs {
            old[key] = from
            new[key] = to
        }
        return UsageLogic.transitions(from: old, to: new)
    }

    @Test func escalationsFire() {
        let out = t([("p|seven_day", .ok, .critical), ("p|five_hour", .warn, .blocked)])
        #expect(out.count == 2)
    }

    @Test func recoveryFromBlockedFires() {
        let out = t([("p|seven_day_fable", .blocked, .ok)])
        #expect(
            out == [
                UsageTransition(
                    profileId: "p", windowType: "seven_day_fable", from: .blocked, to: .ok)
            ])
    }

    @Test func noiseDoesNotFire() {
        // Unchanged, de-escalation short of recovery, and keys with no history.
        #expect(t([("p|a", .warn, .warn)]).isEmpty)
        #expect(t([("p|a", .critical, .warn)]).isEmpty)
        #expect(t([("p|a", .blocked, .critical)]).isEmpty)
        #expect(UsageLogic.transitions(from: [:], to: ["p|a": .blocked]).isEmpty)
    }

}

@Suite struct AliasOverrides {
    @Test func overrideWinsAndEmptyIsIgnored() throws {
        let (quota, profiles) = try decodeFixtures()
        let segs = UsageLogic.segments(
            quota: quota, profiles: profiles,
            aliasOverrides: ["jeanpaul": "work", "jeanpnr": ""]
        )
        let byId = Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0.alias) })
        #expect(byId["jeanpaul"] == "work")
        #expect(byId["jeanpnr"] == "pnr")
    }
}


@Suite struct CodexSegments {
    @Test func mainWindowLeadsButReviewLimitStillBlocks() {
        let segment = UsageLogic.codexSegment(windows: [
            QuotaWindow(type: "primary", utilization: 0.12),
            QuotaWindow(type: "review", utilization: 1),
        ])
        #expect(segment.percent == 12)
        #expect(segment.status == .blocked)
    }

    @Test func missingQuotaIsNotZeroUsage() {
        #expect(UsageLogic.codexSegment(windows: []).percent == nil)
        #expect(UsageLogic.codexSegment(windows: [
            QuotaWindow(type: "primary", utilization: 0)
        ]).percent == 0)
    }

    @Test func codexRemainsVisibleWhenMeridianIsOffline() {
        let codex = UsageLogic.codexSegment(windows: [
            QuotaWindow(type: "primary", utilization: 0.35)
        ])
        let text = MenuBarLabel.attributedText(segments: [], offline: true, codex: codex).string
        #expect(text.contains("meridian"))
        #expect(text.contains("Codex 35%"))
    }
}

@Suite struct WeeklyBudget {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ used: Double?, days: Double?) -> QuotaWindow {
        QuotaWindow(
            type: "seven_day", utilization: used,
            resetsAt: days.map { (now.timeIntervalSince1970 + $0 * 86_400) * 1000 })
    }

    @Test func sameUsageNeedsDifferentPaceAsResetApproaches() throws {
        let early = try #require(UsageLogic.weeklyPace(windows: [window(0.5, days: 6)], now: now))
        let middle = try #require(UsageLogic.weeklyPace(windows: [window(0.5, days: 3.5)], now: now))
        let late = try #require(UsageLogic.weeklyPace(windows: [window(0.5, days: 1)], now: now))
        #expect(early.direction == .ahead)
        #expect(middle.direction == .onPace)
        #expect(late.direction == .useMore)
        #expect(abs(middle.percentagePointsPerDay - 100 / 7.0) < 0.0001)
        #expect(late.percentagePointsPerDay == 50)
    }

    @Test func finalHoursBudgetOnlyTheUnusedQuota() throws {
        let pace = try #require(UsageLogic.weeklyPace(windows: [window(0.75, days: 0.25)], now: now))
        #expect(abs(pace.percentagePointsPerHour - 25 / 6.0) < 0.0001)
        #expect(pace.direction == .useMore)
        let exhausted = try #require(UsageLogic.weeklyPace(windows: [window(1, days: 2)], now: now))
        #expect(exhausted.direction == .exhausted)
        #expect(exhausted.percentagePointsPerDay == 0)
    }

    @Test func fivePointToleranceDoesNotEncourageUnnecessaryChanges() throws {
        for used in [0.46, 0.5, 0.54] {
            let pace = try #require(UsageLogic.weeklyPace(windows: [window(used, days: 3.5)], now: now))
            #expect(pace.direction == .onPace)
        }
    }

    @Test func missingExpiredAndInvalidDataHasNoBudget() {
        for days: Double? in [nil, 0, -1, 8, .infinity, .nan] {
            #expect(UsageLogic.weeklyPace(windows: [window(0.4, days: days)], now: now) == nil)
        }
        for used: Double? in [nil, -0.1, 1.1, .infinity, .nan] {
            #expect(UsageLogic.weeklyPace(windows: [window(used, days: 2)], now: now) == nil)
        }
        #expect(UsageLogic.weeklyPace(
            windows: [QuotaWindow(type: "seven_day_fable", utilization: 0.5,
                                  resetsAt: window(0.5, days: 2).resetsAt)], now: now) == nil)
    }

    @Test func cachedQuotaDoesNotAdvertiseCurrentPaceInBar() throws {
        let quota = QuotaAll(profiles: [
            ProfileQuota(id: "fresh", windows: [window(0.2, days: 1)]),
            ProfileQuota(id: "cached", windows: [window(0.2, days: 1)], stale: true),
            ProfileQuota(id: "failed", error: "no_token", windows: [window(0.2, days: 1)])
        ])
        let segments = UsageLogic.segments(quota: quota, profiles: nil, primaryWindow: "seven_day", now: now)
        #expect(segments.first { $0.id == "fresh" }?.weeklyPace?.direction == .useMore)
        #expect(segments.first { $0.id == "cached" }?.weeklyPace == nil)
        #expect(segments.first { $0.id == "failed" }?.weeklyPace == nil)
        #expect(segments.first { $0.id == "cached" }?.percent == 20)
    }
}
