import AppKit

/// A glow around the whole Touch Bar: it lights up from the left on a CPU peak and from the
/// right on a heat peak, and a thin violet line breathes along the bottom while the Mac is
/// swapping hard.
///   - it starts at the very edge of the bar, in the corner
///   - a fine line (1.25pt) plus a soft glow spreading from the edge: brightest in the corner,
///     fading along the line
///   - each side reaches 65% of the bar's width, so with both on they meet softly in the middle
/// It never takes touches (hitTest → nil) and uses no event monitor.
final class HealthEdgeOverlay: NSView {
    /// How far the glow reaches, relative to the bar's width
    private static let reach: CGFloat = 0.65
    private static let red = Theme.claudeError
    /// The Touch Bar screen's own corner radius
    static let cornerRadius: CGFloat = 8

    private final class Side {
        let leftSide: Bool
        let group = CALayer()
        let line = CALayer(), lineMask = CAGradientLayer()
        let glow = CAGradientLayer()
        var on = false

        init(leftSide: Bool) {
            self.leftSide = leftSide
            line.cornerCurve = .continuous
            line.borderWidth = 1.25
            line.borderColor = HealthEdgeOverlay.red.cgColor
            line.shadowColor = HealthEdgeOverlay.red.cgColor
            line.shadowRadius = 2.5
            line.shadowOpacity = 0.9
            line.shadowOffset = .zero

            // The line stays near full strength to ~40% and fades out softly between 55 and 65%
            // (no hard end).
            let alphas: [CGFloat] = [1, 1, 0.85, 0.6, 0.25, 0]
            let stops: [CGFloat] = [0, 0.3, 0.62, 0.8, 0.92, 1]
            lineMask.colors = alphas.map { NSColor(white: 0, alpha: $0).cgColor }
            lineMask.locations = stops.map { NSNumber(value: Double($0 * HealthEdgeOverlay.reach)) }
            lineMask.startPoint = CGPoint(x: leftSide ? 0 : 1, y: 0.5)
            lineMask.endPoint = CGPoint(x: leftSide ? 1 : 0, y: 0.5)
            line.mask = lineMask

            // A soft glow spreading inward from the edge
            glow.type = .radial
            glow.colors = [HealthEdgeOverlay.red.withAlphaComponent(0.34).cgColor,
                           HealthEdgeOverlay.red.withAlphaComponent(0.1).cgColor,
                           NSColor.clear.cgColor]
            glow.locations = [0, 0.45, 1]

            group.addSublayer(glow)
            group.addSublayer(line)
            group.opacity = 0
        }

        func layout(in bounds: CGRect) {
            group.frame = bounds
            // The screen's corners are rounded, so the line follows the same radius (a square
            // corner got clipped by the screen edge and looked broken).
            line.frame = bounds.insetBy(dx: 0.6, dy: 0.6)
            line.cornerRadius = HealthEdgeOverlay.cornerRadius
            lineMask.frame = bounds.insetBy(dx: -8, dy: -8)
            // The glow: an ellipse hugging the edge, as tall as the bar
            let width: CGFloat = 90
            glow.frame = CGRect(x: leftSide ? 0 : bounds.width - width, y: 0, width: width, height: bounds.height)
            glow.startPoint = CGPoint(x: leftSide ? 0 : 1, y: 0.5)
            glow.endPoint = CGPoint(x: leftSide ? 1 : 0, y: 1.25)
        }
    }

    private let cpu = Side(leftSide: true)
    private let heat = Side(leftSide: false)
    /// Memory pressure looks nothing like the CPU/heat edges: a thin violet line along the
    /// bottom edge that slowly breathes.
    private let memoryLine = CAGradientLayer()
    private var memoryOn = false
    private static let violet = NSColor(srgbRed: 0.749, green: 0.353, blue: 0.949, alpha: 1)   // #bf5af2

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(cpu.group)
        layer?.addSublayer(heat.group)
        // Fades out toward both ends instead of stopping abruptly
        memoryLine.colors = [Self.violet.withAlphaComponent(0).cgColor, Self.violet.cgColor,
                             Self.violet.cgColor, Self.violet.withAlphaComponent(0).cgColor]
        memoryLine.locations = [0, 0.12, 0.88, 1]
        memoryLine.startPoint = CGPoint(x: 0, y: 0.5)
        memoryLine.endPoint = CGPoint(x: 1, y: 0.5)
        memoryLine.shadowColor = Self.violet.cgColor
        memoryLine.shadowRadius = 3
        memoryLine.shadowOpacity = 1
        memoryLine.shadowOffset = .zero
        memoryLine.opacity = 0
        layer?.addSublayer(memoryLine)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cpu.layout(in: bounds)
        heat.layout(in: bounds)
        // The window's bottom edge (CALayer coordinates: y = 0 is the bottom)
        memoryLine.frame = CGRect(x: 0, y: 0.5, width: bounds.width, height: 1.5)
        CATransaction.commit()
    }

    /// Entering a peak blinks twice, then stays lit; leaving fades out.
    func set(cpu cpuPeak: Bool, heat heatPeak: Bool, memory memoryPeak: Bool = false) {
        needsLayout = true
        if memoryPeak != memoryOn {
            memoryOn = memoryPeak
            memoryLine.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            memoryLine.opacity = memoryPeak ? 1 : 0
            CATransaction.commit()
            if memoryPeak && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let breathe = CABasicAnimation(keyPath: "opacity")
                breathe.fromValue = 1; breathe.toValue = 0.3
                breathe.duration = 1.3; breathe.autoreverses = true; breathe.repeatCount = .infinity
                breathe.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
                memoryLine.add(breathe, forKey: "breathe")
            }
        }
        for (side, on) in [(cpu, cpuPeak), (heat, heatPeak)] where side.on != on {
            side.on = on
            animate(side.group, on: on)
        }
    }

    private func animate(_ group: CALayer, on: Bool) {
        group.removeAllAnimations()
        if on && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [0, 1, 0.15, 1, 0.15, 1]
            blink.keyTimes = [0, 0.12, 0.32, 0.5, 0.7, 0.86]
            blink.duration = 1.3
            group.add(blink, forKey: "blink")
        } else {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = group.presentation()?.opacity ?? group.opacity
            fade.toValue = on ? 1 : 0
            fade.duration = on ? 0.2 : 0.4
            fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            group.add(fade, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        group.opacity = on ? 1 : 0
        CATransaction.commit()
    }
}
