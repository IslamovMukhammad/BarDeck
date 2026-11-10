import AppKit
import Observation

/// The quick timer behind the ⏱ chip: pick 5, 10, 15 or 20 minutes on the bar.
///
/// Time is kept as an end date, so it survives sleep and an app restart.
@MainActor
@Observable
final class QuickTimer {
    /// Demo mode keeps its timer out of your real settings.
    static let shared = QuickTimer(defaults: Demo.isOn ? UserDefaults(suiteName: "BarDeckDemo") ?? .standard : .standard)

    static let minMinutes = 1
    static let maxMinutes = 60
    static let presets = [5, 10, 15, 20]

    private(set) var minutes: Int
    private(set) var endsAt: Date?
    private(set) var totalSeconds: TimeInterval = 0

    private var listeners: [(QuickTimer) -> Void] = []
    private var finishListeners: [() -> Void] = []

    private let defaults: UserDefaults
    private var finishWork: DispatchWorkItem?
    /// A second, once-a-second check. `DispatchTime` stops during sleep and can wake a few
    /// milliseconds early; with that alone the timer could sit at 0:00 forever.
    private var watchdog: Timer?

    private enum Keys {
        static let minutes = "quickTimer.minutes"
        static let endsAt = "quickTimer.endsAt"
        static let total = "quickTimer.total"
    }

    var isRunning: Bool { endsAt != nil }
    var remaining: TimeInterval { max(0, endsAt?.timeIntervalSinceNow ?? 0) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Keys.minutes)
        minutes = saved == 0 ? 10 : Self.clamp(saved)
        // A timer that was running when the app quit keeps going.
        let end = defaults.double(forKey: Keys.endsAt)
        if end > Date().timeIntervalSince1970 {
            endsAt = Date(timeIntervalSince1970: end)
            totalSeconds = defaults.double(forKey: Keys.total)
            scheduleFinish()
        }
    }

    func observe(_ listener: @escaping (QuickTimer) -> Void, onFinish finished: @escaping () -> Void) {
        listeners.append(listener)
        finishListeners.append(finished)
        listener(self)
    }

    func start(minutes value: Int? = nil) {
        if let value {
            minutes = Self.clamp(value)
            defaults.set(minutes, forKey: Keys.minutes)
        }
        totalSeconds = TimeInterval(minutes * 60)
        endsAt = Date().addingTimeInterval(totalSeconds)
        persist()
        scheduleFinish()
        publish()
    }

    func stop() {
        finishWork?.cancel()
        watchdog?.invalidate(); watchdog = nil
        endsAt = nil
        totalSeconds = 0
        persist()
        publish()
    }

    private func scheduleFinish() {
        finishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.remaining <= 0.05 else { return }
                self.finish()
            }
        }
        watchdog?.tolerance = 0.3
    }

    private func finish() {
        guard isRunning else { return }
        // Woke up early: schedule again for what is left instead of dropping it.
        if remaining > 0.05 { scheduleFinish(); return }
        watchdog?.invalidate(); watchdog = nil
        endsAt = nil
        totalSeconds = 0
        persist()
        publish()
        Self.playChime()
        finishListeners.forEach { $0() }
    }

    private func publish() { listeners.forEach { $0(self) } }

    private func persist() {
        defaults.set(endsAt?.timeIntervalSince1970 ?? 0, forKey: Keys.endsAt)
        defaults.set(totalSeconds, forKey: Keys.total)
    }

    static func clamp(_ value: Int) -> Int { max(minMinutes, min(maxMinutes, value)) }

    /// "4:58": what the running chip shows. Rounds up, so the last second reads 0:01.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Three times, in step with the chip's green flashes. One sound: mixed sounds read as two signals.
    private static func playChime() {
        for delay in [0.0, 0.52, 1.04] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                (NSSound(named: "Glass")?.copy() as? NSSound)?.play()
            }
        }
    }
}
