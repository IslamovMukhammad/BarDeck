import Foundation
import Testing
@testable import BarDeck

@Suite("Claude state from hook events")
struct ClaudeStatusTests {

    private func payload(_ extra: [String: Any] = [:], id: String = "s1", cwd: String = "/Users/me/code/demo-app") -> [String: Any] {
        var p: [String: Any] = ["session_id": id, "cwd": cwd]
        p.merge(extra) { $1 }
        return p
    }

    @Test func promptToolStopCycle() {
        let status = ClaudeStatus()
        var sessions = status.handle(event: "SessionStart", payload: payload())
        #expect(sessions.first?.state == "idle")
        #expect(sessions.first?.project == "demo-app")

        sessions = status.handle(event: "UserPromptSubmit", payload: payload())
        #expect(sessions.first?.state == "working")
        #expect(sessions.first?.activity == "thinking")

        sessions = status.handle(event: "PreToolUse", payload: payload(["tool_name": "Edit",
                                                                        "tool_input": ["file_path": "/a/b/PlayerView.swift"]]))
        #expect(sessions.first?.activity == "editing PlayerView.swift")

        sessions = status.handle(event: "PostToolUse", payload: payload(["tool_name": "Edit"]))
        #expect(sessions.first?.activity == "thinking")

        sessions = status.handle(event: "Stop", payload: payload())
        #expect(sessions.first?.state == "done")

        sessions = status.handle(event: "SessionEnd", payload: payload())
        #expect(sessions.isEmpty)
    }

    @Test func idlePromptNotificationIsIgnored() {
        let status = ClaudeStatus()
        status.handle(event: "Stop", payload: payload())
        let sessions = status.handle(event: "Notification", payload: payload(["notification_type": "idle_prompt",
                                                                               "message": "Claude is waiting for your input"]))
        #expect(sessions.first?.state == "done")
    }

    @Test func permissionNotificationNeedsYou() {
        let status = ClaudeStatus()
        let sessions = status.handle(event: "Notification", payload: payload(["notification_type": "permission_prompt",
                                                                               "message": "Claude needs your permission to use Bash"]))
        #expect(sessions.first?.state == "waiting")
        #expect(sessions.first?.activity == "Claude needs your permission to use Bash")
    }

    @Test func subagentsAreCounted() {
        let status = ClaudeStatus()
        status.handle(event: "PreToolUse", payload: payload(["tool_name": "Agent"]))
        var sessions = status.handle(event: "PreToolUse", payload: payload(["tool_name": "Task"]))
        #expect(sessions.first?.activity == "2 tasks running")
        sessions = status.handle(event: "SubagentStop", payload: payload())
        #expect(sessions.first?.activity == "1 task running")
        sessions = status.handle(event: "SubagentStop", payload: payload())
        #expect(sessions.first?.activity == "subtask done · continuing")
    }

    @Test func stopFailureReadsTheReason() {
        let status = ClaudeStatus()
        let sessions = status.handle(event: "StopFailure", payload: payload(["error": "rate_limit"]))
        #expect(sessions.first?.state == "error")
        #expect(sessions.first?.activity == "limit reached")
    }

    @Test func doneSettlesToIdleAfterSilence() {
        let status = ClaudeStatus()
        let start = Date()
        status.handle(event: "Stop", payload: payload(), now: start)
        #expect(!status.refresh(now: start.addingTimeInterval(30)))
        #expect(status.refresh(now: start.addingTimeInterval(91)))
        #expect(status.sessionInfos.first?.state == "idle")
    }

    @Test func describeTools() {
        #expect(ClaudeStatus.describe(tool: "Bash", input: ["description": "Build the /Users/me/app/Package.swift target"])
                == "Build the Package.swift target")
        #expect(ClaudeStatus.describe(tool: "Bash", input: ["command": "cd /tmp && git status"]) == "using git")
        #expect(ClaudeStatus.describe(tool: "Read", input: ["file_path": "/x/y/README.md"]) == "reading README.md")
        #expect(ClaudeStatus.describe(tool: "WebFetch", input: ["url": "https://swift.org/docs"]) == "fetching swift.org")
        #expect(ClaudeStatus.describe(tool: "mcp__Claude_Browser__browser_batch", input: nil) == "using the browser")
        #expect(ClaudeStatus.describe(tool: "Grep", input: nil) == "searching the code")
    }
}

@Suite("Claude card mapping")
struct ClaudeStateTests {

    private func session(_ id: String, _ state: String, project: String = "p", model: String? = nil) -> ClaudeSessionInfo {
        ClaudeSessionInfo(id: id, project: project, state: state, activity: "act-\(id)", model: model, cwd: nil)
    }

    @Test func noSessionsIsOffline() {
        let state = ClaudeState.make(from: [], showChips: true)
        #expect(state.activity == .offline)
        #expect(state.chips.isEmpty)
    }

    @Test func idleSessionsShowGreyNotDone() {
        let state = ClaudeState.make(from: [session("1", "idle", project: "demo")], showChips: true)
        #expect(state.activity == .offline)
        #expect(state.project == "demo")
    }

    @Test func mostUrgentWins() {
        let state = ClaudeState.make(from: [session("1", "working"), session("2", "waiting", project: "web", model: "claude-opus-5-5")],
                                     showChips: false)
        #expect(state.activity == .waiting)
        #expect(state.project == "web")
        #expect(state.detail == "act-2")
        #expect(state.model == "Opus 5.5")
        #expect(state.chips.isEmpty)
    }

    @Test func chipsForSeveralActiveSessions() {
        let sessions = [session("1", "done"), session("2", "working"), session("3", "error"), session("4", "waiting"), session("5", "idle")]
        let state = ClaudeState.make(from: sessions, showChips: true)
        #expect(state.chips.map(\.id) == ["4", "3", "2"])
        #expect(state.chips.first?.activity == .waiting)
    }

    @Test func prettyModel() {
        #expect(ClaudeState.prettyModel("claude-opus-5-5") == "Opus 5.5")
        #expect(ClaudeState.prettyModel("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
        #expect(ClaudeState.prettyModel("claude-fable-5-2") == "Fable 5.2")
        #expect(ClaudeState.prettyModel(nil) == "")
    }

    @Test func activityColorsAndPulse() {
        #expect(ClaudeActivity.from("working") == .working)
        #expect(ClaudeActivity.from("asking") == .waiting)
        #expect(ClaudeActivity.from("done") == .idle)
        #expect(ClaudeActivity.working.pulses)
        #expect(!ClaudeActivity.idle.pulses)
    }
}

@Suite("Transcript tail")
struct TranscriptReaderTests {

    @Test func turnEnd() {
        let finished: [Substring] = [#"{"type":"user","message":{"content":"hi"}}"#,
                                     #"{"type":"assistant","message":{"model":"claude-opus-5-5","stop_reason":"end_turn"}}"#]
        #expect(TranscriptReader.turnEnd(lines: finished) == .finished)
        #expect(TranscriptReader.model(lines: finished) == "claude-opus-5-5")

        let running: [Substring] = [#"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#,
                                    #"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#]
        #expect(TranscriptReader.turnEnd(lines: running) == .running)

        let interrupted: [Substring] = [#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#]
        #expect(TranscriptReader.turnEnd(lines: interrupted) == .interrupted)
    }
}

@Suite("Hook receiver and installer")
struct ClaudeHookTests {

    @Test func httpParsing() {
        let body = #"{"event":"Stop","payload":{}}"#
        let raw = "POST /claude-event HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        #expect(HTTPRequest.parse(Data(raw.utf8)) == .complete(HTTPRequest(
            method: "POST", path: "/claude-event",
            headers: ["host": "127.0.0.1", "content-length": "\(body.utf8.count)"], body: Data(body.utf8))))
        // Body still arriving.
        #expect(HTTPRequest.parse(Data(raw.dropLast(5).utf8)) == .incomplete)
        // Headers still arriving.
        #expect(HTTPRequest.parse(Data("POST /claude-event HTTP/1.1\r\nContent-".utf8)) == .incomplete)
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)) == .invalid)
    }

    @Test func addKeepsOtherHooksAndIsIdempotent() {
        let script = "/Library/BarDeck/claude-hook.sh"
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/other/notify.sh"]]]]],
        ]
        let once = ClaudeHooks.adding(to: existing, scriptPath: script)
        let twice = ClaudeHooks.adding(to: once, scriptPath: script)
        #expect(ClaudeHooks.isInstalled(in: twice, scriptPath: script))
        #expect(twice["model"] as? String == "opus")
        let hooks = twice["hooks"] as? [String: Any]
        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)   // the other hook + ours, not ours twice
        let pre = hooks?["PreToolUse"] as? [[String: Any]]
        #expect(pre?.first?["matcher"] as? String == "*")
        #expect(ClaudeHooks.events.allSatisfy { hooks?[$0] != nil })
    }

    @Test func removeTakesOnlyOurs() {
        let script = "/Library/BarDeck/claude-hook.sh"
        let existing: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "/other/notify.sh"]]]]]]
        let removed = ClaudeHooks.removing(from: ClaudeHooks.adding(to: existing, scriptPath: script), scriptPath: script)
        #expect(!ClaudeHooks.isInstalled(in: removed, scriptPath: script))
        let hooks = removed["hooks"] as? [String: Any]
        #expect(hooks?.keys.sorted() == ["Stop"])
        // Nothing but ours → the "hooks" key goes away entirely.
        let clean = ClaudeHooks.removing(from: ClaudeHooks.adding(to: [:], scriptPath: script), scriptPath: script)
        #expect(clean["hooks"] == nil)
    }

    @Test func installAndUninstallFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BarDeckTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = dir.appendingPathComponent(".claude/settings.json")
        let script = dir.appendingPathComponent("support/claude-hook.sh")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)

        let tokenFile = dir.appendingPathComponent("support/hook-token")
        let token = try ClaudeHooks.install(settingsURL: settings, scriptURL: script, tokenURL: tokenFile,
                                            socketPath: "/tmp/bar deck/claude.sock")
        #expect(ClaudeHooks.isInstalled(settingsURL: settings, scriptURL: script))
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("--unix-socket"))
        #expect(text.contains("SOCKET='/tmp/bar deck/claude.sock'"))
        #expect(text.contains("TOKEN='\(token)'"))
        #expect(!text.contains("127.0.0.1"))
        #expect(FileManager.default.fileExists(atPath: settings.path + ".bardeck-backup"))

        // A 64-character random token, readable by you only, the same one the script carries.
        #expect(token.count == 64)
        #expect(ClaudeHooks.currentToken(tokenURL: tokenFile) == token)
        func mode(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
        }
        #expect(try mode(tokenFile) == 0o600)
        #expect(try mode(script) == 0o700)
        #expect(try mode(script.deletingLastPathComponent()) == 0o700)
        // Each install makes a new token.
        let second = try ClaudeHooks.install(settingsURL: settings, scriptURL: script, tokenURL: tokenFile, socketPath: "/tmp/x.sock")
        #expect(second != token)

        try ClaudeHooks.uninstall(settingsURL: settings, scriptURL: script, tokenURL: tokenFile)
        #expect(!ClaudeHooks.isInstalled(settingsURL: settings, scriptURL: script))
        #expect(ClaudeHooks.currentToken(tokenURL: tokenFile) == nil)
        let after = try ClaudeHooks.readSettings(settings)
        #expect(after["theme"] as? String == "dark")
    }

    @Test func refusesUnreadableSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BarDeckTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        try Data("{ not json".utf8).write(to: settings)
        #expect(throws: ClaudeHooks.HookError.self) {
            try ClaudeHooks.install(settingsURL: settings, scriptURL: dir.appendingPathComponent("h.sh"),
                                    tokenURL: dir.appendingPathComponent("t"), socketPath: "/tmp/x.sock")
        }
        // The broken file is left exactly as it was.
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
    }
}
