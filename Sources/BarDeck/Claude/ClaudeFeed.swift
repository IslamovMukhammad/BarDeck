import AppKit

/// What Claude is doing right now, in Touch Bar terms.
enum ClaudeActivity: String {
    case offline    // no session
    case idle       // the turn is over
    case working    // thinking or running a tool
    case waiting    // waiting for your answer
    case error      // the last turn ended with an error

    var color: NSColor {
        switch self {
        case .offline: Theme.claudeOffline
        case .idle:    Theme.claudeIdle
        case .working: Theme.claudeWorking
        case .waiting: Theme.claudeWaiting
        case .error:   Theme.claudeError
        }
    }

    var label: String {
        switch self {
        case .offline: "Claude"
        case .idle:    "Done"
        case .working: "Working"
        case .waiting: "Needs you"
        case .error:   "Failed"
        }
    }

    /// Only working and waiting breathe: something that sits beside you all day shouldn't
    /// always be moving.
    var pulses: Bool { self == .working || self == .waiting }

    static func from(_ state: String) -> ClaudeActivity {
        switch state {
        case "working": .working
        case "waiting", "asking": .waiting
        case "error": .error
        default: .idle
        }
    }
}

/// With several active sessions, each gets its own chip on the bar.
struct ClaudeChip: Equatable {
    let id: String
    let project: String
    let activity: ClaudeActivity
    let cwd: String?
}

struct ClaudeState: Equatable {
    var activity: ClaudeActivity = .offline
    /// Filled when 2 or more sessions are active (most urgent first, at most 3).
    var chips: [ClaudeChip] = []
    var detail: String = ""      // the current tool, e.g. "editing ContentView.swift"
    var model: String = ""
    var project: String = ""

    /// Pure mapping from the session list to what the card shows. Unit-tested.
    ///
    /// With several sessions the most urgent one wins: waiting > error > working > done.
    static func make(from sessions: [ClaudeSessionInfo], showChips: Bool) -> ClaudeState {
        let rank: [String: Int] = ["waiting": 0, "asking": 0, "error": 1, "working": 2, "done": 3]
        let active = sessions
            .filter { $0.state != "idle" }
            .sorted { (rank[$0.state] ?? 9) < (rank[$1.state] ?? 9) }

        var next = ClaudeState()
        if active.count >= 2, showChips {
            next.chips = active.prefix(3).map {
                ClaudeChip(id: $0.id, project: $0.project, activity: .from($0.state), cwd: $0.cwd)
            }
        }
        if let top = active.first {
            next.activity = .from(top.state)
            next.detail = top.activity
            next.model = prettyModel(top.model)
            next.project = top.project
        } else if let first = sessions.first {
            // Every session is idle (finished and settled): grey "Claude". Green "Done" is only
            // for a real "done" state, or it would stick around forever.
            next.activity = .offline
            next.project = first.project
        }
        return next
    }

    /// "claude-opus-5-5" → "Opus 5.5"
    static func prettyModel(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "" }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let name = parts.first else { return id }
        let version = parts.dropFirst().prefix(while: { $0.allSatisfy(\.isNumber) && $0.count <= 2 })
        let title = name.prefix(1).uppercased() + name.dropFirst()
        return version.isEmpty ? title : "\(title) \(version.joined(separator: "."))"
    }
}

/// Owns the Claude state: hook events come in from `ClaudeEventServer`, the Touch Bar
/// listens through `onChange`.
@MainActor
final class ClaudeFeed {
    static let shared = ClaudeFeed()

    let status = ClaudeStatus()
    private(set) var state = ClaudeState()
    var onChange: ((ClaudeState) -> Void)? {
        didSet { onChange?(state) }
    }
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.status.refresh() { self.republish() }
                self.readTranscripts()
            }
        }
        timer?.tolerance = 0.5
    }

    func handle(event: String, payload: [String: Any]) {
        status.handle(event: event, payload: payload)
        republish()
        readTranscripts()
    }

    private let readQueue = DispatchQueue(label: "BarDeck.transcripts", qos: .utility)

    /// Transcripts are validated and read on a background queue, never on the main thread.
    private func readTranscripts() {
        for read in status.transcriptReads() {
            readQueue.async { [weak self] in
                let result = TranscriptReader.read(read.path, wantsModel: read.wantsModel, wantsEnd: read.wantsEnd)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.status.apply(read, validPath: result.validPath, model: result.model, end: result.end) {
                            self.republish()
                        }
                    }
                }
            }
        }
    }

    /// Re-draws after a setting change (e.g. chips turned off).
    func republish() {
        status.autoDone = AppSettings.shared.claudeAutoDone
        set(ClaudeState.make(from: status.sessionInfos, showChips: AppSettings.shared.claudeChips))
    }

    /// Demo mode and tests set the state directly.
    func set(_ next: ClaudeState) {
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
