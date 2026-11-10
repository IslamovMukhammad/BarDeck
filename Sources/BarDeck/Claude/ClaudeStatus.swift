import Foundation

/// One Claude Code session as the Touch Bar needs it.
struct ClaudeSessionInfo: Equatable {
    let id: String
    let project: String
    /// idle | working | waiting | done | error
    let state: String
    let activity: String
    let model: String?
    /// Working folder: tapping a chip uses it to find the app the session runs in.
    let cwd: String?
}

/// Builds Claude Code's state out of its hook events.
///
/// Several sessions can be open at once (one per folder), so state is kept per `session_id`:
/// otherwise one session finishing would wipe out another one's state.
final class ClaudeStatus {

    enum State: String {
        case idle, working, waiting, done, error
    }

    private final class Session {
        let id: String
        var project: String
        var state: State = .idle
        /// The project name is taken from the folder the session started in, once
        /// (a later `cd` doesn't rename it).
        var projectLocked = false
        var activity = "ready"
        var runningTasks = 0
        var lastEventAt: Date
        /// So the transcript isn't read too often (at most every 10 s).
        var lastEndCheck = Date.distantPast
        /// The path the hook reported; it is only trusted after `TranscriptReader.validated`.
        var reportedTranscript: String?
        var lastModelCheck = Date.distantPast
        var cwd: String?
        var transcriptPath: String?
        var model: String?

        var isBusy: Bool { state == .working || state == .waiting }

        init(id: String, project: String, now: Date) {
            self.id = id
            self.project = project
            self.lastEventAt = now
        }
    }

    private var sessions: [String: Session] = [:]
    /// Ask the transcript whether a "working" session has really finished, when the Stop hook
    /// never arrived. Settings → Claude Code.
    var autoDone = true

    var sessionInfos: [ClaudeSessionInfo] {
        // Busy sessions first, then the most recently active.
        sessions.values.sorted { left, right in
            if left.isBusy != right.isBusy { return left.isBusy }
            return left.lastEventAt > right.lastEventAt
        }.map {
            ClaudeSessionInfo(id: $0.id, project: $0.project, state: $0.state.rawValue,
                              activity: $0.activity, model: $0.model, cwd: $0.cwd)
        }
    }

    // MARK: - Hook events

    @discardableResult
    func handle(event: String, payload: [String: Any], now: Date = Date()) -> [ClaudeSessionInfo] {
        let id = payload["session_id"] as? String ?? payload["cwd"] as? String ?? "default"

        if event == "SessionEnd" {
            sessions.removeValue(forKey: id)
            return sessionInfos
        }

        let session = sessions[id] ?? {
            let created = Session(id: id, project: Self.projectName(from: payload) ?? "—", now: now)
            sessions[id] = created
            return created
        }()

        if let transcript = payload["transcript_path"] as? String {
            // Never opened here: it is checked and read off the main thread (see transcriptReads).
            if transcript != session.reportedTranscript {
                session.reportedTranscript = transcript
                session.transcriptPath = nil
                session.lastModelCheck = .distantPast
            }
        }
        if !session.projectLocked, let project = Self.projectName(from: payload) {
            session.project = project
            session.projectLocked = true
        }
        if let cwd = payload["cwd"] as? String { session.cwd = cwd }

        session.lastEventAt = now
        apply(event: event, to: session, payload: payload)
        return sessionInfos
    }

    private func apply(event: String, to session: Session, payload: [String: Any]) {
        switch event {
        case "SessionStart":
            session.state = .idle
            session.activity = "ready"
            session.runningTasks = 0

        case "UserPromptSubmit":
            // The prompt is sent, no tool has been called yet.
            session.state = .working
            session.activity = "thinking"

        case "PreToolUse":
            session.state = .working
            let tool = payload["tool_name"] as? String ?? "tool"
            let input = payload["tool_input"] as? [String: Any]
            if Self.subagentTools.contains(tool) {
                session.runningTasks += 1
                session.activity = Self.taskCountLabel(session.runningTasks)
            } else {
                session.activity = Self.describe(tool: tool, input: input)
            }

        case "PostToolUse":
            session.state = .working
            // The tool finished: Claude is reading the result and picking the next step.
            session.activity = session.runningTasks > 0 ? Self.taskCountLabel(session.runningTasks) : "thinking"

        case "SubagentStop":
            session.state = .working
            session.runningTasks = max(0, session.runningTasks - 1)
            session.activity = session.runningTasks > 0
                ? Self.taskCountLabel(session.runningTasks)
                : "subtask done · continuing"

        case "Notification":
            // Only a real request (a permission, a question) counts as "needs you".
            // `idle_prompt` ("Claude is waiting for your input") arrives about a minute after an
            // answer is done; treating it as a request turned finished sessions blue for no reason.
            let kind = payload["notification_type"] as? String ?? ""
            let message = payload["message"] as? String ?? ""
            let isIdlePrompt = kind == "idle_prompt"
                || (kind.isEmpty && message.localizedCaseInsensitiveContains("waiting for your input"))
            let ignored: Set<String> = ["auth_success", "agent_completed", "elicitation_complete",
                                        "elicitation_response", "quota_auto_resume_fired",
                                        "quota_auto_resume_stale", "quota_auto_resume_disabled"]
            if isIdlePrompt || ignored.contains(kind) { break }
            session.state = .waiting
            session.activity = Self.shortText(message.isEmpty ? nil : message) ?? "waiting for you"

        case "StopFailure":
            // The answer ended with an API error (limit, overload, login…).
            let reason = payload["error"] as? String ?? payload["error_type"] as? String
                ?? payload["matcher"] as? String ?? ""
            session.state = .error
            session.activity = Self.failureText(reason, message: payload["error_message"] as? String ?? payload["message"] as? String)
            session.runningTasks = 0

        case "Stop":
            session.state = .done
            session.activity = "answer ready"
            session.runningTasks = 0

        default:
            break
        }
    }

    /// Called every few seconds: settles sessions whose last hook never came. `true` if anything changed.
    @discardableResult
    func refresh(now: Date = Date()) -> Bool {
        var changed = false
        for (id, session) in sessions {
            let silence = now.timeIntervalSince(session.lastEventAt)

            // One tool call (a long build, a test suite) can run for minutes without any hook,
            // so "working" is only given up after 15 minutes of silence.
            if session.state == .working, silence > 15 * 60 {
                session.state = .idle
                session.activity = "no session"
                session.runningTasks = 0
                changed = true
            }
            if session.state == .error, silence > 5 * 60 {
                session.state = .idle
                session.activity = "no session"
                changed = true
            }
            if session.state == .done, silence > 90 {
                session.state = .idle
                session.activity = "no session"
                changed = true
            }
            // A closed terminal or a crash sends nothing, so a waiting row can't hang forever.
            if session.state == .waiting, silence > 60 * 60 {
                sessions.removeValue(forKey: id)
                changed = true
                continue
            }
            // A deleted transcript means the session is gone. A row without a transcript at
            // all isn't a real session (a hand-sent test event, say).
            if silence > 120 {
                let alive = session.transcriptPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                if !alive {
                    sessions.removeValue(forKey: id)
                    changed = true
                    continue
                }
            }
            // Long-idle sessions shouldn't fill the list.
            if session.state == .idle, silence > 15 * 60 {
                sessions.removeValue(forKey: id)
                changed = true
            }
        }
        return changed
    }

    // MARK: - Transcript reads (done off the main thread by ClaudeFeed)

    struct TranscriptRead: Equatable {
        let sessionID: String
        let path: String
        let wantsModel: Bool
        let wantsEnd: Bool
    }

    /// Which transcripts to look at now: one without a known model (at most every 30 s), and a
    /// "working" session silent for 20 s, because the Stop hook doesn't always arrive and the
    /// session would stay "working" forever (at most every 10 s).
    func transcriptReads(now: Date = Date()) -> [TranscriptRead] {
        sessions.values.compactMap { session in
            guard let path = session.reportedTranscript else { return nil }
            let wantsModel = session.model == nil && now.timeIntervalSince(session.lastModelCheck) > 30
            let wantsEnd = autoDone && session.state == .working
                && now.timeIntervalSince(session.lastEventAt) > 20
                && now.timeIntervalSince(session.lastEndCheck) > 10
            guard wantsModel || wantsEnd else { return nil }
            if wantsModel { session.lastModelCheck = now }
            if wantsEnd { session.lastEndCheck = now }
            return TranscriptRead(sessionID: session.id, path: path, wantsModel: wantsModel, wantsEnd: wantsEnd)
        }
    }

    /// The result of a background read. `validPath` is nil when the reported path was refused.
    @discardableResult
    func apply(_ read: TranscriptRead, validPath: String?, model: String?, end: TranscriptReader.TurnEnd?,
               now: Date = Date()) -> Bool {
        guard let session = sessions[read.sessionID], session.reportedTranscript == read.path else { return false }
        session.transcriptPath = validPath
        guard validPath != nil else { return false }
        var changed = false
        if let model, session.model != model {
            session.model = model
            changed = true
        }
        if let end, end != .running, session.state == .working,
           now.timeIntervalSince(session.lastEventAt) > 20 {
            session.state = .done
            session.activity = end == .interrupted ? "stopped" : "answer ready"
            session.runningTasks = 0
            session.lastEventAt = now
            changed = true
        }
        return changed
    }

    // MARK: - Helpers

    private static let subagentTools: Set<String> = ["Task", "Agent"]

    private static func taskCountLabel(_ count: Int) -> String {
        count == 1 ? "1 task running" : "\(count) tasks running"
    }

    /// A readable line out of the tool name and its input. Hooks hand over the full
    /// `tool_input`; ignoring it would give empty lines like "running a command".
    static func describe(tool: String, input: [String: Any]?) -> String {
        switch tool {
        case "Bash":
            // Claude's own description reads best; paths are cut to the file name.
            if let description = input?["description"] as? String, !description.isEmpty {
                return shorten(stripPaths(description), limit: 64)
            }
            if let command = input?["command"] as? String { return describeCommand(command) }
            return "running a command"
        case "Read":
            return fileName(from: input).map { "reading \($0)" } ?? "reading a file"
        case "Edit", "Write", "NotebookEdit":
            return fileName(from: input).map { "editing \($0)" } ?? "editing a file"
        case "Grep":
            return "searching the code"
        case "Glob":
            return "looking for files"
        case "WebSearch":
            if let query = input?["query"] as? String { return "searching: \(shorten(query, limit: 48))" }
            return "searching the web"
        case "WebFetch":
            if let url = input?["url"] as? String { return "fetching \(URL(string: url)?.host ?? "a page")" }
            return "fetching a page"
        case "TodoWrite":
            return "updating the plan"
        case "Skill":
            if let skill = input?["skill"] as? String { return "using the \(skill) skill" }
            return "using a skill"
        case "AskUserQuestion":
            return "asking you a question"
        case "ToolSearch":
            return "loading tools"
        case "EnterPlanMode", "ExitPlanMode":
            return "planning"
        default:
            if tool.hasPrefix("mcp__") { return describeMCP(tool) }
            return "using \(tool)"
        }
    }

    /// Raw names like "mcp__Claude_Browser__browser_batch" are jargon at arm's length.
    private static func describeMCP(_ tool: String) -> String {
        let parts = tool.components(separatedBy: "__")
        let server = parts.count > 1 ? parts[1] : tool
        let lower = server.lowercased()
        if lower.contains("browser") || lower.contains("chrome") { return "using the browser" }
        if lower.contains("simulator") { return "using the iOS Simulator" }
        if lower.contains("terminal") { return "using the terminal" }
        let readable = server.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        // A long generated id (a UUID, say) gets a generic label.
        if readable.count > 28 || readable.filter(\.isNumber).count > 6 { return "using a connected tool" }
        return "using \(readable)"
    }

    private static func fileName(from input: [String: Any]?) -> String? {
        guard let path = input?["file_path"] as? String ?? input?["notebook_path"] as? String else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// Absolute paths become file names ("/a/b/c.swift" → "c.swift"); `~/…` and `$HOME/…` too.
    private static func stripPaths(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            let trimmed = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`()"))
            guard trimmed.contains("/"), trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("$") else { return w }
            let last = (trimmed as NSString).lastPathComponent
            return last.isEmpty ? "files" : last
        }.joined(separator: " ")
    }

    /// A command without a description: a plain verb from its first word, never the raw text.
    private static func describeCommand(_ command: String) -> String {
        let line = command.split(separator: "\n").first.map(String.init) ?? command
        var words = line.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "&" || $0 == "|" }).map(String.init)
        while let first = words.first, ["cd", "export", "set", "env", "time", "sudo", "nohup"].contains(first) {
            words.removeFirst()
            if first == "cd", !words.isEmpty { words.removeFirst() }
        }
        guard let raw = words.first else { return "running a command" }
        switch (raw as NSString).lastPathComponent.lowercased() {
        case "git": return "using git"
        case "xcodebuild", "swift", "swiftc": return "building the app"
        case "python", "python3", "node", "ruby": return "running a script"
        case "ls", "cat", "head", "tail", "sed", "awk", "find", "wc", "stat", "file": return "reading files"
        case "grep", "rg", "ag": return "searching the code"
        case "curl", "wget": return "calling the network"
        case "npm", "pnpm", "yarn", "brew", "pip", "pip3": return "managing packages"
        case "open", "osascript": return "controlling an app"
        case "pkill", "kill", "killall": return "stopping a process"
        case "rm", "mv", "cp", "mkdir", "touch", "ditto", "chmod": return "managing files"
        case "sleep", "until", "while": return "waiting"
        default: return "running a command"
        }
    }

    private static func projectName(from payload: [String: Any]) -> String? {
        guard let cwd = payload["cwd"] as? String else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    private static func failureText(_ reason: String, message: String?) -> String {
        switch reason {
        case "rate_limit": return "limit reached"
        case "overloaded": return "API overloaded"
        case "authentication_failed": return "login problem"
        case "billing_error": return "billing problem"
        case "server_error": return "server error"
        default:
            if let message = shortText(message) { return message }
            return reason.isEmpty ? "API error" : reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func shorten(_ text: String, limit: Int) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    private static func shortText(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > 110 ? String(single.prefix(110)) + "…" : single
    }
}

/// Reads the end of a session transcript (a `.jsonl` file Claude Code writes).
enum TranscriptReader {


    enum TurnEnd { case finished, interrupted, running }

    nonisolated static var projectsRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects").path
    }

    /// The path the hook reported, or nil unless it resolves (symlinks and "..") to a regular
    /// file inside Claude's projects folder. A FIFO or a device would block the reader, and
    /// anything outside that folder is none of BarDeck's business.
    nonisolated static func validated(_ path: String, root: String = projectsRoot) -> String? {
        guard path.hasPrefix("/"), let real = realPath(path), let realRoot = realPath(root) else { return nil }
        guard real.hasPrefix(realRoot.hasSuffix("/") ? realRoot : realRoot + "/") else { return nil }
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return real
    }

    nonisolated private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Reads a validated transcript. Opened non-blocking and re-checked as a regular file on the
    /// open descriptor, so a file swapped after validation still can't hang the read.
    nonisolated static func read(_ path: String, wantsModel: Bool, wantsEnd: Bool,
                                 root: String = projectsRoot) -> (validPath: String?, model: String?, end: TurnEnd?) {
        guard let valid = validated(path, root: root) else { return (nil, nil, nil) }
        let lines = tailLines(valid)
        return (valid, wantsModel ? model(lines: lines) : nil, wantsEnd ? turnEnd(lines: lines) : nil)
    }

    /// The last 256 KB is plenty: only the most recent entries matter.
    nonisolated private static func tailLines(_ path: String, window: UInt64 = 256 * 1024) -> [Substring] {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { return [] }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
    }

    /// Did the last answer end? A final assistant entry with `end_turn` means yes; a later
    /// "user" entry (a tool result or a new prompt) means it is still going.
    nonisolated static func turnEnd(lines: [Substring]) -> TurnEnd {
        for line in lines.reversed() {
            guard let object = json(line), let type = object["type"] as? String else { continue }
            if type == "user" {
                // Esc may not send the Stop hook; the transcript gets "[Request interrupted by user…]".
                return isInterruptMarker(object) ? .interrupted : .running
            }
            if type == "assistant", let reason = (object["message"] as? [String: Any])?["stop_reason"] as? String {
                return ["end_turn", "stop_sequence", "max_tokens"].contains(reason) ? .finished : .running
            }
        }
        return .running
    }

    /// The model of the latest assistant entry, e.g. "claude-opus-5-5".
    nonisolated static func model(lines: [Substring]) -> String? {
        for line in lines.reversed() where line.contains("\"model\"") {
            if let object = json(line), let model = (object["message"] as? [String: Any])?["model"] as? String,
               model.hasPrefix("claude") {
                return model
            }
        }
        return nil
    }

    nonisolated private static func json(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated private static func isInterruptMarker(_ object: [String: Any]) -> Bool {
        guard let message = object["message"] as? [String: Any] else { return false }
        let marker = "[Request interrupted by user"
        if let text = message["content"] as? String { return text.hasPrefix(marker) }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.contains { ($0["text"] as? String)?.hasPrefix(marker) == true }
        }
        return false
    }
}
