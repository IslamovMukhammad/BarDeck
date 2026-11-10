import AppKit

/// Album art, a scrolling title/artist pair, and a progress line — all tinted
/// with the dominant colour of the cover, which also washes the card's
/// background in a fade that dies out toward the right edge.
final class NowPlayingView: TBCard {

    private let colorWash = CAGradientLayer()
    private let artwork = CALayer()
    private let artworkGlow = CALayer()
    private let pauseOverlay = CALayer()
    private let pauseGlyph = CALayer()
    private let title = MarqueeTextLayer()
    private let subtitle = MarqueeTextLayer()
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let placeholder = CATextLayer()

    /// A transparent, borderless button spanning the whole card. Real
    /// `NSButton` tracking is what reliably receives touches inside the
    /// Touch Bar's remote-hosted view bridge — the drag-to-seek gesture this
    /// view used to have relied on custom mouse tracking that turned out not
    /// to be, so tapping to open Spotify is what survives; seeking is
    /// still possible from inside Spotify itself.
    private let tapCatcher = NSButton()

    private var currentArtworkURL = ""
    private var coverColor: NSColor = Theme.coverDefault
    private var track = NowPlaying()

    var onOpenApp: (() -> Void)?

    /// The narrowest the card gets when the rest of the bar needs room: just the cover.
    static let minimumWidth: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        showsAccent = false   // the progress line lives where the accent would

        colorWash.startPoint = CGPoint(x: 0, y: 0.5)
        colorWash.endPoint = CGPoint(x: 1, y: 0.5)
        colorWash.colors = [Theme.coverDefault.withAlphaComponent(0.28).cgColor,
                            Theme.coverDefault.withAlphaComponent(0.0).cgColor]
        colorWash.locations = [0, 0.85]
        layer?.addSublayer(colorWash)

        artworkGlow.cornerRadius = 5
        artworkGlow.cornerCurve = .continuous
        artworkGlow.shadowOpacity = 0.9
        artworkGlow.shadowRadius = 5
        artworkGlow.shadowOffset = .zero
        layer?.addSublayer(artworkGlow)

        artwork.cornerRadius = 5
        artwork.cornerCurve = .continuous
        artwork.masksToBounds = true
        artwork.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        artwork.contentsGravity = .resizeAspectFill
        artwork.borderWidth = 1
        artwork.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        layer?.addSublayer(artwork)

        pauseOverlay.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        pauseOverlay.opacity = 0
        layer?.addSublayer(pauseOverlay)

        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        pauseGlyph.contents = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.tinted(with: .white)
        pauseGlyph.contentsGravity = .resizeAspect
        pauseGlyph.contentsScale = 2
        pauseGlyph.opacity = 0
        layer?.addSublayer(pauseGlyph)

        title.font = Theme.font(11.5, .semibold)
        title.textColor = Theme.textPrimary
        subtitle.font = Theme.font(9.5, .medium)
        subtitle.textColor = Theme.textSecondary
        layer?.addSublayer(title)
        layer?.addSublayer(subtitle)

        progressTrack.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor
        progressTrack.cornerRadius = 1
        progressFill.cornerRadius = 1
        progressFill.backgroundColor = coverColor.cgColor
        layer?.addSublayer(progressTrack)
        layer?.addSublayer(progressFill)

        placeholder.contentsScale = 2
        placeholder.string = NSAttributedString(
            string: "Spotify",
            attributes: [.font: Theme.font(11, .medium), .foregroundColor: Theme.textTertiary])
        layer?.addSublayer(placeholder)

        tapCatcher.isBordered = false
        tapCatcher.title = ""
        tapCatcher.imagePosition = .noImage
        tapCatcher.target = self
        tapCatcher.action = #selector(handleTap)
        addSubview(tapCatcher)
    }

    @objc private func handleTap() { onOpenApp?() }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        colorWash.frame = bounds

        let side: CGFloat = 22
        let artRect = CGRect(x: 6, y: (bounds.height - side) / 2, width: side, height: side)
        artwork.frame = artRect
        artworkGlow.frame = artRect
        pauseOverlay.frame = artRect
        pauseOverlay.cornerRadius = 5
        pauseOverlay.masksToBounds = true
        let glyphSide: CGFloat = 9
        pauseGlyph.frame = CGRect(x: artRect.midX - glyphSide / 2, y: artRect.midY - glyphSide / 2,
                                  width: glyphSide, height: glyphSide)

        let textX = artRect.maxX + 9
        let textWidth = max(0, bounds.width - textX - 10)
        title.frame = CGRect(x: textX, y: 4, width: textWidth, height: 13)
        subtitle.frame = CGRect(x: textX, y: 16, width: textWidth, height: 11)
        placeholder.frame = CGRect(x: textX, y: 9, width: textWidth, height: 14)

        let lineY = bounds.height - 3.0
        progressTrack.frame = CGRect(x: 7, y: lineY, width: max(0, bounds.width - 14), height: 2)
        layoutProgress(animated: false)
        CATransaction.commit()

        tapCatcher.frame = bounds
    }

    private func layoutProgress(animated: Bool) {
        let width = max(0, progressTrack.frame.width * CGFloat(track.progress))
        let target = CGRect(x: progressTrack.frame.minX, y: progressTrack.frame.minY,
                            width: width, height: 2)
        if animated {
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = progressFill.bounds.width
            animation.toValue = width
            animation.duration = 0.45
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            progressFill.add(animation, forKey: "grow")
        }
        progressFill.frame = target
    }

    // MARK: - Content

    func update(_ np: NowPlaying) {
        let wasPlaying = track.isPlaying
        track = np
        let empty = np.isEmpty

        placeholder.isHidden = !empty
        title.isHidden = empty
        subtitle.isHidden = empty
        progressTrack.isHidden = empty
        progressFill.isHidden = empty

        title.text = np.title
        subtitle.text = np.artist.isEmpty ? np.album : np.artist

        if np.artworkURL != currentArtworkURL {
            currentArtworkURL = np.artworkURL
            ArtworkCache.shared.image(for: np.artworkURL) { [weak self] image in
                guard let self, self.currentArtworkURL == np.artworkURL else { return }
                self.setArtwork(image)
            }
        }

        if wasPlaying != np.isPlaying { setPaused(!np.isPlaying, animated: true) }
        tickProgress(animated: false)
    }

    private func setPaused(_ paused: Bool, animated: Bool) {
        let overlayTarget: Float = (paused && !track.isEmpty) ? 1 : 0
        let artTarget: Float = paused ? 0.55 : 1.0
        let duration = animated ? 0.3 : 0
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        pauseOverlay.opacity = overlayTarget
        pauseGlyph.opacity = overlayTarget
        artwork.opacity = artTarget
        CATransaction.commit()
    }

    /// Called on a timer so the bar creeps forward smoothly between the
    /// sparse position updates the player hands us.
    func tickProgress(animated: Bool = true) {
        guard !track.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        layoutProgress(animated: animated)
        CATransaction.commit()
    }

    private func setArtwork(_ image: NSImage?) {
        guard let image else {
            artwork.contents = nil
            artworkGlow.shadowColor = NSColor.clear.cgColor
            return
        }
        artwork.contents = image
        coverColor = image.dominantColor() ?? Theme.coverDefault
        artworkGlow.shadowColor = coverColor.cgColor

        let barColor = CABasicAnimation(keyPath: "backgroundColor")
        barColor.fromValue = progressFill.backgroundColor
        barColor.toValue = coverColor.cgColor
        barColor.duration = 0.4
        progressFill.add(barColor, forKey: "tint")
        progressFill.backgroundColor = coverColor.cgColor

        let washColors = [coverColor.withAlphaComponent(0.30).cgColor,
                          coverColor.withAlphaComponent(0.0).cgColor]
        let washAnim = CABasicAnimation(keyPath: "colors")
        washAnim.fromValue = colorWash.colors
        washAnim.toValue = washColors
        washAnim.duration = 0.5
        colorWash.add(washAnim, forKey: "wash")
        colorWash.colors = washColors
    }

}

extension NSImage {
    /// Average colour of the cover, pushed toward something vivid enough to
    /// read as an accent on a black strip.
    func dominantColor() -> NSColor? {
        guard let tiff = tiffRepresentation,
              let source = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let size = 12
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var total = (r: 0.0, g: 0.0, b: 0.0)
        var weight = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            // Weight saturated pixels higher so grey cover borders do not win.
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
            let w = 0.15 + saturation
            total.r += r * w; total.g += g * w; total.b += b * w; weight += w
        }
        guard weight > 0 else { return nil }

        let base = NSColor(srgbRed: total.r / weight, green: total.g / weight, blue: total.b / weight, alpha: 1)
        guard let hsb = base.usingColorSpace(.sRGB) else { return base }
        return NSColor(hue: hsb.hueComponent,
                       saturation: min(1, hsb.saturationComponent * 1.5 + 0.15),
                       brightness: max(0.7, hsb.brightnessComponent),
                       alpha: 1)
    }
}
