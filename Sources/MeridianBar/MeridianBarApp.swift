import SwiftUI

@main
struct MeridianBarApp: App {
    @State private var store: UsageStore

    init() {
        PreviewRenderer.runIfRequested()
        let store = UsageStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(store: store)
        } label: {
            Image(nsImage: MenuBarLabel.render(
                segments: store.segments, offline: store.offline, style: store.labelStyle
            ))
            .help("Claude \(UsageLogic.windowLabel(store.primaryWindow)) usage. Weekly arrows: ↑ room to use more, → on pace, ↓ ahead. Colors warn about the worst quota window.")
            .accessibilityLabel("Claude \(UsageLogic.windowLabel(store.primaryWindow)) usage. " + store.segments.map {
                "\($0.alias): \($0.percent.map { "\($0) percent" } ?? "unknown"). \($0.weeklyPace?.direction.label ?? "")"
            }.joined(separator: " "))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
