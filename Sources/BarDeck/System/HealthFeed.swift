import Foundation

/// One reading: only what the edge glow needs. (Ported from the author's system monitor.)
struct HealthSample: Equatable {
    var cpuPercent: Double = 0
    /// Swap read + written right now (MB/s): this, not the size, is what makes a Mac stutter.
    var swapMBs: Double = 0
    /// macOS's own verdict: 1 normal, 2 warning, 4 critical.
    var memoryPressure: Int = 1
    /// Hottest CPU sensor, °C. nil when the SMC can't be read.
    var temperature: Double?
}

/// Samples CPU, memory pressure, swap traffic and temperature. Cheap enough to run every 2 s.
@MainActor
final class HealthSampler {

    private var previousCPU: host_cpu_load_info?
    private var lastSwap: (ins: UInt64, outs: UInt64, at: Date)?
    private let smc = SMCReader()
    private var cachedTemperature: Double?
    private var lastSensorSample: Date?

    func sample() -> HealthSample {
        HealthSample(cpuPercent: cpu(), swapMBs: swapRate(),
                     memoryPressure: Self.memoryPressure(), temperature: temperature())
    }

    private func cpu() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var load = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer { previousCPU = load }
        guard let prev = previousCPU else { return 0 }
        let user = Double(load.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(load.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(load.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(load.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return max(0, min(100, (user + system + nice) / total * 100))
    }

    private static let pageSize: Int = {
        var size = 0
        var length = MemoryLayout<Int>.size
        return sysctlbyname("hw.pagesize", &size, &length, nil, 0) == 0 ? size : 16_384
    }()

    private func swapRate() -> Double {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let now = Date()
        defer { lastSwap = (stats.swapins, stats.swapouts, now) }
        guard let last = lastSwap else { return 0 }
        let seconds = max(0.5, now.timeIntervalSince(last.at))
        let pages = Double((stats.swapins &- last.ins) &+ (stats.swapouts &- last.outs))
        return max(0, pages * Double(Self.pageSize) / 1_048_576 / seconds)
    }

    private static func memoryPressure() -> Int {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return Int(level)
    }

    /// The SMC is read at most every 3 s: it is dozens of IOKit calls.
    private func temperature() -> Double? {
        if let last = lastSensorSample, Date().timeIntervalSince(last) < 3 { return cachedTemperature }
        lastSensorSample = Date()
        cachedTemperature = smc?.read().temperature
        return cachedTemperature
    }
}

/// Is the Mac at a CPU or heat peak, or stuck swapping? One decision with hysteresis, used for
/// the glowing edges around the whole bar.
///
///   CPU:    ≥ 85 % for 5 s → on; < 70 % for 5 s → off
///   Heat:   10-second smoothed average ≥ 95 °C for 5 s → on; < 90 °C for 5 s → off
///   Memory: pressure critical, or warning while swapping ≥ 5 MB/s, for 5 s
///
/// Why smoothed and why 95 °C: the value read is the M1's hottest spot (TCMz). It jumps between
/// 85 and 104 every second and sits around 93 °C in ordinary work, so an 85 °C line was on
/// almost all the time: noise, not a warning. M1 slows down at about 100 °C.
struct HealthPeaks: Equatable {
    var cpu = false
    var heat = false
    var memory = false

    /// "cpu,heat,memory" (any subset) → forced peaks, for demo screenshots
    /// (`BARDECK_DEMO_HEALTH`). nil when the text names none of them.
    static func parse(_ text: String?) -> HealthPeaks? {
        guard let text else { return nil }
        let parts = Set(text.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let peaks = HealthPeaks(cpu: parts.contains("cpu"), heat: parts.contains("heat"), memory: parts.contains("memory"))
        return peaks == HealthPeaks() ? nil : peaks
    }
}

struct HealthGate {
    let enter: Double, exit: Double
    var on = false
    var since: Date?
    static let hold: TimeInterval = 5

    mutating func feed(_ value: Double?, now: Date) -> Bool {
        guard let value else { return on }
        let want = on ? value >= exit : value >= enter
        if want == on { since = nil; return on }
        if since == nil { since = now }
        if let since, now.timeIntervalSince(since) >= Self.hold { on = want; self.since = nil }
        return on
    }
}

struct HealthTracker {
    private var cpuGate = HealthGate(enter: 85, exit: 70)
    private var heatGate = HealthGate(enter: 95, exit: 90)
    /// The memory signal is for real stalls only: pressure critical (4), or warning (2) while the
    /// Mac is swapping to disk right now (≥ 5 MB/s). Warning alone isn't enough: an 8 GB Mac sets
    /// it often without stalling (the signal stayed on even with 0 swap after a restart).
    private var memoryGate = HealthGate(enter: 1, exit: 1)
    private var smoothTemp: Double?
    private var lastFeed: Date?
    /// Temperature smoothing time constant: it depends on time, not on how many samples arrive.
    private static let smoothing: TimeInterval = 10

    mutating func feed(_ s: HealthSample, now: Date = Date()) -> HealthPeaks {
        if let t = s.temperature {
            let dt = lastFeed.map { now.timeIntervalSince($0) } ?? Self.smoothing
            let alpha = 1 - exp(-dt / Self.smoothing)
            smoothTemp = smoothTemp.map { $0 + alpha * (t - $0) } ?? t
        }
        lastFeed = now
        let memory: Double = (s.memoryPressure >= 4 || (s.memoryPressure >= 2 && s.swapMBs >= 5)) ? 1 : 0
        return HealthPeaks(cpu: cpuGate.feed(s.cpuPercent, now: now),
                           heat: heatGate.feed(smoothTemp, now: now),
                           memory: memoryGate.feed(memory, now: now))
    }
}
