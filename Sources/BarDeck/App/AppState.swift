import AppKit
import ApplicationServices
import Observation
import ServiceManagement

/// App-wide state: the Touch Bar, the Claude listener, permissions, launch at login.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    private(set) var isTrusted = AXIsProcessTrusted()
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?
    private(set) var hooksInstalled = ClaudeHooks.isInstalled()
    private(set) var hooksError: String?
    private(set) var barShown = false
    /// False on Macs without a Touch Bar (or if the private framework isn't there).
    let touchBarAvailable = DFR.isAvailable

    @ObservationIgnored let controller = TouchBarController()
    @ObservationIgnored let server = ClaudeEventServer()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var started = false

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    func start() {
        guard !started, !Self.isRunningTests else { return }
        started = true
        if !Demo.isOn {
            server.onEvent = { event, payload in ClaudeFeed.shared.handle(event: event, payload: payload) }
            server.start()
            ClaudeFeed.shared.start()
        }
        if touchBarAvailable {
            controller.start()
            barShown = controller.isPresented
        } else {
            NSLog("[BarDeck] No Touch Bar (DFRFoundation not found): nothing to show")
        }
        if !isTrusted { startPolling() }
    }

    func shutdown() {
        guard started else { return }
        controller.stop()
        server.stop()
    }

    func toggleBar() {
        controller.toggle()
        barShown = controller.isPresented
    }

    // MARK: - Accessibility
    // Touches on a third-party Touch Bar reach the app through the same Accessibility-gated
    // path as apps that control the Mac; the Xcode card reads Xcode's window through it too.

    func requestPermission() {
        if !AccessibilityPermission.requestIfNeeded() { AccessibilityPermission.openSystemSettings() }
        startPolling()
    }

    /// Polls only while permission is missing; stops for good once it's granted.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let state = AppState.shared
                guard AXIsProcessTrusted() else { return }
                state.isTrusted = true
                state.pollTimer?.invalidate()
                state.pollTimer = nil
                // The bar presented before the grant may ignore touches: present it again.
                if state.touchBarAvailable, state.controller.isPresented { state.controller.present() }
            }
        }
    }

    // MARK: - Claude Code hooks

    func installHooks() {
        do {
            try ClaudeHooks.install()
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksInstalled = ClaudeHooks.isInstalled()
    }

    func uninstallHooks() {
        do {
            try ClaudeHooks.uninstall()
            hooksError = nil
        } catch {
            hooksError = error.localizedDescription
        }
        hooksInstalled = ClaudeHooks.isInstalled()
    }

    // MARK: - Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
