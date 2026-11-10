import AppKit

/// A circular translucent button with an SF Symbol — the same shape Apple
/// uses for transport controls in its own Now Playing / Control Centre
/// widgets.
///
/// Tap only, via `NSButtonCell`'s own untouched tracking. A real physical
/// test proved that any *custom* `mouseDown`/`mouseDragged` override on a
/// Touch Bar item view — even one that still calls through to `super` for the
/// plain-tap case — stops the whole view receiving touches the moment the
/// override exists for a *different* code path on the same class. Play,
/// pause, skip and the album tap all still work because they never override
/// these methods at all; a press-and-hold-drag variant of this button was
/// tried and confirmed dead on real hardware, which is why it isn't here.
final class IconButton: NSButton {

    private let glass = CALayer()
    private let icon = CALayer()
    private var currentSymbol = ""
    private var tint: NSColor = Theme.textPrimary

    var symbolPointSize: CGFloat = 13 { didSet { redraw() } }
    var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage   // we draw the glyph ourselves via `icon`
        wantsLayer = true
        target = self
        action = #selector(handleTap)

        glass.cornerCurve = .continuous
        glass.backgroundColor = Theme.cardFill.cgColor
        glass.borderWidth = 1
        glass.borderColor = Theme.cardStroke.cgColor
        layer?.addSublayer(glass)

        icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func handleTap() {
        flashPress()
        onTap?()
    }

    func setSymbol(_ name: String, tint color: NSColor = Theme.textPrimary, animated: Bool = true) {
        guard name != currentSymbol || color != tint else { return }
        let changed = name != currentSymbol
        currentSymbol = name
        tint = color
        redraw()
        if changed && animated {
            // A quick pop when the glyph itself changes (e.g. play -> pause)
            // — makes the swap read as a deliberate state change, not a glitch.
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.mass = 0.35
            pop.stiffness = 380
            pop.damping = 14
            pop.fromValue = 0.6
            pop.toValue = 1.0
            icon.add(pop, forKey: "pop")
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        let side = min(bounds.height - 8, 18)
        icon.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                            width: side, height: side)
        CATransaction.commit()
        redraw()
    }

    private func redraw() {
        guard !currentSymbol.isEmpty else { icon.contents = nil; return }
        let config = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .semibold)
        guard let image = NSImage(systemSymbolName: currentSymbol, accessibilityDescription: currentSymbol)?
            .withSymbolConfiguration(config) else { return }
        icon.contents = image.tinted(with: tint)
        icon.contentsScale = 2
    }

    private func flashPress() {
        let tint = CABasicAnimation(keyPath: "backgroundColor")
        tint.fromValue = Theme.cardFillHover.cgColor
        tint.toValue = Theme.cardFill.cgColor
        tint.duration = 0.35
        tint.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glass.add(tint, forKey: "press-tint")

        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.mass = 0.4
        scale.stiffness = 420
        scale.damping = 16
        scale.fromValue = 0.9
        scale.toValue = 1.0
        glass.add(scale, forKey: "press-scale")
    }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect, from: rect, operation: .sourceOver, fraction: 1)
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
