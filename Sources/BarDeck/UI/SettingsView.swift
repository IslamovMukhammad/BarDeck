import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            if !state.touchBarAvailable {
                Section {
                    Label("This Mac has no Touch Bar", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                    Text("BarDeck takes over the Touch Bar of MacBook Pro models that have one. There is nothing to show here.")
                        .foregroundStyle(.secondary)
                }
            }
            if !state.isTrusted {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility permission needed", systemImage: "hand.raised.fill")
                            .font(.headline)
                        Text("Touches on the bar reach BarDeck through Accessibility, and the Xcode card reads Xcode's activity text the same way.")
                            .foregroundStyle(.secondary)
                        Button("Grant Permission…") { state.requestPermission() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("On the bar") {
                Toggle("Spotify: now playing and controls", isOn: $settings.showMusic)
                Toggle("Claude Code status", isOn: $settings.showClaude)
                Toggle("Quick timer", isOn: $settings.showTimer)
                Toggle("Xcode build progress", isOn: $settings.showXcode)
                Toggle("Brightness slider", isOn: $settings.showBrightness)
                Toggle("Volume slider", isOn: $settings.showVolume)
                Toggle("Glowing edges on CPU, heat or swap peaks", isOn: $settings.healthEdges)
                Text("Left edge red: CPU above 85% for 5 s. Right edge red: the chip above 95 °C (10 s average). Violet line along the bottom: memory pressure while the Mac is swapping.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                LabeledContent("Hooks") {
                    HStack {
                        Text(state.hooksInstalled ? "Installed" : "Not installed")
                            .foregroundStyle(state.hooksInstalled ? .green : .secondary)
                        Button(state.hooksInstalled ? "Remove" : "Install") {
                            state.hooksInstalled ? state.uninstallHooks() : state.installHooks()
                        }
                    }
                }
                Text("Adds hooks to ~/.claude/settings.json. They send BarDeck only what the card shows (state, tool, project), never your prompts or tool output, over a private local socket with a secret token. Your other hooks stay; a backup is kept next to the file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = state.hooksError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                Toggle("One chip per session when several are active", isOn: $settings.claudeChips)
                Toggle("Mark a session done from its transcript if the Stop hook is missed", isOn: $settings.claudeAutoDone)
            }

            Section("Xcode") {
                Toggle("Play a sound when a build succeeds or fails", isOn: $settings.xcodeSound)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }))
                if let error = state.launchAtLoginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                LabeledContent("Accessibility") {
                    Text(state.isTrusted ? "Granted" : "Not granted")
                        .foregroundStyle(state.isTrusted ? .green : .secondary)
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Text("Free and open source under the MIT license.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
