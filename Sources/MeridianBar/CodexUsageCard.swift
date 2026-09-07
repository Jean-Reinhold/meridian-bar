import SwiftUI

struct CodexUsageCard: View {
    let snapshot: CodexUsageSnapshot
    /// Accounts OMP routes GPT requests through; nil when OMP is not usable.
    var ompPoolCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("OpenAI Codex", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                if let plan = snapshot.plan { Badge(text: plan, color: .gray) }
                if !snapshot.isLoggedIn { Badge(text: "SIGN IN", color: .orange) }
            }
            if let email = snapshot.email {
                Text(email).font(.caption).foregroundStyle(.secondary)
            }
            Text("Account-wide quota").font(.caption.bold())
            if let error = snapshot.quotaError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if snapshot.windows.isEmpty {
                Text("Quota unavailable. Manage your login in Accounts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.windows, id: \.type) { window in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(UsageLogic.windowLabel(window.type))
                            .font(.caption)
                            .frame(width: 92, alignment: .leading)
                        UsageBar(
                            value: min(max(window.utilization ?? 0, 0), 1),
                            status: UsageLogic.status(utilization: window.utilization))
                        Text(UsageLogic.percent(window.utilization).map { "\($0)%" } ?? "–")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                    if let countdown = UsageLogic.resetCountdown(resetsAtMs: window.resetsAt) {
                        Text("Resets \(countdown)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .opacity(snapshot.quotaError == nil ? 1 : 0.55)
            }
            if let updated = snapshot.quotaUpdatedAt {
                Text("Quota updated \(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let count = ompPoolCount {
                Text(count == 0
                    ? "OMP has no OpenAI accounts to route through."
                    : "OMP routes GPT requests through \(count) OpenAI account\(count == 1 ? "" : "s").")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Text("Recorded on this Mac").font(.caption.bold())
            if let error = snapshot.localError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.callout)
                Spacer()
                Text(snapshot.today.totalTokens.formatted(.number.notation(.compactName)))
                    .font(.title3.monospacedDigit().bold())
                Text("tokens").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                tokenDetail("Input", value: snapshot.today.inputTokens)
                Spacer()
                tokenDetail("Cached input", value: snapshot.today.cachedInputTokens)
                Spacer()
                tokenDetail("Output", value: snapshot.today.outputTokens)
            }
            Text("Local history: \(snapshot.allTime.totalTokens.formatted(.number.notation(.compactName))) tokens across \(snapshot.sessionCount) sessions. Cached input is included in input.")
                .font(.caption2).foregroundStyle(.secondary)
            if let activity = snapshot.lastActivity {
                Text("Last recorded activity \(activity.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Local session records only, not cloud usage or a billing estimate.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassCard()
    }

    private func tokenDetail(_ title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.secondary)
            Text(value.formatted(.number.notation(.compactName))).monospacedDigit()
        }
        .font(.caption)
    }
}
