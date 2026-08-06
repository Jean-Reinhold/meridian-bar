import SwiftUI

/// Settings window (F10): connection, bar label, profile names,
/// notifications. Values live in UserDefaults; the store re-reads them on
/// every poll, and edits trigger an immediate refresh so the bar updates
/// without waiting for the next cycle.
struct SettingsView: View {
    let store: UsageStore

    @AppStorage("baseURL") private var baseURL = MeridianClient.defaultBaseURL.absoluteString
    @AppStorage("pollInterval") private var pollInterval = 60.0
    @AppStorage("labelStyle") private var labelStyle = LabelStyle.segments.rawValue
    @AppStorage("primaryWindow") private var primaryWindow = UsageLogic.defaultPrimaryWindow
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false

    var body: some View {
        Form {
            Section("Connection") {
                TextField(
                    "Meridian URL", text: $baseURL,
                    prompt: Text(MeridianClient.defaultBaseURL.absoluteString)
                )
                .autocorrectionDisabled()
                Stepper(value: $pollInterval, in: 5...600, step: 5) {
                    Text("Poll every \(Int(pollInterval)) s")
                }
            }

            Section("Menu bar label") {
                Picker("Style", selection: $labelStyle) {
                    Text("Per-account segments").tag(LabelStyle.segments.rawValue)
                    Text("Colored dots").tag(LabelStyle.dots.rawValue)
                    Text("Worst account only").tag(LabelStyle.worst.rawValue)
                }
                Picker("Number shown", selection: $primaryWindow) {
                    ForEach(windowOptions, id: \.self) { type in
                        Text(UsageLogic.windowLabel(type)).tag(type)
                    }
                }
                Text("The color always tracks each account's worst window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Profile names in the bar") {
                if profileIds.isEmpty {
                    Text("No profiles yet — names appear once Meridian responds.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profileIds, id: \.self) { id in
                    TextField(id, text: aliasBinding(id), prompt: Text(autoAliases[id] ?? id))
                }
            }

            Section("Notifications") {
                Toggle("Notify on threshold crossings and resets", isOn: $notificationsEnabled)
                Text("Fires once per transition: above 60%, above 85%, exhausted, and reset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: baseURL) { refresh() }
        .onChange(of: labelStyle) { refresh() }
        .onChange(of: primaryWindow) { refresh() }
    }

    private var profileIds: [String] { store.segments.map(\.id) }

    private var autoAliases: [String: String] { UsageLogic.aliases(for: profileIds) }

    /// Known window types plus anything the live API is currently reporting.
    private var windowOptions: [String] {
        var set = Set(UsageLogic.windowLabels.keys)
        for p in store.quota?.profiles ?? [] {
            for w in p.windows ?? [] { set.insert(w.type) }
        }
        set.insert(primaryWindow)
        return set.sorted()
    }

    private func aliasBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { UsageStore.aliasOverrides()[id] ?? "" },
            set: { value in
                var overrides = UsageStore.aliasOverrides()
                overrides[id] = value.isEmpty ? nil : value
                UserDefaults.standard.set(overrides, forKey: "aliasOverrides")
                refresh()
            }
        )
    }

    private func refresh() {
        Task { await store.refresh() }
    }
}
