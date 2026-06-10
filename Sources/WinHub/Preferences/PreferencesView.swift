import SwiftUI

/// The Settings window content — a native grouped form. Deliberately plain:
/// toggles, an app list, no jargon.
struct PreferencesView: View {
    @ObservedObject var model: PreferencesModel

    @AppStorage(NotchSettings.openOnHoverKey) private var notchOpenOnHover = true
    @AppStorage(NotchSettings.hoverDelayKey) private var notchHoverDelay = 0.3
    @AppStorage(NotchSettings.liveActivityKey) private var notchLiveActivity = true
    @AppStorage(NotchSettings.shelfKey) private var notchShelf = true
    @AppStorage(NotchSettings.hapticsKey) private var notchHaptics = true
    @AppStorage(NotchSettings.realVisualizerKey) private var notchRealVisualizer = true

    var body: some View {
        Form {
            Section {
                ForEach(model.modules, id: \.id) { module in
                    moduleRow(module)
                }
            } header: {
                Text("Tweaks")
            } footer: {
                Text("Turn each tweak on or off. WinHub asks for a permission only when a tweak needs it.")
            }

            Section {
                if model.exclusions.isEmpty {
                    Text("No apps excluded — every app quits when its last window closes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.exclusions) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(app.name)
                            Spacer()
                            Button {
                                model.removeExclusion(app)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Stop excluding \(app.name)")
                        }
                    }
                }
                Button {
                    model.addExclusion()
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
            } header: {
                Text("Apps that should stay open")
            } footer: {
                Text("These keep macOS's default behavior — closing their last window won't quit them. Only matters when \u{201C}Close button quits app\u{201D} is on.")
            }

            Section {
                Toggle("Open on hover", isOn: $notchOpenOnHover)
                if notchOpenOnHover {
                    HStack {
                        Text("Hover delay")
                        Slider(value: $notchHoverDelay, in: 0...1)
                        Text(String(format: "%.1f s", notchHoverDelay))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Music live activity beside the notch", isOn: $notchLiveActivity)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Visualizer reacts to the actual audio", isOn: $notchRealVisualizer)
                    Text("Uses a system-audio tap while music plays — macOS asks once for permission and shows its recording indicator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("File shelf (drop files on the notch)", isOn: $notchShelf)
                Toggle("Haptic feedback", isOn: $notchHaptics)
            } header: {
                Text("Dynamic notch")
            } footer: {
                Text("Only applies while the \u{201C}Dynamic notch\u{201D} tweak is on.")
            }

            Section {
                Toggle("Start at login", isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }))
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("WinHub \(AppInfo.version) · Version2")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("View on GitHub", destination: URL(string: "https://github.com/v2matosevic/WinHub")!)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func moduleRow(_ module: HubModule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { model.isEnabled(module) },
                set: { model.setEnabled($0, module) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                        Text(module.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

            ForEach(model.missingPermissions(module), id: \.self) { permission in
                Button {
                    model.grant(permission)
                } label: {
                    Label("Grant \(permission.displayName) permission…", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}
