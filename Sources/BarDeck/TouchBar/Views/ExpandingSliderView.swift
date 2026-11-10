import AppKit

/// A round icon that swells into a slider under your finger and shrinks back
/// when you let go — the volume and brightness controls.
///
/// Everything here is driven by `NSPressGestureRecognizer` with
/// `allowedTouchTypes = .direct`. That one setting is the whole story: the
/// Touch Bar sends *direct* touches, views and recognizers accept only
/// *indirect* ones by default, and every earlier hand-rolled attempt at this
/// gesture was silently waiting for events that were never addressed to it.
///
/// Movement is relative to where the finger landed, not an absolute position
/// along a track, so the full range is always reachable no matter where on the
/// strip the control happens to sit.
final class ExpandingSliderView: TBCard {

    static let collapsedWidth: CGFloat = 46
    static let expandedWidth: CGFloat = 190

    /// Shared by this view and by whatever the controller moves out of the
    /// way, so the two travel as one piece of motion rather than one after
    /// the other. They must also stay monotonic — an overshooting width would
    /// drive the companion's constraint below zero.
    static let motionDuration: TimeInterval = 0.4
    static var motionCurve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 0.7, 0.25, 1)
    }

    /// How long the control stays open after the finger lifts. Raising the
    /// volume runs out of strip long before it runs out of range, so this is
    /// the window in which you can lift, reposition, and carry on.
    static let gracePeriod: TimeInterval = 1.0

    private let icon = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let readout = CATextLayer()

    private var widthConstraint: NSLayoutConstraint?
    private var accent: NSColor = .white
    private var symbolProvider: (Double) -> String = { _ in "circle" }

    private var dragStartX: CGFloat = 0
    private var dragStartValue: Double = 0
    private var collapseWork: DispatchWorkItem?
    private(set) var isExpanded = false

    private(set) var value: Double = 0

    /// Reports the live value while the finger is down.
    var onChange: ((Double) -> Void)?
    /// Lets the controller free up room on the strip for the expansion.
    var onExpandedChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        shape = .circular
        showsAccent = false

        icon.contentsGravity = .resizeAspect
        layer?.addSublayer(icon)

        track.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        track.cornerRadius = 3
        track.opacity = 0
        layer?.addSublayer(track)

        fill.cornerRadius = 3
        fill.opacity = 0
        layer?.addSublayer(fill)

        readout.contentsScale = 2
        readout.alignmentMode = .right
        readout.opacity = 0
        layer?.addSublayer(readout)

        let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0
        // Once the press is recognised we never want movement to cancel it —
        // movement *is* the interaction.
        press.allowableMovement = .greatestFiniteMagnitude
        press.allowedTouchTypes = .direct
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func install(widthConstraint: NSLayoutConstraint) {
        self.widthConstraint = widthConstraint
    }

    func configure(accent: NSColor, symbolProvider: @escaping (Double) -> String) {
        self.accent = accent
        self.symbolProvider = symbolProvider
        fill.backgroundColor = accent.cgColor
    }

    /// Updates the value from the outside (hardware keys, another app) without
    /// disturbing a gesture in progress.
    func setValue(_ new: Double) {
        guard !isExpanded else { return }
        value = min(max(new, 0), 1)
        refreshIcon()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let side: CGFloat = 17
        // Collapsed the glyph is centred; expanded it tucks to the left and
        // hands the middle over to the track.
        let iconX = isExpanded ? 13 : (bounds.width - side) / 2
        icon.frame = CGRect(x: iconX, y: (bounds.height - side) / 2, width: side, height: side)

        let trackX = iconX + side + 10
        let readoutWidth: CGFloat = 34
        let trackWidth = max(0, bounds.width - trackX - readoutWidth - 12)
        track.frame = CGRect(x: trackX, y: bounds.midY - 3, width: trackWidth, height: 6)
        readout.frame = CGRect(x: bounds.width - readoutWidth - 10, y: bounds.midY - 7,
                               width: readoutWidth, height: 14)
        layoutFill()

        CATransaction.commit()
        refreshIcon()
    }

    private func layoutFill() {
        fill.frame = CGRect(x: track.frame.minX, y: track.frame.minY,
                            width: max(0, track.frame.width * CGFloat(value)), height: 6)
    }

    /// The value is refreshed every 0.5 s; the glyph is only redrawn when its shape changes.
    private var drawnSymbol = ""

    private func refreshIcon() {
        let name = symbolProvider(value)
        guard name != drawnSymbol else { return }
        drawnSymbol = name
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.contents = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.tinted(with: Theme.textPrimary)
        icon.contentsScale = 2
    }

    // MARK: - Gesture

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        // Measured against the window, never against `self`.
        //
        // This view grows from 46pt to 190pt during the gesture, and because
        // it sits at the right end of the strip its own origin slides ~144pt
        // to the left as it does. In view-local coordinates a finger that has
        // not moved at all therefore appears to race 144pt to the right — which
        // is exactly why the value shot straight to 100% on touch-down. Window
        // space stays still while we resize, so the delta is real finger travel.
        let point = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            collapseWork?.cancel()
            dragStartX = point.x
            dragStartValue = value
            setExpanded(true)
        case .changed:
            // Roughly one full sweep per 170pt of travel — enough resolution
            // for a deliberate nudge without being twitchy.
            let delta = Double(point.x - dragStartX) / 170.0
            value = min(max(dragStartValue + delta, 0), 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutFill()
            updateReadout()
            CATransaction.commit()
            refreshIcon()
            onChange?(value)
        case .ended, .cancelled, .failed:
            scheduleCollapse()
        default:
            break
        }
    }

    /// Stays open for a beat after release so a second touch can pick up
    /// where the first ran out of room.
    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setExpanded(false) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracePeriod, execute: work)
    }

    /// Demo mode: opens the slider at a value and keeps it open (no finger needed).
    func showExpandedForDemo(value new: Double) {
        collapseWork?.cancel()
        value = min(max(new, 0), 1)
        setExpanded(true)
        layoutFill()
        updateReadout()
        refreshIcon()
    }

    /// Called when the sibling control opens, so only one is ever expanded.
    func collapseNow() {
        collapseWork?.cancel()
        setExpanded(false)
    }

    private func updateReadout() {
        readout.string = NSAttributedString(
            string: "\(Int(round(value * 100)))",
            attributes: [.font: Theme.mono(12, .bold), .foregroundColor: Theme.textPrimary])
    }

    /// The swell. Width rides a curve that overshoots slightly before settling,
    /// which is what gives it the Dynamic-Island feel rather than a plain
    /// resize; the contents cross-fade against it.
    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        onExpandedChange?(expanded)

        updateReadout()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motionDuration
            context.timingFunction = Self.motionCurve
            widthConstraint?.animator().constant = expanded ? Self.expandedWidth : Self.collapsedWidth
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(expanded ? 0.3 : 0.22)
        track.opacity = expanded ? 1 : 0
        fill.opacity = expanded ? 1 : 0
        readout.opacity = expanded ? 1 : 0
        CATransaction.commit()

        // The bounce lives here rather than on the width: an overshooting
        // width would push the companion item's constraint below zero.
        if expanded {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.mass = 0.4
            pop.stiffness = 320
            pop.damping = 14
            pop.fromValue = 0.7
            pop.toValue = 1.0
            for l in [track, fill, readout] { l.add(pop, forKey: "pop") }
        }

        setBackgroundColor(expanded ? accent.withAlphaComponent(0.22) : Theme.cardFill,
                           animated: true)
        needsLayout = true
    }
}
