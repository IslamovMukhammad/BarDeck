import AppKit

/// Demo mode for README screenshots: a made-up track with a cover drawn in code and a neutral
/// Claude project. It never asks Spotify, never listens for Claude hooks, and keeps its timer
/// out of your real settings.
///
///     BARDECK_DEMO=bar       build/BarDeck.app/Contents/MacOS/BarDeck   # music + Claude working
///     BARDECK_DEMO=sessions  …   # two Claude sessions as chips, one needs you
///     BARDECK_DEMO=timer     …   # quick timer running
///     BARDECK_DEMO=slider    …   # volume slider expanded
///     BARDECK_DEMO=xcode     …   # Xcode build in progress
///     BARDECK_DEMO=settings  …   # the settings window
///
/// Add `BARDECK_DEMO_HEALTH=cpu,heat,memory` (any subset) to force the glowing edges on;
/// without it the edges follow this Mac's real CPU, heat and swap.
@MainActor
enum Demo {
    static let mode = ProcessInfo.processInfo.environment["BARDECK_DEMO"]
    static var isOn: Bool { mode != nil }

    static let coverURL = "demo://cover"

    static func run(_ state: AppState) {
        let controller = state.controller
        // Each demo starts clean: a timer from an earlier demo run must not carry over.
        if QuickTimer.shared.isRunning { QuickTimer.shared.stop() }
        controller.music.isDemo = true
        if let cover = cover() { ArtworkCache.shared.register(cover, for: coverURL) }
        let now = Date().timeIntervalSince1970
        controller.music.publish(NowPlaying(title: "Midnight Drive", artist: "Demo Artist", album: "Open Roads",
                                            artworkURL: coverURL, isPlaying: true, position: 74, duration: 214,
                                            positionStamp: now))
        controller.demoPeaks = HealthPeaks.parse(ProcessInfo.processInfo.environment["BARDECK_DEMO_HEALTH"])
        ClaudeFeed.shared.set(ClaudeState(activity: .working, detail: "editing PlayerView.swift",
                                          model: "Opus 5.5", project: "demo-app"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            switch mode {
            case "settings":
                SettingsWindow.shared.show()
                // Sharpest shot: centre it on the highest-resolution screen.
                if let window = SettingsWindow.shared.window,
                   let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) {
                    let area = screen.visibleFrame
                    window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                                  y: area.maxY - window.frame.height - 20))
                }
            case "sessions":
                ClaudeFeed.shared.set(ClaudeState(
                    activity: .waiting,
                    chips: [ClaudeChip(id: "1", project: "demo-app", activity: .waiting, cwd: nil),
                            ClaudeChip(id: "2", project: "website", activity: .working, cwd: nil)],
                    detail: "Allow Bash?", model: "Opus 5.5", project: "demo-app"))
            case "timer":
                QuickTimer.shared.start(minutes: 15)
            case "slider":
                controller.volumeSlider.showExpandedForDemo(value: 0.62)
            case "xcode":
                controller.updateXcode(XcodeMessage(phase: "building", text: "Compiling 24 of 40",
                                                    progress: 0.6, project: "DemoApp"))
            default:
                break
            }
        }
    }

    /// A cover drawn in code: a sunset gradient with a road, no one else's artwork.
    static func cover(size: CGFloat = 300) -> NSImage? {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.30, alpha: 1),
                            NSColor(srgbRed: 0.55, green: 0.20, blue: 0.62, alpha: 1),
                            NSColor(srgbRed: 0.12, green: 0.10, blue: 0.32, alpha: 1)])?
            .draw(in: rect, angle: -90)
        NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.3, y: size * 0.42, width: size * 0.4, height: size * 0.4)).fill()
        NSColor(srgbRed: 0.08, green: 0.06, blue: 0.18, alpha: 1).setFill()
        let road = NSBezierPath()
        road.move(to: NSPoint(x: size * 0.42, y: size * 0.45))
        road.line(to: NSPoint(x: size * 0.58, y: size * 0.45))
        road.line(to: NSPoint(x: size * 0.95, y: 0))
        road.line(to: NSPoint(x: size * 0.05, y: 0))
        road.close()
        NSRect(x: 0, y: 0, width: size, height: size * 0.45).fill()
        NSColor(srgbRed: 0.2, green: 0.16, blue: 0.36, alpha: 1).setFill()
        road.fill()
        return image
    }
}
