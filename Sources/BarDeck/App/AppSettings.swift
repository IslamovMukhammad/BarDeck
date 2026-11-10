import Foundation
import Observation

/// Every setting, saved in UserDefaults. A change that affects the bar calls `onTouchBar`.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    // Items on the bar
    var showMusic: Bool { didSet { save(showMusic, "showMusic") } }
    var showClaude: Bool { didSet { save(showClaude, "showClaude") } }
    var showTimer: Bool { didSet { save(showTimer, "showTimer") } }
    var showXcode: Bool { didSet { save(showXcode, "showXcode") } }
    var showBrightness: Bool { didSet { save(showBrightness, "showBrightness") } }
    var showVolume: Bool { didSet { save(showVolume, "showVolume") } }
    /// CPU, heat and swap as colour only: red edges on CPU (left) or heat (right) peaks, a
    /// violet line along the bottom while the Mac swaps hard.
    var healthEdges: Bool { didSet { save(healthEdges, "healthEdges") } }

    // Claude Code
    /// With 2+ active sessions, one chip per session (tap one to bring its app forward).
    var claudeChips: Bool { didSet { save(claudeChips, "claudeChips") } }
    /// Mark a session done from its transcript when the Stop hook never arrives.
    var claudeAutoDone: Bool { didSet { save(claudeAutoDone, "claudeAutoDone") } }

    // Xcode
    var xcodeSound: Bool { didSet { save(xcodeSound, "xcodeSound") } }

    @ObservationIgnored var onTouchBar: (() -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool = true) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        showMusic = bool("showMusic")
        showClaude = bool("showClaude")
        showTimer = bool("showTimer")
        showXcode = bool("showXcode")
        showBrightness = bool("showBrightness")
        showVolume = bool("showVolume")
        healthEdges = bool("healthEdges")
        claudeChips = bool("claudeChips")
        claudeAutoDone = bool("claudeAutoDone")
        xcodeSound = bool("xcodeSound")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onTouchBar?()
    }
}
