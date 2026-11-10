import AppKit
import SwiftUI

@main
struct BarDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("BarDeck", systemImage: "rectangle.split.3x1") {
            MenuBarContent()
        }
    }
}

/// The menu bar menu.
private struct MenuBarContent: View {
    @State private var tick = 0

    var body: some View {
        let state = AppState.shared
        Button(state.barShown ? "Hide Touch Bar" : "Show Touch Bar") { state.toggleBar() }
            .disabled(!state.touchBarAvailable)
        Divider()
        Section("Quick Timer") {
            if QuickTimer.shared.isRunning {
                Button("Stop Timer (\(QuickTimer.clock(QuickTimer.shared.remaining)) left)") { QuickTimer.shared.stop() }
            } else {
                ForEach(QuickTimer.presets, id: \.self) { minutes in
                    Button("\(minutes) minutes") { QuickTimer.shared.start(minutes: minutes) }
                }
            }
        }
        Divider()
        Button("Settings…") { SettingsWindow.shared.show() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit BarDeck") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppState.isRunningTests else { return }
        let state = AppState.shared
        state.start()
        if Demo.isOn {
            Demo.run(state)
            return
        }
        // Opened by the user (not at login), or still missing permission → show settings.
        if !launchedAsLoginItem || !state.isTrusted {
            SettingsWindow.shared.show()
        }
    }

    /// Double-clicking the app while it runs opens settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// The settings window is managed by hand so it can be reopened from anywhere (menu bar, Finder).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingView(rootView: SettingsView()
                .environment(AppState.shared)
                .environment(AppSettings.shared))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "BarDeck"
            window.contentView = host
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
