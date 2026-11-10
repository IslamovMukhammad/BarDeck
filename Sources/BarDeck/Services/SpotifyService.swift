import AppKit

/// What the music card shows.
struct NowPlaying: Equatable {
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var artworkURL: String = ""
    var isPlaying: Bool = false
    /// Playback position captured at `positionStamp` (seconds).
    var position: Double = 0
    var duration: Double = 0
    var positionStamp: Double = 0

    var isEmpty: Bool { title.isEmpty && artist.isEmpty }

    /// Position extrapolated to now, so the progress bar moves smoothly
    /// between the sparse updates the player gives us.
    func livePosition(now: Double = Date().timeIntervalSince1970) -> Double {
        guard duration > 0 else { return 0 }
        guard isPlaying, positionStamp > 0 else { return min(position, duration) }
        return min(max(position + (now - positionStamp), 0), duration)
    }

    var progress: Double { duration > 0 ? livePosition() / duration : 0 }
}

/// Turns the AppleScript reply into a state. Pure, so it is unit-tested.
enum SpotifyParser {
    enum Result: Equatable {
        case notRunning
        case stopped
        case track(NowPlaying)
    }

    static let separator = "|||"

    /// `output` is what `SpotifyService.pollScript` returns:
    /// title ||| artist ||| album ||| artwork url ||| duration (ms) ||| position (s) ||| state
    static func parse(_ output: String?, now: Double = Date().timeIntervalSince1970) -> Result {
        guard let output, !output.isEmpty, output != "NOT_RUNNING" else { return .notRunning }
        if output == "STOPPED" { return .stopped }
        let parts = output.components(separatedBy: separator)
        guard parts.count >= 7 else { return .stopped }
        return .track(NowPlaying(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            artworkURL: parts[3],
            isPlaying: parts[6].trimmingCharacters(in: .whitespaces) == "playing",
            position: number(parts[5]) ?? 0,
            // Spotify reports the track length in milliseconds and the position in seconds.
            duration: (number(parts[4]) ?? 0) / 1000,
            positionStamp: now))
    }

    /// AppleScript formats reals with the system locale, so "12,5" is as likely as "12.5".
    static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}

/// Reads Spotify's "now playing" and drives it, through AppleScript only: no Web API, no keys,
/// no login. Based on the author's own SpotifyTouchBar `SpotifyManager`.
///
/// The first call makes macOS ask once for permission to control Spotify (Automation).
@MainActor
final class SpotifyService {

    nonisolated static let bundleID = "com.spotify.client"

    private(set) var nowPlaying = NowPlaying()
    var onChange: ((NowPlaying) -> Void)?

    private let queue = DispatchQueue(label: "BarDeck.spotify", qos: .userInitiated)
    private var timer: Timer?
    private var polling = false
    private var observers: [NSObjectProtocol] = []
    /// Demo mode feeds a made-up track instead of asking Spotify.
    var isDemo = false

    /// `if application … is running` never launches Spotify, unlike a bare `tell`.
    static let pollScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return "STOPPED"
            set t to current track
            return (name of t) & "|||" & (artist of t) & "|||" & (album of t) & "|||" & (artwork url of t) & "|||" & ((duration of t) as string) & "|||" & ((player position) as string) & "|||" & ((player state) as string)
        end tell
    else
        return "NOT_RUNNING"
    end if
    """

    func start() {
        guard !isDemo else { return }
        // Spotify announces every play, pause and track change; the timer only keeps the
        // position honest (and catches anything the notification misses).
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            })
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.publish(NowPlaying()) }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer?.tolerance = 0.5
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func poll() {
        guard !isDemo, !polling else { return }
        guard isRunning else {
            if !nowPlaying.isEmpty { publish(NowPlaying()) }
            return
        }
        polling = true
        let script = Self.pollScript
        queue.async { [weak self] in
            let output = Self.run(script)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.polling = false
                    switch SpotifyParser.parse(output) {
                    case .track(let track): self.publish(track)
                    case .stopped, .notRunning: self.publish(NowPlaying())
                    }
                }
            }
        }
    }

    func publish(_ track: NowPlaying) {
        // Only a real change is pushed: the position stamp moves on every poll.
        var a = track, b = nowPlaying
        a.position = 0; a.positionStamp = 0; b.position = 0; b.positionStamp = 0
        let jumped = abs(track.livePosition() - nowPlaying.livePosition()) > 1.5
        nowPlaying = track
        if a != b || jumped { onChange?(track) }
    }

    // MARK: - Controls

    enum Action: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    func perform(_ action: Action) {
        guard !isDemo else { return }
        guard isRunning else { activateApp(); return }
        let script = "tell application \"Spotify\" to \(action.rawValue)"
        queue.async { [weak self] in
            _ = Self.run(script)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.poll() } }
        }
    }

    /// Tapping the card brings Spotify forward (or opens it).
    func activateApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    nonisolated private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return result?.stringValue
    }
}
