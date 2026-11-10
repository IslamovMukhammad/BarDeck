import AppKit

/// The centrepiece: a status lamp that breathes while Claude is working,
/// the state, and the tool it is running.
final class ClaudeStatusView: TBCard {

    private let lamp = CALayer()
    private let lampGlow = CALayer()
    private let primary = CATextLayer()
    private let secondary = MarqueeTextLayer()

    private var state = ClaudeState()
    private var chipButtons: [ClaudeChipButton] = []
    private var chipMode = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        showsAccent = false   // the lamp already carries the status colour

        lampGlow.cornerRadius = 8
        lampGlow.shadowRadius = 6
        lampGlow.shadowOpacity = 1
        lampGlow.shadowOffset = .zero
        layer?.addSublayer(lampGlow)

        lamp.cornerRadius = 3.5
        layer?.addSublayer(lamp)

        primary.contentsScale = 2
        layer?.addSublayer(primary)

        secondary.font = Theme.font(9.5, .medium)
        secondary.textColor = Theme.textSecondary
        layer?.addSublayer(secondary)

        render()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let lampRect = CGRect(x: 11, y: bounds.midY - 3.5, width: 7, height: 7)
        lamp.frame = lampRect
        lampGlow.frame = lampRect.insetBy(dx: -1, dy: -1)

        let textX = lampRect.maxX + 9
        let textWidth = max(0, bounds.width - textX - 12)
        primary.frame = CGRect(x: textX, y: 3, width: textWidth, height: 13)
        secondary.frame = CGRect(x: textX, y: 16, width: textWidth, height: 11)

        CATransaction.commit()
        layoutChips(animated: false)
    }

    // MARK: - Content

    func update(_ new: ClaudeState) {
        let activityChanged = new.activity != state.activity
        state = new
        render()
        renderChips()
        if activityChanged && !chipMode { flash(new.activity.color) }
    }

    // MARK: - Several sessions: chips

    private func renderChips() {
        let chips = state.chips
        let wantChips = chips.count >= 2

        // Match the number of buttons, reusing the ones there are
        while chipButtons.count < chips.count {
            let button = ClaudeChipButton()
            button.alphaValue = 0
            addSubview(button)
            chipButtons.append(button)
        }
        while chipButtons.count > chips.count {
            chipButtons.removeLast().removeFromSuperview()
        }
        for (button, chip) in zip(chipButtons, chips) { button.configure(chip) }

        if wantChips != chipMode {
            chipMode = wantChips
            // The single-session view and the chips swap with a soft cross-fade
            let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.duration = 0.22
            fade.timingFunction = curve
            for layer in [lamp, lampGlow, primary, secondary] as [CALayer] {
                fade.fromValue = layer.opacity
                fade.toValue = wantChips ? 0 : 1
                layer.add(fade, forKey: "mode")
                layer.opacity = wantChips ? 0 : 1
            }
            if !wantChips { setBackgroundColor(state.activity.color.withAlphaComponent(0.20), animated: true) }
        }
        if chipMode { setBackgroundColor(Theme.cardFill, animated: true) }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
            for button in chipButtons { button.animator().alphaValue = chipMode ? 1 : 0 }
            layoutChips(animated: true)
        }
    }

    /// A waiting chip is wider (Open ›); the rest share equally
    private func layoutChips(animated: Bool) {
        guard !chipButtons.isEmpty else { return }
        let gap: CGFloat = 4, inset: CGFloat = 3
        let weights = chipButtons.map { $0.isWaiting ? 1.8 : 1.0 }
        let total = weights.reduce(0, +)
        let usable = bounds.width - inset * 2 - gap * CGFloat(chipButtons.count - 1)
        var x = inset
        for (button, weight) in zip(chipButtons, weights) {
            let width = max(20, usable * CGFloat(weight / total))
            let frame = CGRect(x: x, y: 2, width: width, height: bounds.height - 4)
            if animated { button.animator().frame = frame } else { button.frame = frame }
            x += width + gap
        }
    }

    private func render() {
        let color = state.activity.color

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        lamp.backgroundColor = color.cgColor
        lampGlow.shadowColor = color.cgColor
        lampGlow.backgroundColor = NSColor.clear.cgColor

        primary.string = NSAttributedString(
            string: state.activity.label,
            attributes: [.font: Theme.font(11.5, .semibold), .foregroundColor: Theme.textPrimary])

        var detail: [String] = []
        if !state.detail.isEmpty { detail.append(state.detail) }
        if !state.model.isEmpty { detail.append(state.model) }
        if !state.project.isEmpty { detail.append(state.project) }
        secondary.text = detail.isEmpty ? "no session" : detail.joined(separator: " · ")

        needsLayout = true

        setBackgroundColor(color.withAlphaComponent(state.activity == .offline ? 0.10 : 0.20),
                           animated: true)
        CATransaction.commit()

        updatePulse()
    }

    /// A slow breath while Claude is busy, a quicker one when it is blocked on
    /// the human, and stillness otherwise.
    private func updatePulse() {
        lamp.removeAnimation(forKey: "pulse")
        lampGlow.removeAnimation(forKey: "pulse")
        guard state.activity.pulses else {
            lampGlow.shadowOpacity = 0.55
            return
        }
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.25
        pulse.toValue = 1.0
        pulse.duration = state.activity == .waiting ? 0.5 : 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lampGlow.add(pulse, forKey: "pulse")

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue = 1.15
        scale.duration = pulse.duration
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = pulse.timingFunction
        lamp.add(scale, forKey: "pulse")
    }

    /// One bright sweep so a state change is impossible to miss out of the
    /// corner of your eye.
    private func flash(_ color: NSColor) {
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = color.withAlphaComponent(0.75).cgColor
        animation.toValue = color.withAlphaComponent(state.activity == .offline ? 0.10 : 0.20).cgColor
        animation.duration = 0.55
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.sublayers?.first?.add(animation, forKey: "flash")
    }
}

/// One Claude session chip: a status lamp and the project name. A waiting session gets a
/// blue fill and "Open ›". A tap brings the session's app forward. Uses only NSButton's
/// own tracking (nothing else works on the Touch Bar).
final class ClaudeChipButton: NSButton {

    private let glass = CALayer()
    private let lamp = CALayer()
    private let label = CATextLayer()
    private var chip: ClaudeChip?

    var isWaiting: Bool { chip?.activity == .waiting }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        target = self
        action = #selector(tap)

        glass.cornerRadius = 6
        glass.cornerCurve = .continuous
        lamp.cornerRadius = 3.5
        lamp.shadowRadius = 4
        lamp.shadowOpacity = 0.8
        lamp.shadowOffset = .zero
        label.contentsScale = 2
        label.truncationMode = .end
        for sub in [glass, lamp, label] { layer?.addSublayer(sub) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ chip: ClaudeChip) {
        guard chip != self.chip else { return }
        self.chip = chip
        let color = chip.activity.color
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        lamp.backgroundColor = color.cgColor
        lamp.shadowColor = color.cgColor
        glass.backgroundColor = (chip.activity == .waiting
            ? Theme.claudeWaiting.withAlphaComponent(0.28)
            : NSColor(white: 1, alpha: 0.08)).cgColor
        CATransaction.commit()

        let text = NSMutableAttributedString(string: chip.project, attributes: [
            .font: Theme.font(11, .semibold), .foregroundColor: Theme.textPrimary])
        if chip.activity == .waiting {
            text.append(NSAttributedString(string: "  Open ›", attributes: [
                .font: Theme.font(11, .bold), .foregroundColor: NSColor(srgbRed: 0.45, green: 0.72, blue: 1, alpha: 1)]))
        }
        label.string = text

        lamp.removeAnimation(forKey: "pulse")
        if chip.activity.pulses {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35
            pulse.duration = chip.activity == .waiting ? 0.5 : 0.9
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            lamp.add(pulse, forKey: "pulse")
        }
        needsLayout = true
    }

    @objc private func tap() {
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.mass = 0.4; pop.stiffness = 420; pop.damping = 16
        pop.fromValue = 0.92; pop.toValue = 1
        glass.add(pop, forKey: "press")
        ClaudeOpener.open(cwd: chip?.cwd)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = bounds
        lamp.frame = CGRect(x: 7, y: bounds.midY - 3.5, width: 7, height: 7)
        label.frame = CGRect(x: 19, y: (bounds.height - 14) / 2 - 1, width: max(0, bounds.width - 24), height: 15)
        CATransaction.commit()
    }
}
