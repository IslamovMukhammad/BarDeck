import AppKit

/// A rounded text button. Like `IconButton` it relies only on NSButton's own
/// tracking: overriding mouseDown on the Touch Bar stops taps arriving at all
/// (confirmed on real hardware).
final class TouchPillButton: NSButton {

    private let glass = CALayer()
    private let label = CATextLayer()
    var onTap: (() -> Void)?

    var text: String = "" { didSet { redraw() } }
    var textColor: NSColor = Theme.textPrimary { didSet { redraw() } }
    var fill: NSColor = Theme.cardFill { didSet { glass.backgroundColor = fill.cgColor } }
    var labelFont: NSFont = Theme.mono(12.5, .semibold) { didSet { redraw() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        target = self
        action = #selector(handleTap)

        glass.cornerCurve = .continuous
        glass.backgroundColor = fill.cgColor
        glass.borderWidth = 1
        glass.borderColor = Theme.cardStroke.cgColor
        layer?.addSublayer(glass)

        label.contentsScale = 2
        label.alignmentMode = .center
        layer?.addSublayer(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Flashes a colour in the button's own shape, then returns to its fill.
    func flash(_ color: NSColor, times: Int, period: CFTimeInterval) {
        let base = fill.cgColor
        let on = color.cgColor
        let blink = CAKeyframeAnimation(keyPath: "backgroundColor")
        blink.values = [base, on, on, base, base]
        blink.keyTimes = [0, 0.08, 0.5, 0.62, 1]
        blink.duration = period
        blink.repeatCount = Float(times)
        glass.add(blink, forKey: "flash")
    }

    @objc private func handleTap() {
        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.mass = 0.4; scale.stiffness = 420; scale.damping = 16
        scale.fromValue = 0.88; scale.toValue = 1.0
        glass.add(scale, forKey: "press")
        onTap?()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = bounds
        glass.cornerRadius = min(bounds.height / 2, 8)
        label.frame = CGRect(x: 0, y: (bounds.height - 16) / 2, width: bounds.width, height: 16)
        CATransaction.commit()
    }

    private func redraw() {
        label.string = NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: textColor])
    }
}

/// The quick timer on the Touch Bar: shows and drives `QuickTimer`.
///
/// Three states, each with its own width:
///   idle     → ⏱ circle (42pt)
///   picking  → 5 · 10 · 15 · 20 · × (236pt)
///   running  → 4:58 + a shrinking line (108pt)
/// The controller animates the width change together with the Claude card, on the
/// same curve, so the two read as one motion.
final class TimerChipView: NSView {

    enum Mode { case idle, picking, running }

    static let idleWidth: CGFloat = 42
    static let pickingWidth: CGFloat = 236
    static let runningWidth: CGFloat = 108

    /// The controller animates the width
    var onWidthChange: ((CGFloat) -> Void)?

    private(set) var mode: Mode = .idle
    private let idleButton = IconButton()
    private var presetButtons: [TouchPillButton] = []
    private let closeButton = IconButton()
    private let runButton = TouchPillButton()
    private let bar = CALayer()
    private let barTrack = CALayer()

    private var ticker: Timer?
    private var confirmUntil: Date?
    /// When done, the chip reads "Done" and flashes a few times, then goes back to idle
    private var celebrating = false
    private var celebrationEnd: DispatchWorkItem?
    private static let flashTimes = 3
    private static let flashPeriod: CFTimeInterval = 0.6
    private var pickTimeout: DispatchWorkItem?
    private let timer = QuickTimer.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        idleButton.setSymbol("timer", animated: false)
        idleButton.onTap = { [weak self] in self?.setMode(.picking) }
        addSubview(idleButton)

        for minutes in QuickTimer.presets {
            let button = TouchPillButton()
            button.text = "\(minutes)"
            button.onTap = { [weak self] in
                self?.timer.start(minutes: minutes)
            }
            presetButtons.append(button)
            addSubview(button)
        }
        closeButton.setSymbol("xmark", tint: Theme.textSecondary, animated: false)
        closeButton.symbolPointSize = 10
        closeButton.onTap = { [weak self] in self?.setMode(.idle) }
        addSubview(closeButton)

        runButton.labelFont = Theme.mono(13.5, .bold)
        runButton.onTap = { [weak self] in self?.tapRunning() }
        addSubview(runButton)

        barTrack.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        barTrack.cornerRadius = 1
        bar.backgroundColor = Theme.timerLime.cgColor
        bar.cornerRadius = 1
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        runButton.layer?.addSublayer(barTrack)
        runButton.layer?.addSublayer(bar)

        timer.observe({ [weak self] timer in
            self?.sync(with: timer)
        }, onFinish: { [weak self] in
            self?.celebrate()
        })
        applyVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// If the timer was already running at launch, the chip switches to "running" before the
    /// controller is wired up and the width message is lost (the chip got cut at 42pt).
    /// The controller asks for the current width again once connected.
    func reportWidth() {
        let width: CGFloat = switch mode {
        case .idle: Self.idleWidth
        case .picking: Self.pickingWidth
        case .running: Self.runningWidth
        }
        onWidthChange?(width)
    }

    /// Called by the controller: an opening slider closes the picker
    func collapsePicker() {
        if mode == .picking { setMode(.idle) }
    }

    // MARK: - State

    private func sync(with timer: QuickTimer) {
        if timer.isRunning {
            if mode != .running { setMode(.running) }
            startTicker()
        } else {
            stopTicker()
            // On a natural finish QuickTimer calls this first and onFinish right after.
            // Collapsing waits one run-loop turn, so celebrate() can hold the running shape.
            if mode == .running, !celebrating {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.celebrating, !self.timer.isRunning, self.mode == .running else { return }
                    self.setMode(.idle)
                }
            }
        }
        renderRunning()
    }

    private func setMode(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        confirmUntil = nil
        pickTimeout?.cancel()
        if new == .picking {
            // Nothing picked within 6 seconds: fold back, so the bar isn't left half open.
            let work = DispatchWorkItem { [weak self] in
                if self?.mode == .picking { self?.setMode(.idle) }
            }
            pickTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
        let width: CGFloat = switch new {
        case .idle: Self.idleWidth
        case .picking: Self.pickingWidth
        case .running: Self.runningWidth
        }
        onWidthChange?(width)
        applyVisibility(animated: true)
    }

    /// Only opacity changes here; the controller owns the width. The incoming group
    /// appears a touch later than the outgoing one leaves, so they never muddle together.
    private func applyVisibility(animated: Bool) {
        let target = mode
        let groups: [(views: [NSView], visible: Bool)] = [
            ([idleButton], mode == .idle),
            (presetButtons + [closeButton], mode == .picking),
            ([runButton], mode == .running),
        ]
        for group in groups {
            for view in group.views {
                if !animated {
                    view.alphaValue = group.visible ? 1 : 0
                    view.isHidden = !group.visible
                    continue
                }
                if group.visible { view.isHidden = false }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = group.visible ? 0.24 : 0.14
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    view.animator().alphaValue = group.visible ? 1 : 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        // Only if nothing changed meanwhile: a stale completion from a quick
                        // running → idle switch used to hide the idle button for good.
                        guard let self, self.mode == target else { return }
                        if !group.visible { view.isHidden = true }
                    }
                }
            }
        }
        needsLayout = true
    }

    // MARK: - Running

    private func tapRunning() {
        // Tapped while flashing: straight back to idle
        if celebrating { endCelebration(); return }
        // Two steps, so a stray touch can't stop the timer
        if let until = confirmUntil, until > Date() {
            confirmUntil = nil
            timer.stop()
        } else {
            confirmUntil = Date().addingTimeInterval(2.5)
            renderRunning()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in self?.renderRunning() }
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderRunning() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func renderRunning() {
        guard timer.isRunning else { return }
        let left = timer.remaining
        let ending = left <= 30
        let confirming = (confirmUntil ?? .distantPast) > Date()

        runButton.text = confirming ? "Stop?" : QuickTimer.clock(left)
        runButton.textColor = confirming ? Theme.claudeError : (ending ? Theme.timerOrange : Theme.textPrimary)
        runButton.fill = confirming ? Theme.claudeError.withAlphaComponent(0.18) : Theme.cardFill

        let fraction = timer.totalSeconds > 0 ? CGFloat(left / timer.totalSeconds) : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        bar.backgroundColor = (ending ? Theme.timerOrange : Theme.timerLime).cgColor
        bar.transform = CATransform3DMakeScale(max(0.001, fraction), 1, 1)
        CATransaction.commit()
    }

    /// Done: the chip keeps its running shape, reads "Done" and flashes green 3 times,
    /// then returns to idle (the ⏱ circle).
    private func celebrate() {
        guard mode == .running else { return }
        celebrating = true
        runButton.text = "Done"
        runButton.textColor = Theme.claudeIdle
        runButton.fill = Theme.cardFill
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.isHidden = true
        barTrack.isHidden = true
        CATransaction.commit()
        runButton.flash(Theme.claudeIdle.withAlphaComponent(0.32), times: Self.flashTimes, period: Self.flashPeriod)

        celebrationEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endCelebration() }
        celebrationEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(Self.flashTimes) * Self.flashPeriod, execute: work)
    }

    private func endCelebration() {
        celebrationEnd?.cancel()
        celebrationEnd = nil
        celebrating = false
        bar.isHidden = false
        barTrack.isHidden = false
        if !timer.isRunning { setMode(.idle) }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let h = bounds.height
        idleButton.frame = CGRect(x: 0, y: 0, width: Self.idleWidth, height: h)

        let pill: CGFloat = 40, gap: CGFloat = 5
        for (i, button) in presetButtons.enumerated() {
            button.frame = CGRect(x: CGFloat(i) * (pill + gap), y: 1, width: pill, height: h - 2)
        }
        let closeX = CGFloat(presetButtons.count) * (pill + gap) + 2
        closeButton.frame = CGRect(x: closeX, y: 0, width: 30, height: h)

        runButton.frame = CGRect(x: 0, y: 0, width: Self.runningWidth, height: h)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // NSButton is flipped: the line sits on the bottom edge
        barTrack.frame = CGRect(x: 10, y: h - 4, width: Self.runningWidth - 20, height: 2)
        bar.bounds = CGRect(x: 0, y: 0, width: Self.runningWidth - 20, height: 2)
        bar.position = CGPoint(x: 10, y: h - 3)
        CATransaction.commit()
    }
}
