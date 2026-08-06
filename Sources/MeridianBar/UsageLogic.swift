import Foundation

// Pure, unit-tested logic — no I/O, no UI. Everything the label and the
// dropdown compute lives here (okf/04 §3).

enum UsageStatus: Int, Comparable, Sendable {
    case ok = 0
    case warn = 1
    case critical = 2
    case blocked = 3

    static func < (lhs: UsageStatus, rhs: UsageStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProfileSegment: Equatable, Sendable {
    var id: String
    var alias: String
    /// Primary-window utilization percent (0–100); nil when no data.
    var percent: Int?
    /// Worst status across ALL windows — drives color (okf/02 §1).
    var status: UsageStatus
    var isActive: Bool
}

enum UsageLogic {
    /// Meridian's own thresholds (okf/01): warn ≥ 0.6, critical ≥ 0.85.
    static func status(utilization: Double?) -> UsageStatus {
        guard let u = utilization, u.isFinite else { return .ok }
        if u >= 1.0 { return .blocked }
        if u >= 0.85 { return .critical }
        if u >= 0.6 { return .warn }
        return .ok
    }

    /// Owner decision: the 7d Fable window leads wherever one number is shown.
    static let defaultPrimaryWindow = "seven_day_fable"

    static let windowLabels: [String: String] = [
        "five_hour": "5h",
        "seven_day": "7d",
        "seven_day_opus": "7d Opus",
        "seven_day_sonnet": "7d Sonnet",
        "seven_day_fable": "7d Fable",
        "seven_day_oauth_apps": "7d Apps",
        "seven_day_cowork": "7d Cowork",
    ]

    static func windowLabel(_ type: String) -> String {
        if let known = windowLabels[type] { return known }
        return type.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Short display aliases: strip the longest common prefix shared by all
    /// ids (min 3 chars, only when there are 2+ profiles), trim separators,
    /// cap at 4 chars, extend on collision. "jeanpaul/jeanpnr/jean_reinhold"
    /// → "paul/pnr/rein".
    static func aliases(for ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var prefix = ids.count > 1 ? commonPrefix(ids) : ""
        if prefix.count < 3 { prefix = "" }
        var result: [String: String] = [:]
        var used: Set<String> = []
        for id in ids {
            var rest = String(id.dropFirst(prefix.count))
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
            if rest.isEmpty { rest = id }
            var alias = String(rest.lowercased().prefix(4))
            var len = 5
            while used.contains(alias), alias.count < rest.count {
                alias = String(rest.lowercased().prefix(len))
                len += 1
            }
            used.insert(alias)
            result[id] = alias
        }
        return result
    }

    private static func commonPrefix(_ ids: [String]) -> String {
        guard var prefix = ids.first else { return "" }
        for id in ids.dropFirst() {
            prefix = String(prefix.commonPrefix(with: id))
            if prefix.isEmpty { break }
        }
        return prefix
    }

    /// "in 8h 05m" / "in 3d 2h" / "resetting…"; nil for missing input.
    static func resetCountdown(resetsAtMs: Double?, now: Date = Date()) -> String? {
        guard let ms = resetsAtMs, ms.isFinite else { return nil }
        let seconds = ms / 1000 - now.timeIntervalSince1970
        if seconds <= 0 { return "resetting…" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "in \(max(1, minutes))m" }
        let hours = minutes / 60
        let remMin = minutes % 60
        if hours < 24 {
            return remMin > 0
                ? String(format: "in %dh %02dm", hours, remMin)
                : "in \(hours)h"
        }
        let days = hours / 24
        let remHr = hours % 24
        return remHr > 0 ? "in \(days)d \(remHr)h" : "in \(days)d"
    }

    static func percent(_ utilization: Double?) -> Int? {
        guard let u = utilization, u.isFinite else { return nil }
        return Int((min(max(u, 0), 1) * 100).rounded())
    }

    /// One segment per profile, in Meridian's profileOrder. The number is the
    /// primary window (fallback: worst window); the color is always the worst
    /// window (okf/02 §1).
    static func segments(
        quota: QuotaAll?,
        profiles: ProfilesList?,
        primaryWindow: String = defaultPrimaryWindow,
        aliasOverrides: [String: String] = [:]
    ) -> [ProfileSegment] {
        let quotaById = Dictionary(
            uniqueKeysWithValues: (quota?.profiles ?? []).map { ($0.id, $0) }
        )
        let listed = profiles?.profiles.map(\.id) ?? []
        let order = (profiles?.profileOrder ?? []).filter { listed.contains($0) || quotaById[$0] != nil }
        var ids = order.isEmpty ? (listed.isEmpty ? Array(quotaById.keys).sorted() : listed) : order
        for id in listed where !ids.contains(id) { ids.append(id) }
        let aliasMap = aliases(for: ids).merging(
            aliasOverrides.filter { !$0.value.isEmpty }
        ) { _, override in override }
        let exhausted = Set(profiles?.exhausted ?? [])
        let active = profiles?.activeProfile

        return ids.map { id in
            let windows = quotaById[id]?.windows ?? []
            let primary = windows.first { $0.type == primaryWindow }?.utilization
            let worstUtil = windows.compactMap(\.utilization).max()
            var worstStatus = windows.map { status(utilization: $0.utilization) }.max()
                ?? UsageStatus.ok
            if exhausted.contains(id) { worstStatus = .blocked }
            return ProfileSegment(
                id: id,
                alias: aliasMap[id] ?? String(id.prefix(4)),
                percent: percent(primary ?? worstUtil),
                status: worstStatus,
                isActive: id == active
            )
        }
    }

    /// Flat "profileId|windowType" → status map for notification diffing.
    static func statuses(quota: QuotaAll?) -> [String: UsageStatus] {
        var out: [String: UsageStatus] = [:]
        for p in quota?.profiles ?? [] {
            for w in p.windows ?? [] {
                out["\(p.id)|\(w.type)"] = status(utilization: w.utilization)
            }
        }
        return out
    }

    /// Transitions worth a user notification (F11): escalations into
    /// warn/critical/blocked, and recovery out of blocked. Keys absent on
    /// either side are ignored — no startup or profile-add spam.
    static func transitions(
        from old: [String: UsageStatus], to new: [String: UsageStatus]
    ) -> [UsageTransition] {
        var out: [UsageTransition] = []
        for (key, to) in new {
            guard let from = old[key], from != to else { continue }
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let escalated = to > from && to >= .warn
            let recovered = from == .blocked && to <= .warn
            if escalated || recovered {
                out.append(UsageTransition(
                    profileId: String(parts[0]), windowType: String(parts[1]),
                    from: from, to: to
                ))
            }
        }
        return out.sorted { ($0.profileId, $0.windowType) < ($1.profileId, $1.windowType) }
    }
}

struct UsageTransition: Equatable, Sendable {
    var profileId: String
    var windowType: String
    var from: UsageStatus
    var to: UsageStatus
}

/// Collapsed-label rendering styles (okf/02 §1, F9).
enum LabelStyle: String, CaseIterable, Sendable {
    case segments
    case dots
    case worst
}
