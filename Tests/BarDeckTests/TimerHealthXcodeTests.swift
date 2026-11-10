import Foundation
import Testing
@testable import BarDeck

@Suite("Quick timer")
struct QuickTimerTests {

    @Test func clock() {
        #expect(QuickTimer.clock(298) == "4:58")
        #expect(QuickTimer.clock(0.2) == "0:01")   // rounds up: the last second still shows
        #expect(QuickTimer.clock(0) == "0:00")
        #expect(QuickTimer.clock(3600) == "60:00")
    }

    @Test func clamp() {
        #expect(QuickTimer.clamp(0) == 1)
        #expect(QuickTimer.clamp(15) == 15)
        #expect(QuickTimer.clamp(500) == 60)
    }

    @Test func startStopAndRestore() {
        let suite = "BarDeckTests"   // one fixed name, emptied before and after, so runs leave nothing behind
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let timer = QuickTimer(defaults: defaults)
        #expect(!timer.isRunning)
        timer.start(minutes: 5)
        #expect(timer.isRunning)
        #expect(timer.totalSeconds == 300)
        #expect(timer.remaining > 298 && timer.remaining <= 300)
        // A new instance (an app restart) picks the running timer up.
        let restored = QuickTimer(defaults: defaults)
        #expect(restored.isRunning)
        #expect(restored.minutes == 5)
        timer.stop()
        #expect(!timer.isRunning)
        #expect(!QuickTimer(defaults: defaults).isRunning)
    }
}

@Suite("Health edges")
struct HealthTests {

    @Test func gateNeedsFiveSecondsBothWays() {
        var gate = HealthGate(enter: 85, exit: 70)
        let t0 = Date()
        do { let v = gate.feed(90, now: t0); #expect(!v) }
        do { let v = gate.feed(90, now: t0.addingTimeInterval(4)); #expect(!v) }
        do { let v = gate.feed(90, now: t0.addingTimeInterval(5)); #expect(v) }
        // Between exit and enter it stays on.
        do { let v = gate.feed(75, now: t0.addingTimeInterval(20)); #expect(v) }
        do { let v = gate.feed(60, now: t0.addingTimeInterval(21)); #expect(v) }
        do { let v = gate.feed(60, now: t0.addingTimeInterval(26)); #expect(!v) }
        // A short spike doesn't count.
        do { let v = gate.feed(95, now: t0.addingTimeInterval(30)); #expect(!v) }
        do { let v = gate.feed(50, now: t0.addingTimeInterval(32)); #expect(!v) }
        do { let v = gate.feed(95, now: t0.addingTimeInterval(36)); #expect(!v) }
    }

    @Test func heatIsSmoothed() {
        var tracker = HealthTracker()
        let t0 = Date()
        // One 104 °C spike among normal ~90 °C readings doesn't light the edge.
        for second in stride(from: 0, through: 30, by: 2) {
            let temp: Double = second == 10 ? 104 : 90
            let peaks = tracker.feed(HealthSample(cpuPercent: 10, temperature: temp), now: t0.addingTimeInterval(Double(second)))
            #expect(!peaks.heat)
        }
        // A sustained 100 °C does, once the average passes 95 and holds for 5 s.
        var lit = false
        for second in stride(from: 32, through: 80, by: 2) {
            lit = tracker.feed(HealthSample(cpuPercent: 10, temperature: 100), now: t0.addingTimeInterval(Double(second))).heat
        }
        #expect(lit)
    }

    @Test func demoFlag() {
        #expect(HealthPeaks.parse("cpu,heat") == HealthPeaks(cpu: true, heat: true, memory: false))
        #expect(HealthPeaks.parse(" Memory ") == HealthPeaks(cpu: false, heat: false, memory: true))
        #expect(HealthPeaks.parse("nothing") == nil)
        #expect(HealthPeaks.parse(nil) == nil)
    }

    @Test func memoryPeakNeedsRealSwapping() {
        var tracker = HealthTracker()
        let t0 = Date()
        let warningOnly = HealthSample(cpuPercent: 10, swapMBs: 0, memoryPressure: 2, temperature: 50)
        _ = tracker.feed(warningOnly, now: t0)
        do { let v = tracker.feed(warningOnly, now: t0.addingTimeInterval(10)); #expect(!v.memory) }
        let swapping = HealthSample(cpuPercent: 10, swapMBs: 12, memoryPressure: 2, temperature: 50)
        _ = tracker.feed(swapping, now: t0.addingTimeInterval(11))
        do { let v = tracker.feed(swapping, now: t0.addingTimeInterval(17)); #expect(v.memory) }
    }
}

@Suite("Xcode activity text")
struct XcodeParseTests {

    @Test func phases() {
        let fetching = XcodeActivityWatcher.parse("Fetching GRDB.swift (32%)…")
        #expect(fetching.phase == "packages")
        #expect(fetching.text == "Fetching GRDB.swift")
        #expect(fetching.progress == 0.32)

        let building = XcodeActivityWatcher.parse("Building DemoApp | Compiling 12 of 40")
        #expect(building.phase == "building")
        #expect(building.text == "Compiling 12 of 40")
        #expect(building.progress == 0.3)

        #expect(XcodeActivityWatcher.parse("Build Succeeded | Today at 17:40").phase == "succeeded")
        #expect(XcodeActivityWatcher.parse("Build Failed | 3 errors").phase == "failed")
        #expect(XcodeActivityWatcher.parse("Testing DemoApp").phase == "testing")
        #expect(XcodeActivityWatcher.parse("Indexing | Processing files").phase == "idle")
        #expect(XcodeActivityWatcher.parse("Ready").phase == "idle")
    }

    @Test func projectName() {
        #expect(XcodeActivityWatcher.projectName(from: "DemoApp — DemoApp.xcodeproj") == "DemoApp")
    }
}

@Suite("Bar layout")
struct BarLayoutTests {

    @Test func restingBar() {
        let w = TouchBarController.layout(timerGrowth: 0, sliderGrowth: 0, xcodeGrowth: 0)
        #expect(w == .init(music: TouchBarController.musicFullWidth, claude: TouchBarController.claudeFullWidth))
    }

    @Test func sliderIsPaidByClaude() {
        let slider = ExpandingSliderView.expandedWidth - ExpandingSliderView.collapsedWidth   // 144
        let w = TouchBarController.layout(timerGrowth: 0, sliderGrowth: slider, xcodeGrowth: 0)
        #expect(w.claude == TouchBarController.claudeFullWidth - slider)
        #expect(w.music == TouchBarController.musicFullWidth)
    }

    @Test func growthIsPaidByClaudeThenMusic() {
        // Xcode card (214) + an open slider (144). (The timer picker never opens alongside
        // them: either one closes it.)
        let w = TouchBarController.layout(timerGrowth: 0, sliderGrowth: 144, xcodeGrowth: 214)
        #expect(w.claude == 90)
        // The total never changes: whatever grew is exactly what the others gave up.
        #expect((TouchBarController.claudeFullWidth - w.claude) + (TouchBarController.musicFullWidth - w.music) == 358)
    }

    @Test func volumeSymbols() {
        #expect(TouchBarController.volumeSymbol(0) == "speaker.slash.fill")
        #expect(TouchBarController.volumeSymbol(0.2) == "speaker.wave.1.fill")
        #expect(TouchBarController.volumeSymbol(0.5) == "speaker.wave.2.fill")
        #expect(TouchBarController.volumeSymbol(0.9) == "speaker.wave.3.fill")
    }
}
