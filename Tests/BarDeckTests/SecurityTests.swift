import Foundation
import Testing
@testable import BarDeck

@Suite("Hook receiver access rules")
struct ReceiverRuleTests {

    private func request(method: String = "POST", path: String = "/claude-event",
                         headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data("{}".utf8))
    }

    private let good = ["content-type": "application/json", "x-bardeck-token": "abc123"]

    @Test func acceptsOnlyTheRightRequest() {
        #expect(ClaudeEventServer.accepts(request(headers: good), token: "abc123"))
        #expect(ClaudeEventServer.accepts(request(headers: ["content-type": "application/json; charset=utf-8",
                                                            "x-bardeck-token": "abc123"]), token: "abc123"))
    }

    @Test func rejectsMissingOrWrongToken() {
        #expect(!ClaudeEventServer.accepts(request(headers: ["content-type": "application/json"]), token: "abc123"))
        #expect(!ClaudeEventServer.accepts(request(headers: ["content-type": "application/json", "x-bardeck-token": "abc124"]), token: "abc123"))
        #expect(!ClaudeEventServer.accepts(request(headers: ["content-type": "application/json", "x-bardeck-token": ""]), token: ""))
        // Hooks not installed: no token at all, so nothing is accepted.
        #expect(!ClaudeEventServer.accepts(request(headers: good), token: nil))
    }

    @Test func rejectsBrowsersAndOtherContentTypes() {
        var withOrigin = good
        withOrigin["origin"] = "https://example.com"
        #expect(!ClaudeEventServer.accepts(request(headers: withOrigin), token: "abc123"))
        withOrigin["origin"] = "null"
        #expect(!ClaudeEventServer.accepts(request(headers: withOrigin), token: "abc123"))
        for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data"] {
            #expect(!ClaudeEventServer.accepts(request(headers: ["content-type": type, "x-bardeck-token": "abc123"]), token: "abc123"))
        }
        #expect(!ClaudeEventServer.accepts(request(headers: ["x-bardeck-token": "abc123"]), token: "abc123"))
    }

    @Test func rejectsOtherMethodsAndPaths() {
        #expect(!ClaudeEventServer.accepts(request(method: "GET", headers: good), token: "abc123"))
        #expect(!ClaudeEventServer.accepts(request(path: "/other", headers: good), token: "abc123"))
    }

    @Test func sizeCaps() {
        let big = "POST /claude-event HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes + 1)\r\n\r\n"
        #expect(HTTPRequest.parse(Data(big.utf8)) == .tooLarge)
        let exact = "POST /claude-event HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBodyBytes)\r\n\r\n"
        #expect(HTTPRequest.parse(Data(exact.utf8)) == .incomplete)
        // Endless headers are cut off, with or without the blank line.
        let longHeader = "POST /claude-event HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: HTTPRequest.maxHeaderBytes)
        #expect(HTTPRequest.parse(Data(longHeader.utf8)) == .tooLarge)
        #expect(HTTPRequest.parse(Data((longHeader + "\r\n\r\n").utf8)) == .tooLarge)
    }

    @Test func emptyFieldsCountAsAbsent() {
        let compact = ClaudeEventServer.compact(["a": "", "b": "x", "tool_input": ["file_path": "", "description": ""], "n": 3])
        #expect(compact["a"] == nil)
        #expect(compact["b"] as? String == "x")
        #expect(compact["tool_input"] == nil)
        #expect(compact["n"] as? Int == 3)
    }
}

@Suite("Transcript path validation")
struct TranscriptPathTests {

    private func makeTree() throws -> (root: URL, outside: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BarDeckTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("projects/demo-app")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        return (base.appendingPathComponent("projects"), outside)
    }

    @Test func acceptsARegularFileInside() throws {
        let (root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let file = root.appendingPathComponent("demo-app/session.jsonl")
        try Data(#"{"type":"assistant","message":{"model":"claude-opus-5-5","stop_reason":"end_turn"}}"#.utf8).write(to: file)
        #expect(TranscriptReader.validated(file.path, root: root.path) != nil)
        let result = TranscriptReader.read(file.path, wantsModel: true, wantsEnd: true, root: root.path)
        #expect(result.model == "claude-opus-5-5")
        #expect(result.end == .finished)
    }

    @Test func refusesOutsideTraversalAndSymlinks() throws {
        let (root, outside) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let secret = outside.appendingPathComponent("secret.jsonl")
        try Data("{}".utf8).write(to: secret)
        #expect(TranscriptReader.validated(secret.path, root: root.path) == nil)
        #expect(TranscriptReader.validated(root.path + "/demo-app/../../elsewhere/secret.jsonl", root: root.path) == nil)
        let link = root.appendingPathComponent("demo-app/link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(TranscriptReader.validated(link.path, root: root.path) == nil)
        #expect(TranscriptReader.validated("relative/path.jsonl", root: root.path) == nil)
        #expect(TranscriptReader.validated(root.path + "/demo-app/missing.jsonl", root: root.path) == nil)
        // A sibling folder whose name merely starts with the root's name is outside too.
        let sibling = root.deletingLastPathComponent().appendingPathComponent("projects-evil")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sibling.appendingPathComponent("x.jsonl"))
        #expect(TranscriptReader.validated(sibling.path + "/x.jsonl", root: root.path) == nil)
    }

    @Test func refusesFifosDirectoriesAndDevices() throws {
        let (root, _) = try makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let fifo = root.appendingPathComponent("demo-app/pipe.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(TranscriptReader.validated(fifo.path, root: root.path) == nil)
        // The read returns at once instead of blocking on the pipe.
        let result = TranscriptReader.read(fifo.path, wantsModel: true, wantsEnd: true, root: root.path)
        #expect(result.validPath == nil)
        #expect(TranscriptReader.validated(root.appendingPathComponent("demo-app").path, root: root.path) == nil)
        #expect(TranscriptReader.validated("/dev/zero", root: "/dev") == nil)
    }

    @Test func statusOnlyTrustsAValidatedPath() {
        let status = ClaudeStatus()
        let t0 = Date()
        status.handle(event: "UserPromptSubmit", payload: ["session_id": "s", "cwd": "/tmp/demo-app",
                                                           "transcript_path": "/dev/zero"], now: t0)
        let reads = status.transcriptReads(now: t0)
        #expect(reads.count == 1)
        #expect(reads.first?.wantsModel == true)
        // Validation refused it: no model, no state change, and it isn't asked again right away.
        #expect(!status.apply(reads[0], validPath: nil, model: "claude-x", end: .finished, now: t0))
        #expect(status.sessionInfos.first?.model == nil)
        #expect(status.transcriptReads(now: t0.addingTimeInterval(1)).isEmpty)
    }

    @Test func missingStopIsSettledFromTheTranscript() {
        let status = ClaudeStatus()
        let t0 = Date()
        status.handle(event: "UserPromptSubmit", payload: ["session_id": "s", "transcript_path": "/p/s.jsonl"], now: t0)
        _ = status.transcriptReads(now: t0)   // the model read
        let later = t0.addingTimeInterval(25)
        let reads = status.transcriptReads(now: later)
        #expect(reads.first?.wantsEnd == true)
        #expect(status.apply(reads[0], validPath: "/p/s.jsonl", model: nil, end: .finished, now: later))
        #expect(status.sessionInfos.first?.state == "done")
    }
}

@Suite("Hook script end to end", .serialized)
@MainActor
struct HookScriptTests {

    /// Installs into a temp folder, starts the receiver on a temp socket, runs the real script
    /// with a full Claude payload, and checks what arrives.
    @Test func scriptSendsOnlyTheNeededFields() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BarDeckTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let socket = "/tmp/bardeck-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        defer { unlink(socket) }
        let script = dir.appendingPathComponent("support/claude-hook.sh")
        let settings = dir.appendingPathComponent("settings.json")
        let token = try ClaudeHooks.install(settingsURL: settings, scriptURL: script,
                                            tokenURL: dir.appendingPathComponent("support/hook-token"), socketPath: socket)

        let server = ClaudeEventServer()
        server.tokenProvider = { token }
        var received: [(String, [String: Any])] = []
        server.onEvent = { received.append(($0, $1)) }
        server.start(socketPath: socket)
        defer { server.stop() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(20)) }

        let payload: [String: Any] = [
            "session_id": "s1", "cwd": "/Users/me/code/demo-app", "transcript_path": "/Users/me/.claude/projects/x/s1.jsonl",
            "hook_event_name": "PreToolUse", "prompt": "my private prompt",
            "tool_name": "Bash",
            "tool_input": ["command": "cd /secret && FOO=bar git push https://user:pass@example.com \"quoted\"",
                           "description": "Push the \"main\" branch\\now"],
            "tool_response": ["stdout": "private output"],
        ]
        let process = Process()
        process.executableURL = script
        process.arguments = ["PreToolUse"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        for _ in 0..<150 where received.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(received.count == 1)
        guard let (event, got) = received.first else { return }
        #expect(event == "PreToolUse")
        #expect(got["session_id"] as? String == "s1")
        #expect(got["cwd"] as? String == "/Users/me/code/demo-app")
        #expect(got["tool_name"] as? String == "Bash")
        let tool = got["tool_input"] as? [String: Any]
        #expect(tool?["command"] as? String == "git")                         // the program, never its arguments
        #expect(tool?["description"] as? String == "Push the \"main\" branch\\now")
        #expect(got["prompt"] == nil)
        #expect(got["tool_response"] == nil)
        let flat = String(describing: got)
        #expect(!flat.contains("private"))
        #expect(!flat.contains("pass@"))
        #expect(ClaudeStatus.describe(tool: "Bash", input: tool) == "Push the \"main\" branch\\now")
    }

    @Test func wrongTokenIsDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BarDeckTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let socket = "/tmp/bardeck-test-\(UInt32.random(in: 0...UInt32.max)).sock"
        defer { unlink(socket) }
        let script = dir.appendingPathComponent("support/claude-hook.sh")
        _ = try ClaudeHooks.install(settingsURL: dir.appendingPathComponent("settings.json"), scriptURL: script,
                                    tokenURL: dir.appendingPathComponent("support/hook-token"), socketPath: socket)
        let server = ClaudeEventServer()
        server.tokenProvider = { "not-the-installed-token" }
        var received = 0
        server.onEvent = { _, _ in received += 1 }
        server.start(socketPath: socket)
        defer { server.stop() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(20)) }

        let process = Process()
        process.executableURL = script
        process.arguments = ["Stop"]
        let input = Pipe()
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"session_id":"s1"}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        try await Task.sleep(for: .milliseconds(1500))
        #expect(received == 0)
        // The socket itself is private.
        let mode = (try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? Int) ?? -1
        #expect(mode == 0o600)
    }
}
