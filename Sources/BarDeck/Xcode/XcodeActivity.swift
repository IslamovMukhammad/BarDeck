import AppKit
import ApplicationServices

struct XcodeMessage: Equatable {
    /// idle | packages | building | testing | succeeded | failed
    var phase: String
    var text: String
    /// 0...1, when known
    var progress: Double?
    var project: String

    static let idle = XcodeMessage(phase: "idle", text: "", progress: nil, project: "")
}

/// What Xcode is doing (fetching packages, building, testing), for the Xcode card.
///
/// Xcode has no API for this, so the activity text in its window toolbar ("Fetching
/// GRDB.swift (32%)…") is read through Accessibility (the same permission the Touch Bar
/// already needs). It works while Xcode is in the background or behind other windows.
///
/// Only long, meaningful work is shown: packages, Building, Testing. Indexing is not: it runs
/// in the background all the time and is just noise. When done: success stays green for 3 s
/// with a sound; failure stays red until you switch to Xcode.
@MainActor
final class XcodeActivityWatcher {
    nonisolated static let bundleID = "com.apple.dt.Xcode"

    var onChange: ((XcodeMessage) -> Void)?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cachedText: AXUIElement?
    private var cachedWindowTitle = ""
    private var lastSearch = Date.distantPast
    /// The last work phase seen: a "Succeeded/Failed" only counts after one we watched.
    private var lastWorkPhase: String?
    private var result: XcodeMessage?
    private var resultClear: DispatchWorkItem?
    private var current = XcodeMessage.idle

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.updateTimer() }
            })
        }
        // A failure stays until you switch to Xcode.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated {
                guard let self, self.result?.phase == "failed" else { return }
                self.result = nil
                self.emit()
            }
        })
        updateTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    /// Polls once a second, and only while Xcode is open.
    private func updateTimer() {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if running, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer?.tolerance = 0.3
            poll()
        } else if !running {
            timer?.invalidate()
            timer = nil
            cachedText = nil
            lastWorkPhase = nil
            result = nil
            current = .idle
            emit()
        }
    }

    private func poll() {
        guard AXIsProcessTrusted() else { return }
        let parsed = Self.parse(readActivityText() ?? "")
        let project = Self.projectName(from: cachedWindowTitle)

        switch parsed.phase {
        case "packages", "building", "testing":
            lastWorkPhase = parsed.phase
            result = nil
            resultClear?.cancel()
            current = XcodeMessage(phase: parsed.phase, text: parsed.text, progress: parsed.progress, project: project)
        case "succeeded", "failed":
            if lastWorkPhase == "building" || lastWorkPhase == "testing" {
                lastWorkPhase = nil
                finish(XcodeMessage(phase: parsed.phase, text: parsed.text, progress: nil, project: project))
            }
            current = XcodeMessage(phase: "idle", text: "", progress: nil, project: project)
        default:
            if lastWorkPhase == "packages" { lastWorkPhase = nil }
            current = XcodeMessage(phase: "idle", text: "", progress: nil, project: project)
        }
        emit()
    }

    private func finish(_ message: XcodeMessage) {
        result = message
        let success = message.phase == "succeeded"
        if AppSettings.shared.xcodeSound {
            NSSound(named: success ? "Submarine" : "Basso")?.play()
        }
        resultClear?.cancel()
        guard success else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.result?.phase == "succeeded" else { return }
                self.result = nil
                self.emit()
            }
        }
        resultClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func emit() {
        onChange?(current.phase != "idle" ? current : (result ?? current))
    }

    // MARK: - Accessibility

    /// The "Activity Text" element of Xcode's window. Cached; when lost, the tree is searched
    /// again at most every 5 seconds.
    private func readActivityText() -> String? {
        if let element = cachedText, let value = Self.string(element, kAXValueAttribute) {
            return value
        }
        cachedText = nil
        guard Date().timeIntervalSince(lastSearch) > 5,
              let xcode = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        else { return nil }
        lastSearch = Date()
        let app = AXUIElementCreateApplication(xcode.processIdentifier)
        // kAXWindows only lists windows on the current Space; the main/focused window and the
        // children are returned for other Spaces too.
        var windows = (Self.attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let value = Self.attr(app, name), CFGetTypeID(value) == AXUIElementGetTypeID() {
                windows.append(value as! AXUIElement)
            }
        }
        windows += ((Self.attr(app, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
            .filter { Self.string($0, kAXRoleAttribute) == kAXWindowRole }
        for window in windows {
            if let found = Self.find(in: window, depth: 0) {
                cachedText = found
                cachedWindowTitle = Self.string(window, kAXTitleAttribute) ?? ""
                return Self.string(found, kAXValueAttribute)
            }
        }
        return nil
    }

    private static func find(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 14 { return nil }
        if string(element, kAXIdentifierAttribute) == "Activity Text" { return element }
        for child in (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let found = find(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attr(element, name) as? String
    }

    // MARK: - Reading the text (unit-tested)

    /// "Fetching GRDB.swift (32%)…" → packages, "Fetching GRDB.swift", 0.32
    /// "Building MyApp | Compiling 12 of 40" → building, "Compiling 12 of 40", 0.3
    /// "Build Succeeded | Today at 17:40" → succeeded
    /// "Indexing | Processing files", "Running …", "Ready" → idle
    nonisolated static func parse(_ raw: String) -> (phase: String, text: String, progress: Double?) {
        let cleaned = raw.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
        let lower = cleaned.lowercased()
        let head = cleaned.components(separatedBy: CharacterSet(charactersIn: "|│")).first?
            .trimmingCharacters(in: .whitespaces) ?? cleaned

        if lower.contains("succeeded") { return ("succeeded", head, nil) }
        if lower.contains("failed") { return ("failed", head, nil) }

        var progress: Double?
        if let match = cleaned.range(of: #"\((\d{1,3})%\)"#, options: .regularExpression) {
            progress = Double(cleaned[match].filter(\.isNumber)).map { min(1, $0 / 100) }
        } else if let match = cleaned.range(of: #"(\d+) of (\d+)"#, options: .regularExpression) {
            let numbers = cleaned[match].split(separator: " ").compactMap { Double($0) }
            if numbers.count == 2, numbers[1] > 0 { progress = min(1, numbers[0] / numbers[1]) }
        }
        let text = head.replacingOccurrences(of: #"\s*\(\d{1,3}%\)"#, with: "", options: .regularExpression)

        let packageWords = ["fetching", "resolving", "cloning", "updating", "checking out", "computing", "downloading"]
        let buildWords = ["building", "build ", "compiling", "linking", "preparing", "copying", "signing", "generating"]
        if packageWords.contains(where: lower.hasPrefix) { return ("packages", text, progress) }
        if lower.hasPrefix("testing") || lower.hasPrefix("running tests") { return ("testing", text, progress) }
        if buildWords.contains(where: lower.hasPrefix) {
            // "Build | Compiling …": the second part says more.
            let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: "|│"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return ("building", parts.count > 1 ? parts[1] : text, progress)
        }
        return ("idle", text, nil)
    }

    /// "MyApp — MyApp.xcodeproj" → "MyApp"
    nonisolated static func projectName(from title: String) -> String {
        title.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}
