import AppKit

/// Broadcasts the current Claude status colour so every card on the strip can
/// tint itself. The stagger is what sells it: the colour sweeps left-to-right
/// across the bar instead of snapping all at once.
@MainActor
final class StatusTint {
    static let shared = StatusTint()
    private(set) var color: NSColor = Theme.claudeOffline
    private var observers: [(index: Int, apply: (NSColor, TimeInterval) -> Void)] = []
    private var nextIndex = 0

    func register(_ apply: @escaping (NSColor, TimeInterval) -> Void) {
        let index = nextIndex; nextIndex += 1
        observers.append((index, apply))
        apply(color, 0)
    }

    func set(_ color: NSColor) {
        guard color != self.color else { return }
        self.color = color
        for observer in observers {
            observer.apply(color, Double(observer.index) * 0.045)
        }
    }
}

/// Base view for everything on the strip: a translucent card with a hairline
/// accent that follows the Claude status colour.
class TBCard: NSView {

    enum Shape { case rounded, circular }

    private let background = CALayer()
    private let specular = CAGradientLayer()
    private let accent = CALayer()
    private(set) var isPressed = false

    var shape: Shape = .rounded { didSet { needsLayout = true } }
    var accentIntensity: CGFloat = 0.9 { didSet { needsLayout = true } }
    var showsAccent: Bool = true { didSet { accent.isHidden = !showsAccent } }
    var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        background.cornerCurve = .continuous
        background.backgroundColor = Theme.cardFill.cgColor
        background.borderWidth = 1
        background.borderColor = Theme.cardStroke.cgColor
        background.masksToBounds = true
        layer?.addSublayer(background)

        // A faint top-edge catch-light — the one cue that reads as "glass"
        // rather than "flat tinted rectangle" at this size, without pulling
        // in a full vibrancy/blur material that would fight the manually
        // ordered CALayer content the rest of this view relies on.
        specular.colors = [NSColor(white: 1, alpha: 0.20).cgColor, NSColor(white: 1, alpha: 0.0).cgColor]
        specular.locations = [0, 1]
        // `background` is a plain (non-flipped) CALayer, so gradient unit
        // space here is the CALayer default: y:1 is its top edge, y:0 its
        // bottom — the opposite convention from this NSView's own flipped
        // bounds. Bright at y:1 is what actually lands at the card's top.
        specular.startPoint = CGPoint(x: 0.5, y: 1)
        specular.endPoint = CGPoint(x: 0.5, y: 0.4)
        background.addSublayer(specular)

        accent.cornerRadius = 1
        accent.backgroundColor = Theme.claudeOffline.cgColor
        layer?.addSublayer(accent)

        StatusTint.shared.register { [weak self] color, delay in
            self?.applyAccent(color, delay: delay)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.cornerRadius = shape == .circular ? bounds.height / 2 : Theme.cardRadius
        specular.frame = background.bounds
        accent.frame = CGRect(x: 6, y: bounds.height - 2.5, width: max(0, bounds.width - 12), height: 2)
        CATransaction.commit()
    }

    private func applyAccent(_ color: NSColor, delay: TimeInterval) {
        let target = color.withAlphaComponent(accentIntensity).cgColor
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = accent.backgroundColor
        animation.toValue = target
        animation.duration = 0.35
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        accent.add(animation, forKey: "tint")
        accent.backgroundColor = target
        accentChanged(to: color, delay: delay)
    }

    /// Subclass hook for cards that want to do more than move the hairline.
    func accentChanged(to color: NSColor, delay: TimeInterval) {}

    // MARK: - Touch handling
    //
    // Touch Bar item views are hosted through a remote-view bridge, not a
    // normal window. Blocking that host with a manual `nextEvent` tracking
    // loop (the obvious AppKit pattern) is unreliable there — it is what made
    // every button on the strip stop responding. Plain event overrides are
    // the only pattern that behaves.

    override func mouseDown(with event: NSEvent) {
        setPressed(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressed(inside)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressed(false)
        if inside { onTap?() }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        background.backgroundColor = (pressed ? Theme.cardFillHover : Theme.cardFill).cgColor
        CATransaction.commit()

        // A small tactile pop — matches how Apple's own Touch Bar controls
        // and Control Centre widgets feel underfinger. This animates the
        // `background` *sublayer*, never `self.layer` — that root layer's
        // geometry belongs to AppKit's Auto Layout engine, and touching its
        // transform there triggers a layout feedback loop (the view keeps
        // re-entering `-layout` while already laying out) that froze every
        // touch on the strip.
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.mass = 0.4
        scale.stiffness = 420
        scale.damping = 18
        scale.toValue = pressed ? 0.93 : 1.0
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        background.add(scale, forKey: "press")
    }

    func setBackgroundColor(_ color: NSColor, animated: Bool = true, delay: TimeInterval = 0) {
        let target = color.cgColor
        if animated {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = background.backgroundColor
            animation.toValue = target
            animation.duration = 0.35
            animation.beginTime = CACurrentMediaTime() + delay
            animation.fillMode = .backwards
            background.add(animation, forKey: "fill")
        }
        background.backgroundColor = target
    }
}
