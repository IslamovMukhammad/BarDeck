import AppKit

/// Visual language for the Touch Bar. Everything is tuned for the 30pt-tall
/// strip: small radii, high contrast, no hairlines thinner than 1pt.
nonisolated enum Theme {

    // MARK: Metrics
    static let barHeight: CGFloat = 30
    static let cardRadius: CGFloat = 7
    static let itemSpacing: CGFloat = 8

    // MARK: Palette
    static let cardFill      = NSColor(white: 1.0, alpha: 0.10)
    static let cardFillHover = NSColor(white: 1.0, alpha: 0.18)
    static let cardStroke    = NSColor(white: 1.0, alpha: 0.14)

    static let textPrimary   = NSColor(white: 1.0, alpha: 0.95)
    static let textSecondary = NSColor(white: 1.0, alpha: 0.55)
    static let textTertiary  = NSColor(white: 1.0, alpha: 0.35)

    // Claude states: done — green, working — yellow, needs you — blue, failed — red.
    static let claudeIdle     = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)   // #30d158, clearly apart from the yellow
    static let claudeWorking  = NSColor(srgbRed: 1.000, green: 0.839, blue: 0.039, alpha: 1)   // #ffd60a
    static let claudeWaiting  = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.000, alpha: 1)   // #0a84ff
    static let claudeError    = NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1)   // #ff453a
    // Timer colours
    static let timerLime      = NSColor(srgbRed: 0.851, green: 1.000, blue: 0.361, alpha: 1)   // #d9ff5c
    static let timerOrange    = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.039, alpha: 1)   // #ff9f0a

    /// The music card's colour before the cover has loaded (a warm clay)
    static let coverDefault   = NSColor(srgbRed: 0.80, green: 0.47, blue: 0.33, alpha: 1)
    /// No Claude Code session alive.
    static let claudeOffline  = NSColor(white: 0.45, alpha: 1)

    static let gaugeSafe    = NSColor(srgbRed: 0.16, green: 0.82, blue: 0.62, alpha: 1)
    static let gaugeWarn    = NSColor(srgbRed: 1.00, green: 0.72, blue: 0.16, alpha: 1)
    static let gaugeDanger  = NSColor(srgbRed: 0.98, green: 0.34, blue: 0.34, alpha: 1)

    // MARK: Type
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
