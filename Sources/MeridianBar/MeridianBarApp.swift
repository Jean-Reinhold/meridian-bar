import SwiftUI

@main
struct MeridianBarApp: App {
    @State private var store: UsageStore

    init() {
        let store = UsageStore()
        store.start()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            UsageMenuView(store: store)
        } label: {
            Image(nsImage: MenuBarLabel.render(segments: store.segments, offline: store.offline))
        }
        .menuBarExtraStyle(.window)
    }
}
