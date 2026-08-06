import Foundation
import UserNotifications

/// Threshold notifications (F11): one notification per status transition,
/// never repeated — dedupe falls out of diffing consecutive snapshots.
@MainActor
final class UsageNotifier {
    private var last: [String: UsageStatus] = [:]

    func process(quota: QuotaAll?) {
        let now = UsageLogic.statuses(quota: quota)
        let previous = last
        last = now
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"),
            Bundle.main.bundleIdentifier != nil,  // UNUserNotificationCenter needs a real bundle
            !previous.isEmpty
        else { return }
        let transitions = UsageLogic.transitions(from: previous, to: now)
        guard !transitions.isEmpty else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) {
            granted, _ in
            guard granted else { return }
            let center = UNUserNotificationCenter.current()
            for t in transitions {
                let content = UNMutableNotificationContent()
                content.title = "MeridianBar — \(t.profileId)"
                content.body = Self.message(for: t)
                center.add(
                    UNNotificationRequest(
                        identifier: "\(t.profileId)|\(t.windowType)|\(t.to.rawValue)",
                        content: content, trigger: nil
                    ))
            }
        }
    }

    nonisolated static func message(for t: UsageTransition) -> String {
        let window = UsageLogic.windowLabel(t.windowType)
        switch t.to {
        case .blocked: return "\(window) window exhausted — requests will be rejected."
        case .critical: return "\(window) window above 85%."
        case .warn:
            return t.from == .blocked
                ? "\(window) window reset — usable again."
                : "\(window) window above 60%."
        case .ok: return "\(window) window reset — usable again."
        }
    }
}
