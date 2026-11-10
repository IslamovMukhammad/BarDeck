import AppKit

/// The card that only appears while Xcode is busy:
///
///   🔨 Fetching GRDB.swift          32%
///   ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔ (progress line)
///
/// When done: green "Build Succeeded" (3 s), red "Build Failed" (until you
/// switch to Xcode). It rises in from below and leaves the same way.
final class XcodeCardView: TBCard {

    static let width: CGFloat = 214

    private let icon = CALayer()
    /// Long text scrolls itself, like the music and Claude cards
    private let label = MarqueeTextLayer()
    private let percent = CATextLayer()
    private let track = CALayer()
    private let bar = CALayer()
    private(set) var isShown = false
    private var lastSymbol = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        showsAccent = false
        layer?.masksToBounds = true
        icon.contentsGravity = .resizeAspect
        label.font = Theme.font(11.5, .semibold)
        percent.contentsScale = 2
        percent.alignmentMode = .right
        track.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        track.cornerRadius = 1
        bar.cornerRadius = 1
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        for sub in [icon, label, percent, track, bar] { layer?.addSublayer(sub) }
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ m: XcodeMessage) {
        let color: NSColor
        let symbol: String
        let text: String
        switch m.phase {
        case "succeeded":
            color = Theme.claudeIdle; symbol = "checkmark.circle.fill"; text = m.text.isEmpty ? "Build Succeeded" : m.text
        case "failed":
            color = Theme.claudeError; symbol = "xmark.octagon.fill"; text = m.text.isEmpty ? "Build Failed" : m.text
        case "packages":
            color = Theme.claudeWaiting; symbol = "shippingbox.fill"; text = m.text
        case "testing":
            color = Theme.claudeWaiting; symbol = "checklist"; text = m.text
        default:
            color = Theme.claudeWaiting; symbol = "hammer.fill"; text = m.text
        }

        if symbol != lastSymbol {
            lastSymbol = symbol
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [color]))
            icon.contents = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }

        let done = m.phase == "succeeded" || m.phase == "failed"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.textColor = done ? color : Theme.textPrimary
        label.text = text
        percent.string = NSAttributedString(
            string: m.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "",
            attributes: [.font: Theme.mono(12, .bold), .foregroundColor: color])
        track.isHidden = done || m.progress == nil
        bar.isHidden = track.isHidden
        bar.backgroundColor = color.cgColor
        CATransaction.commit()

        // The progress line glides forward (updated once a second)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.9)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        bar.transform = CATransform3DMakeScale(max(0.001, m.progress ?? 0), 1, 1)
        CATransaction.commit()

        setBackgroundColor(done ? color.withAlphaComponent(0.2) : Theme.cardFill, animated: true)
        layoutLayers()
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduce {
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = shown ? 14 : 0
            rise.toValue = shown ? 0 : 14
            rise.duration = shown ? 0.3 : 0.18
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            for sub in [icon, label, percent] { sub.add(rise, forKey: "rise") }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.28 : 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            animator().alphaValue = shown ? 1 : 0
        }
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    /// After a Touch Bar width animation `layout()` isn't always called again
    /// (confirmed with logs: only once, at width 0), so the layers are placed by
    /// hand on every size change and every update.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        icon.frame = CGRect(x: 9, y: (h - 15) / 2, width: 15, height: 15)
        let percentWidth: CGFloat = 38
        percent.frame = CGRect(x: bounds.width - percentWidth - 9, y: (h - 16) / 2 + 1, width: percentWidth, height: 16)
        // The marquee rebuilds itself only when its width or text changes
        label.frame = CGRect(x: 30, y: (h - 16) / 2 + 1, width: max(0, percent.frame.minX - 34), height: 16)
        // TBCard is flipped: the line sits on the bottom edge
        track.frame = CGRect(x: 10, y: h - 4, width: bounds.width - 20, height: 2)
        bar.bounds = CGRect(x: 0, y: 0, width: bounds.width - 20, height: 2)
        bar.position = CGPoint(x: 10, y: h - 3)
        CATransaction.commit()
    }
}
