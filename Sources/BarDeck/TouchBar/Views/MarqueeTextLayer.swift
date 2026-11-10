import AppKit

/// A single line of text that scrolls itself when it does not fit, then pauses
/// at the start of each loop. Two copies of the text ride the same animation so
/// the wrap is seamless.
nonisolated final class MarqueeTextLayer: CALayer {

    private let clip = CALayer()
    private let first = CATextLayer()
    private let second = CATextLayer()
    private let gap: CGFloat = 36
    private var lastBuild: (text: String, width: CGFloat) = ("", 0)

    var text: String = "" { didSet { guard text != oldValue else { return }; rebuild() } }
    /// Forces the next `rebuild()` to run even if the text is unchanged.
    private func invalidate() { lastBuild = ("\u{0}", -1) }
    var font: NSFont = Theme.font(12, .semibold) { didSet { invalidate(); rebuild() } }
    var textColor: NSColor = Theme.textPrimary { didSet { invalidate(); rebuild() } }

    override init() {
        super.init()
        clip.masksToBounds = true
        addSublayer(clip)
        for layer in [first, second] {
            layer.contentsScale = 2
            layer.truncationMode = .none
            layer.isWrapped = false
            clip.addSublayer(layer)
        }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        rebuild()   // no-ops unless the text or the width actually changed
        CATransaction.commit()
    }

    private func rebuild() {
        guard bounds.width > 0 else { return }
        guard (text, bounds.width) != lastBuild else { return }
        lastBuild = (text, bounds.width)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let width = ceil(attributed.size().width)
        let height = bounds.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        first.string = attributed
        second.string = attributed
        first.frame = CGRect(x: 0, y: 0, width: width, height: height)
        second.frame = CGRect(x: width + gap, y: 0, width: width, height: height)

        first.removeAllAnimations()
        second.removeAllAnimations()

        if width <= bounds.width {
            second.isHidden = true
            CATransaction.commit()
            return
        }

        second.isHidden = false
        let distance = width + gap
        // Roughly 34pt per second reads comfortably at arm's length, with a
        // beat of stillness before each pass.
        let scrollTime = Double(distance) / 34.0
        let pause = 1.6
        let total = scrollTime + pause

        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.duration = total
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.keyTimes = [0, NSNumber(value: pause / total), 1]
        animation.values = [0, 0, -distance]
        animation.isAdditive = true

        first.add(animation, forKey: "marquee")
        second.add(animation, forKey: "marquee")
        CATransaction.commit()
    }
}
