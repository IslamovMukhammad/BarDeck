import AppKit

extension NSTouchBarItem.Identifier {
    static let tray        = NSTouchBarItem.Identifier("com.bardeck.tray")
    static let nowPlaying  = NSTouchBarItem.Identifier("com.bardeck.nowPlaying")
    static let previous    = NSTouchBarItem.Identifier("com.bardeck.previous")
    static let playPause   = NSTouchBarItem.Identifier("com.bardeck.playPause")
    static let next        = NSTouchBarItem.Identifier("com.bardeck.next")
    static let claude      = NSTouchBarItem.Identifier("com.bardeck.claude")
    static let brightness  = NSTouchBarItem.Identifier("com.bardeck.brightness")
    static let volume      = NSTouchBarItem.Identifier("com.bardeck.volume")
    static let quickTimer  = NSTouchBarItem.Identifier("com.bardeck.quickTimer")
    static let xcode       = NSTouchBarItem.Identifier("com.bardeck.xcode")
}

/// Owns the strip: builds the items, keeps every view fed from the services, and does the
/// width bookkeeping when something on the bar grows.
///
/// The one layout rule ("the totals cancel"): whatever grows (the timer picker, a slider, the
/// Xcode card) is paid for by the Claude card shrinking by exactly that much (then the music
/// card, once Claude is at its floor), in the same animation. The sum never changes, so the bar never overflows.
@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {

    private(set) var isPresented = false

    private var touchBar: NSTouchBar?
    private var trayItem: NSCustomTouchBarItem?

    let nowPlayingView = NowPlayingView()
    private let claudeView = ClaudeStatusView()
    let timerChip = TimerChipView()
    private let xcodeView = XcodeCardView()
    private let previousButton = IconButton()
    private let playPauseButton = IconButton()
    private let nextButton = IconButton()
    let brightnessSlider = ExpandingSliderView()
    let volumeSlider = ExpandingSliderView()
    private let trayView = TrayView()
    private let healthOverlay = HealthEdgeOverlay()

    let music = SpotifyService()
    private let claude = ClaudeFeed.shared
    private let audio = SystemVolume()
    private let display = SystemBrightness()
    private let xcode = XcodeActivityWatcher()
    private let sampler = HealthSampler()
    private var health = HealthTracker()
    /// Demo mode forces the edge glow on (BARDECK_DEMO_HEALTH) instead of reading this Mac.
    var demoPeaks: HealthPeaks?

    static let musicFullWidth: CGFloat = 250
    static let claudeFullWidth: CGFloat = 300
    private var musicWidth: NSLayoutConstraint?
    private var claudeWidth: NSLayoutConstraint?
    private var timerWidth: NSLayoutConstraint?
    private var xcodeWidth: NSLayoutConstraint?
    /// Kept so the transport controls can fold away when playback pauses.
    private var previousWidth: NSLayoutConstraint?
    private var nextWidth: NSLayoutConstraint?
    private var transportCollapsed = false

    private var timerGrowth: CGFloat = 0
    private var sliderGrowth: CGFloat = 0
    private var xcodeGrowth: CGFloat = 0

    private var ticker: Timer?
    private var tickCount = 0
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private var settings: AppSettings { AppSettings.shared }

    // MARK: - Lifecycle

    func start() {
        buildItems()
        wireServices()

        DFR.showsCloseBoxWhenFrontMost(false)
        installTrayItem()
        present()
        observeSystemEvents()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if !Demo.isOn {
            music.start()
            xcode.start()
        }
        refreshVolume()
        refreshBrightness()
        sampleHealth()
    }

    func stop() {
        ticker?.invalidate()
        music.stop()
        xcode.stop()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        dismiss()
        if let trayItem { NSTouchBarItem.removeFromSystemTray(trayItem) }
        DFR.setControlStripPresence(NSTouchBarItem.Identifier.tray.rawValue, present: false)
    }

    // MARK: - Presentation

    func present() {
        let bar = touchBar ?? makeTouchBar()
        touchBar = bar
        let ok = NSTouchBar.presentSystemModal(bar, placement: 1, systemTrayItemIdentifier: .tray)
        isPresented = ok
        if !ok { NSLog("[BarDeck] presentSystemModalTouchBar failed: the private selector did not respond") }
        // The bar's window appears a moment later (or is rebuilt after wake): re-attach the
        // edge glow to the new window, or a peak in progress would stay invisible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.applyHealthEdges()
        }
    }

    func dismiss() {
        guard let touchBar else { return }
        NSTouchBar.dismissSystemModal(touchBar)
        isPresented = false
    }

    func toggle() { isPresented ? dismiss() : present() }

    /// macOS hands the strip back to whichever app just became active, and it tears the modal
    /// bar down across sleep. Re-assert ourselves both times so the bar is there no matter
    /// what is in front.
    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repossess() }
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repossess() }
        }
    }

    private func repossess() {
        guard isPresented else { return }
        // A short delay lets the incoming app install its own bar first, so we land on top of it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.isPresented, let bar = self.touchBar else { return }
            NSTouchBar.presentSystemModal(bar, placement: 1, systemTrayItemIdentifier: .tray)
        }
    }

    private func installTrayItem() {
        let item = NSCustomTouchBarItem(identifier: .tray)
        trayView.onTap = { [weak self] in self?.toggle() }
        item.view = trayView
        trayItem = item
        let added = NSTouchBarItem.addToSystemTray(item)
        if !added { NSLog("[BarDeck] addSystemTrayItem: failed: the private selector did not respond") }
        DFR.setControlStripPresence(NSTouchBarItem.Identifier.tray.rawValue, present: true)
    }

    private func makeTouchBar() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = itemIdentifiers()
        return bar
    }

    /// The bar's items, minus whatever Settings turned off.
    private func itemIdentifiers() -> [NSTouchBarItem.Identifier] {
        var ids: [NSTouchBarItem.Identifier] = []
        if settings.showMusic { ids += [.nowPlaying, .previous, .playPause, .next] }
        ids.append(.flexibleSpace)
        if settings.showClaude { ids.append(.claude) }
        if settings.showTimer { ids.append(.quickTimer) }
        if settings.showXcode { ids.append(.xcode) }
        ids.append(.flexibleSpace)
        if settings.showBrightness { ids.append(.brightness) }
        if settings.showVolume { ids.append(.volume) }
        return ids
    }

    // MARK: - Item construction

    private func buildItems() {
        musicWidth = constrain(nowPlayingView, width: Self.musicFullWidth)
        xcodeWidth = constrain(xcodeView, width: 0)
        claudeWidth = constrain(claudeView, width: Self.claudeFullWidth)
        timerWidth = constrain(timerChip, width: TimerChipView.idleWidth)
        timerChip.onWidthChange = { [weak self] width in self?.resizeTimer(to: width) }
        timerChip.reportWidth()
        previousWidth = constrain(previousButton, width: 42)
        constrain(playPauseButton, width: 46)
        nextWidth = constrain(nextButton, width: 42)
        // The system's own control-strip root view sometimes imposes its own width on this one
        // (e.g. while the strip is reconfiguring), so this constraint must be free to lose that
        // fight quietly instead of spamming "unsatisfiable constraints".
        constrain(trayView, width: 68, priority: .defaultHigh)

        previousButton.setSymbol("backward.fill")
        playPauseButton.setSymbol("play.fill")
        nextButton.setSymbol("forward.fill")
        previousButton.onTap  = { [weak self] in self?.music.perform(.previous) }
        playPauseButton.onTap = { [weak self] in self?.music.perform(.playPause) }
        nextButton.onTap      = { [weak self] in self?.music.perform(.next) }
        nowPlayingView.onOpenApp = { [weak self] in self?.music.activateApp() }

        configureSlider(brightnessSlider, accent: Self.brightnessAccent) { value in
            value < 0.5 ? "sun.min.fill" : "sun.max.fill"
        } apply: { [weak self] value in
            self?.display.brightness = Float(value)
            EdgeHUD.shared.show(.brightness, value: value)
        }

        configureSlider(volumeSlider, accent: Self.volumeAccent) { value in
            Self.volumeSymbol(value)
        } apply: { [weak self] value in
            self?.audio.volume = Float(value)
            EdgeHUD.shared.show(.volume, value: value, muted: value <= 0.001)
        }
    }

    static func volumeSymbol(_ value: Double) -> String {
        if value <= 0.001 { return "speaker.slash.fill" }
        if value < 0.34 { return "speaker.wave.1.fill" }
        if value < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private static let volumeAccent = NSColor(srgbRed: 0.35, green: 0.72, blue: 1.0, alpha: 1)
    private static let brightnessAccent = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.4, alpha: 1)

    private func configureSlider(_ slider: ExpandingSliderView, accent: NSColor,
                                 symbol: @escaping (Double) -> String,
                                 apply: @escaping (Double) -> Void) {
        let width = constrain(slider, width: ExpandingSliderView.collapsedWidth)
        slider.install(widthConstraint: width)
        slider.configure(accent: accent, symbolProvider: symbol)
        slider.onChange = apply
        slider.onExpandedChange = { [weak self] expanded in
            guard let self else { return }
            if expanded {
                // Pressing one control must never leave the other one open.
                let sibling = slider === self.volumeSlider ? self.brightnessSlider : self.volumeSlider
                sibling.collapseNow()
                // The timer picker and an open slider don't both fit.
                self.timerChip.collapsePicker()
                // The on-screen indicator follows the slider: shown while open, gone when closed.
                if slider === self.volumeSlider {
                    EdgeHUD.shared.begin(.volume, value: self.audio.isMuted ? 0 : Double(self.audio.volume), muted: self.audio.isMuted)
                } else {
                    EdgeHUD.shared.begin(.brightness, value: Double(self.display.brightness))
                }
            } else {
                EdgeHUD.shared.end()
            }
            self.sliderGrowth = expanded ? ExpandingSliderView.expandedWidth - ExpandingSliderView.collapsedWidth : 0
            self.relayout()
        }
    }

    @discardableResult
    private func constrain(_ view: NSView, width: CGFloat,
                           priority: NSLayoutConstraint.Priority = .required) -> NSLayoutConstraint {
        view.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = view.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.priority = priority
        widthConstraint.isActive = true
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: Theme.barHeight)
        heightConstraint.priority = priority
        heightConstraint.isActive = true
        return widthConstraint
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let view: NSView? = switch identifier {
        case .nowPlaying: nowPlayingView
        case .previous:   previousButton
        case .playPause:  playPauseButton
        case .next:       nextButton
        case .claude:     claudeView
        case .quickTimer: timerChip
        case .xcode:      xcodeView
        case .brightness: brightnessSlider
        case .volume:     volumeSlider
        default:          nil
        }
        guard let view else { return nil }
        // Views are reused across layout changes: one must never still be parented to an old item.
        view.removeFromSuperview()
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = view
        return item
    }

    // MARK: - Service wiring

    private func wireServices() {
        music.onChange = { [weak self] np in
            guard let self else { return }
            self.nowPlayingView.update(np)
            self.playPauseButton.setSymbol(np.isPlaying ? "pause.fill" : "play.fill")
            self.trayView.setArtworkURL(np.artworkURL)
            self.setTransportCollapsed(!np.isPlaying)
        }
        // Draw the starting state once (nothing playing: the skip buttons start folded).
        music.onChange?(music.nowPlaying)
        claude.onChange = { [weak self] state in
            guard let self else { return }
            self.claudeView.update(state)
            self.trayView.setStatusColor(state.activity.color, pulsing: state.activity.pulses)
            StatusTint.shared.set(state.activity.color)
        }
        xcode.onChange = { [weak self] message in self?.updateXcode(message) }
        audio.onChange = { [weak self] _, _ in self?.refreshVolume() }
        settings.onTouchBar = { [weak self] in self?.applySettings() }
    }

    /// A setting changed: rebuild the item list and re-run the layout.
    func applySettings() {
        if !settings.showTimer { timerChip.collapsePicker(); timerGrowth = 0 }
        if !settings.showBrightness { brightnessSlider.collapseNow() }
        if !settings.showVolume { volumeSlider.collapseNow() }
        touchBar?.defaultItemIdentifiers = itemIdentifiers()
        claude.republish()
        relayout()
        applyHealthEdges()
    }

    /// Dynamic-Island-style morph: when playback stops, the skip controls shrink into the play
    /// button and disappear; starting playback springs them back out. Animating the width
    /// constraints (rather than swapping items) is what makes it read as one continuous shape.
    private func setTransportCollapsed(_ collapsed: Bool) {
        guard collapsed != transportCollapsed else { return }
        transportCollapsed = collapsed
        NSAnimationContext.runAnimationGroup { context in
            // Collapsing is a quick ease-out; opening keeps a light bounce.
            context.duration = collapsed ? 0.26 : 0.44
            context.timingFunction = collapsed
                ? CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                : CAMediaTimingFunction(controlPoints: 0.2, 1.35, 0.4, 1)
            previousWidth?.animator().constant = collapsed ? 0 : 42
            nextWidth?.animator().constant = collapsed ? 0 : 42
            previousButton.animator().alphaValue = collapsed ? 0 : 1
            nextButton.animator().alphaValue = collapsed ? 0 : 1
        }
    }

    private func resizeTimer(to width: CGFloat) {
        guard settings.showTimer else { return }
        timerGrowth = width - TimerChipView.idleWidth
        // Opening the picker closes an open slider: one at a time.
        if width >= TimerChipView.pickingWidth {
            brightnessSlider.collapseNow()
            volumeSlider.collapseNow()
            sliderGrowth = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ExpandingSliderView.motionDuration
            context.timingFunction = ExpandingSliderView.motionCurve
            context.allowsImplicitAnimation = true
            timerWidth?.animator().constant = width
        }
        relayout()
    }

    /// The single width calculation for the bar (see the class comment).
    private func relayout() {
        let widths = Self.layout(timerGrowth: timerGrowth, sliderGrowth: sliderGrowth, xcodeGrowth: xcodeGrowth,
)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ExpandingSliderView.motionDuration
            context.timingFunction = ExpandingSliderView.motionCurve
            musicWidth?.animator().constant = widths.music
            claudeWidth?.animator().constant = widths.claude
            xcodeWidth?.animator().constant = xcodeGrowth
        }
    }

    struct Widths: Equatable {
        var music: CGFloat
        var claude: CGFloat
    }

    /// Pure, unit-tested. Whatever grows is paid for by the Claude card (down to 90pt),
    /// then by the music card.
    static func layout(timerGrowth: CGFloat, sliderGrowth: CGFloat, xcodeGrowth: CGFloat) -> Widths {
        let growth = timerGrowth + sliderGrowth + xcodeGrowth
        let claudeFloor: CGFloat = 90
        let wanted = claudeFullWidth - growth
        let claude = max(claudeFloor, wanted)
        let music = max(NowPlayingView.minimumWidth, musicFullWidth - max(0, claudeFloor - wanted))
        return Widths(music: music, claude: claude)
    }

    // MARK: - Xcode

    /// The Xcode card appears while Xcode is busy and takes its room from the Claude card.
    func updateXcode(_ message: XcodeMessage) {
        let shown = message.phase != "idle" && settings.showXcode
        if shown { xcodeView.update(message) }
        guard shown != xcodeView.isShown else { return }
        xcodeGrowth = shown ? XcodeCardView.width : 0
        if shown { timerChip.collapsePicker() }
        relayout()
        xcodeView.setShown(shown)
    }

    // MARK: - Health edges

    private func tick() {
        tickCount += 1
        nowPlayingView.tickProgress()
        refreshBrightness()
        if tickCount % 4 == 0 { sampleHealth() }   // every 2 s
    }

    /// CPU, swap and temperature are never shown as numbers: they only light the edges.
    private func sampleHealth() {
        let peaks = demoPeaks ?? health.feed(sampler.sample())
        if peaks != currentPeaks {
            currentPeaks = peaks
            applyHealthEdges()
        }
    }

    private var currentPeaks = HealthPeaks()

    private func applyHealthEdges() {
        attachHealthOverlay()
        let peaks = settings.healthEdges ? currentPeaks : HealthPeaks()
        healthOverlay.set(cpu: peaks.cpu, heat: peaks.heat, memory: peaks.memory)
    }

    /// The overlay sits on the Touch Bar window's root view, above everything. The root can
    /// change when the bar is presented again, so it is checked every time.
    private func attachHealthOverlay() {
        let anchors: [NSView] = [nowPlayingView, claudeView, timerChip, volumeSlider, brightnessSlider]
        guard let root = anchors.lazy.compactMap({ $0.window?.contentView }).first else { return }
        if healthOverlay.superview !== root {
            healthOverlay.removeFromSuperview()
            healthOverlay.frame = root.bounds
            healthOverlay.autoresizingMask = [.width, .height]
            root.addSubview(healthOverlay, positioned: .above, relativeTo: nil)
        } else if root.subviews.last !== healthOverlay {
            root.addSubview(healthOverlay, positioned: .above, relativeTo: nil)
        }
    }

    private func refreshVolume() {
        volumeSlider.setValue(audio.isMuted ? 0 : Double(audio.volume))
    }

    private func refreshBrightness() {
        guard display.isAvailable else { return }
        brightnessSlider.setValue(Double(display.brightness))
    }
}

/// The little widget that lives in the Control Strip when the full bar is dismissed:
/// the current cover plus a Claude status lamp. Tap it to bring the bar back.
final class TrayView: TBCard {

    private let lamp = CALayer()
    private let art = CALayer()
    /// Real `NSButton` tracking: see `IconButton` for why a raw `NSView` mouse override
    /// doesn't reliably fire inside the Control Strip either.
    private let tapCatcher = NSButton()
    private var artworkURL = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        showsAccent = false
        setBackgroundColor(.clear, animated: false)

        art.cornerRadius = 4
        art.masksToBounds = true
        art.contentsGravity = .resizeAspectFill
        art.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
        layer?.addSublayer(art)

        lamp.cornerRadius = 3
        lamp.backgroundColor = Theme.claudeOffline.cgColor
        lamp.shadowRadius = 4
        lamp.shadowOpacity = 0.9
        lamp.shadowOffset = .zero
        layer?.addSublayer(lamp)

        tapCatcher.isBordered = false
        tapCatcher.title = ""
        tapCatcher.imagePosition = .noImage
        tapCatcher.target = self
        tapCatcher.action = #selector(handleTap)
        addSubview(tapCatcher)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func handleTap() { onTap?() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = CGRect(x: 6, y: (bounds.height - 20) / 2, width: 20, height: 20)
        lamp.frame = CGRect(x: art.frame.maxX + 9, y: bounds.midY - 3, width: 6, height: 6)
        CATransaction.commit()
        tapCatcher.frame = bounds
    }

    func setArtworkURL(_ url: String) {
        guard url != artworkURL else { return }
        artworkURL = url
        ArtworkCache.shared.image(for: url) { [weak self] image in
            guard let self, self.artworkURL == url else { return }
            self.art.contents = image
        }
    }

    func setStatusColor(_ color: NSColor, pulsing: Bool) {
        lamp.backgroundColor = color.cgColor
        lamp.shadowColor = color.cgColor
        lamp.removeAnimation(forKey: "pulse")
        guard pulsing else { lamp.shadowOpacity = 0.6; return }
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.2
        pulse.toValue = 1.0
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        lamp.add(pulse, forKey: "pulse")
    }
}
