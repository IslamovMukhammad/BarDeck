import ApplicationServices
import AppKit

/// Third-party Touch Bar takeovers route their touches through the same
/// Accessibility-gated pathway as apps that control the system, so a Touch
/// Bar item's buttons stay dead until this is granted — and because a
/// development-signed build's code signature changes with every rebuild,
/// TCC forgets the grant each time and the user has to redo it.
enum AccessibilityPermission {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's own "would like to control this computer" prompt,
    /// which drops the app straight into System Settings ▸ Accessibility.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
