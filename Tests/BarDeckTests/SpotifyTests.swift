import Foundation
import Testing
@testable import BarDeck

@Suite("Spotify state parsing")
struct SpotifyParserTests {

    @Test func notRunningAndEmpty() {
        #expect(SpotifyParser.parse(nil) == .notRunning)
        #expect(SpotifyParser.parse("") == .notRunning)
        #expect(SpotifyParser.parse("NOT_RUNNING") == .notRunning)
    }

    @Test func stopped() {
        #expect(SpotifyParser.parse("STOPPED") == .stopped)
        // A short or broken reply is treated as nothing playing, never a crash.
        #expect(SpotifyParser.parse("Song|||Artist") == .stopped)
    }

    @Test func playingTrack() {
        let output = "Midnight Drive|||Demo Artist|||Open Roads|||https://i.scdn.co/image/abc|||214000|||74.5|||playing"
        guard case .track(let track) = SpotifyParser.parse(output, now: 1000) else {
            Issue.record("expected a track"); return
        }
        #expect(track.title == "Midnight Drive")
        #expect(track.artist == "Demo Artist")
        #expect(track.album == "Open Roads")
        #expect(track.artworkURL == "https://i.scdn.co/image/abc")
        #expect(track.isPlaying)
        // Duration comes in milliseconds, position in seconds.
        #expect(track.duration == 214)
        #expect(track.position == 74.5)
        #expect(track.positionStamp == 1000)
    }

    @Test func pausedWithCommaDecimals() {
        // AppleScript formats reals with the system locale.
        let output = "Song|||Artist|||Album||||||180000|||12,25|||paused"
        guard case .track(let track) = SpotifyParser.parse(output) else {
            Issue.record("expected a track"); return
        }
        #expect(!track.isPlaying)
        #expect(track.position == 12.25)
        #expect(track.artworkURL.isEmpty)
    }

    @Test func titleWithSpecialCharacters() {
        let output = "Don't Stop — Live (2024)|||A & B|||X|||u|||1000|||0|||playing"
        guard case .track(let track) = SpotifyParser.parse(output) else {
            Issue.record("expected a track"); return
        }
        #expect(track.title == "Don't Stop — Live (2024)")
        #expect(track.artist == "A & B")
    }

    @Test func livePositionMovesOnlyWhilePlaying() {
        var track = NowPlaying(title: "A", isPlaying: true, position: 10, duration: 100, positionStamp: 1000)
        #expect(track.livePosition(now: 1005) == 15)
        // Never past the end.
        #expect(track.livePosition(now: 2000) == 100)
        track.isPlaying = false
        #expect(track.livePosition(now: 1005) == 10)
        // No duration, no progress.
        #expect(NowPlaying(title: "A", isPlaying: true, position: 10).livePosition(now: 1005) == 0)
    }
}
