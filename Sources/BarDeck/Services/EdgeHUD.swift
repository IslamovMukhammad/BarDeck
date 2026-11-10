import AppKit
import Combine
import SwiftUI

/// The volume and brightness indicator: a Liquid Glass column in the middle of the screen's
/// right edge.
///
/// macOS 26+ no longer shows the system's own indicator for other apps (the modern one needs
/// Apple's private `com.apple.private.system-banner-client` entitlement), so BarDeck draws its own.
///
/// Safeguards:
///   · one panel is reused for the app's whole life, never a new window per change;
///   · the panel never takes focus, lets the mouse through, and is ordered out while hidden;
///   · every show bumps a generation number, so an old timer can't close a newer indicator;
///   · spring animations: a new value arriving mid-close turns it around from where it is;
///   · with Reduce Motion on, only fades, no sliding.
@MainActor
final class EdgeHUD {
    static let shared = EdgeHUD()

    enum Kind { case volume, brightness }

    private let model = EdgeHUDModel()
    private var panel: NSPanel?
    private var generation = 0
    /// While a Touch Bar slider is open, the indicator stays: it doesn't thin out or close.
    private var held = false

    /// When it thins out and when it closes (after the last change)
    private let thinAfter: TimeInterval = 1.0
    private let hideAfter: TimeInterval = 1.8

    private static let panelSize = NSSize(width: 150, height: 240)

    /// A Touch Bar slider opened: the indicator shows at once and stays until the slider closes.
    func begin(_ kind: Kind, value: Double, muted: Bool = false) {
        held = true
        show(kind, value: value, muted: muted)
    }

    /// The Touch Bar slider closed: the indicator slides away right then.
    func end() {
        guard held else { return }
        held = false
        generation += 1
        hide(generation: generation)
    }

    func show(_ kind: Kind, value: Double, muted: Bool = false) {
        generation += 1
        let current = generation
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let clamped = min(1, max(0, value))

        let panel = ensurePanel()
        if !model.shown {
            place(panel)
            panel.orderFrontRegardless()
        }

        // One "bump" when it hits a limit
        let hitLimit = (clamped >= 1 && model.value < 1) || (clamped <= 0 && model.value > 0)
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            model.kind = kind
            model.value = clamped
            model.muted = muted
        }
        if hitLimit && !reduceMotion { model.pulse += 1 }

        if !model.shown {
            model.reduceMotion = reduceMotion
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.1)) { model.shown = true }
        }
        if model.thin {
            withAnimation(.spring(duration: 0.45, bounce: 0)) { model.thin = false }
        }

        guard !held else { return }      // a slider is open: no timed close
        DispatchQueue.main.asyncAfter(deadline: .now() + thinAfter) { [weak self] in
            guard let self, self.generation == current, !self.held, self.model.shown else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0)) { self.model.thin = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self] in
            guard let self, self.generation == current, !self.held else { return }
            self.hide(generation: current)
        }
    }

    private func hide(generation current: Int) {
        let reduceMotion = model.reduceMotion
        withAnimation(reduceMotion ? .easeIn(duration: 0.2) : .spring(duration: 0.4, bounce: 0)) { model.shown = false }
        // Order the panel out after the animation, unless something was shown meanwhile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.generation == current, !self.model.shown else { return }
            self.panel?.orderOut(nil)
            self.model.thin = false
        }
    }

    // MARK: Panel

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: EdgeHUDView(model: model))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// On the right edge of the screen the mouse is on: where your eyes are
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.panelSize.width, y: frame.midY - Self.panelSize.height / 2))
    }
}

final class EdgeHUDModel: ObservableObject {
    @Published var kind: EdgeHUD.Kind = .volume
    @Published var value = 0.0
    @Published var muted = false
    @Published var shown = false
    @Published var thin = false
    @Published var pulse = 0
    @Published var reduceMotion = false
}

private struct EdgeHUDView: View {
    @ObservedObject var model: EdgeHUDModel

    private let height: CGFloat = 186
    /// The icon centre's height above the column bottom, and the icon box
    private let iconBottom: CGFloat = 23
    private let iconBox: CGFloat = 18

    var body: some View {
        let width: CGFloat = model.thin ? 12 : 46
        let level = model.muted ? 0 : model.value
        ZStack(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.16))
            // The filled part is exactly proportional; the column's own shape clips its rounded bottom.
            Rectangle().fill(.white).frame(height: height * level)
            if !model.thin {
                // Two icon layers: white over the empty part, black over the filled part; the boundary crosses the icon
                ZStack {
                    icon.foregroundStyle(.white.opacity(0.9))
                    icon.foregroundStyle(.black.opacity(0.72))
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: max(0, height * level - iconBottom + iconBox / 2))
                        }
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(height: iconBox)
                .padding(.bottom, iconBottom - iconBox / 2)
                .symbolEffect(.bounce, value: model.pulse)
                .transition(.opacity)
            }
        }
        .frame(width: width - (model.thin ? 4 : 12), height: height)
        .clipShape(Capsule())
        .padding(model.thin ? 2 : 6)
        .glassEffect(.regular, in: .capsule)
        .keyframeAnimator(initialValue: 0.0, trigger: model.pulse) { view, v in
            view.scaleEffect(x: 1 - 0.03 * v, y: 1 + 0.025 * v, anchor: .bottom)
        } keyframes: { _ in
            LinearKeyframe(1, duration: 0.07)
            SpringKeyframe(0, duration: 0.4, spring: .init(duration: 0.4, bounce: 0.35))
        }
        .offset(x: model.shown || model.reduceMotion ? 0 : 74)
        .opacity(model.shown ? 1 : 0)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        switch model.kind {
        case .volume:
            if model.muted || model.value <= 0.001 {
                Image(systemName: "speaker.slash.fill")
            } else {
                Image(systemName: "speaker.wave.3.fill", variableValue: model.value)
            }
        case .brightness:
            Image(systemName: "sun.max.fill", variableValue: model.value)
        }
    }
}
