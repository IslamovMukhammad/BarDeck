import Foundation

import Security

/// Installs (or removes) the Claude Code hooks that feed the Claude card.
///
/// Three pieces, all in `~/Library/Application Support/BarDeck/` (0700) plus Claude's settings:
///   1. `claude-hook.sh` (0700): reads the hook's JSON from stdin, keeps only the few fields the
///      card needs, and posts them to BarDeck's Unix socket in the background. It never blocks
///      Claude and always exits 0. Your prompts and tool output never leave Claude.
///   2. `hook-token` (0600): a random token made at install. The script sends it with every
///      event and BarDeck drops anything without it.
///   3. One entry per hook event in `~/.claude/settings.json` that runs the script. Other hooks
///      in that file are left alone, and a backup is written before the first change.
enum ClaudeHooks {

    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                         "SubagentStop", "Notification", "Stop", "StopFailure", "SessionEnd"]
    /// Tool events need a matcher; "*" means every tool.
    private static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static var scriptURL: URL { AppSupport.directory.appendingPathComponent("claude-hook.sh") }
    static var tokenURL: URL { AppSupport.directory.appendingPathComponent("hook-token") }

    /// 32 random bytes as hex.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static var cachedToken: String??

    /// The installed token, or nil when the hooks aren't installed (then every event is dropped).
    static func currentToken(tokenURL: URL = tokenURL) -> String? {
        if tokenURL == Self.tokenURL, let cached = cachedToken { return cached }
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (token?.isEmpty ?? true) ? nil : token
        if tokenURL == Self.tokenURL { cachedToken = .some(value) }
        return value
    }

    /// Wrapped in single quotes for sh; a single quote inside becomes '\''.
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func script(socketPath: String, token: String) -> String {
        template
            .replacingOccurrences(of: "__SOCKET__", with: shellQuoted(socketPath))
            .replacingOccurrences(of: "__TOKEN__", with: shellQuoted(token))
    }

    private static let template = #"""
    #!/bin/sh
    # Installed by BarDeck. Sends a few fields of each Claude Code hook event to the Touch Bar
    # over BarDeck's own Unix socket. Never blocks Claude and never returns an error.
    #
    # Only these leave Claude: the event name, session id, working folder, transcript path,
    # tool name, a short hint about the tool (its description, a file name, a web host, a
    # search query, a skill, or just the program name of a shell command) and the text of
    # a notification. Never your prompts, file contents or tool output.

    SOCKET=__SOCKET__
    TOKEN=__TOKEN__
    EVENT="${1:-unknown}"
    PAYLOAD=$(cat 2>/dev/null)
    [ -S "$SOCKET" ] || exit 0

    (
      field() { printf '%s' "$PAYLOAD" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }
      # JSON string: drop control characters, escape backslashes and quotes.
      esc() { printf '%s' "$1" | /usr/bin/tr -d '\000-\037' | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
      # The program a shell command runs ("cd x && git status" -> "git"), never its arguments.
      program() {
        line=$(printf '%s\n' "$1" | /usr/bin/head -n 1 | /usr/bin/tr ';&|' '   ')
        set -f; set -- $line; set +f
        while [ $# -gt 0 ]; do
          case "$1" in
            cd) shift; [ $# -gt 0 ] && shift ;;
            export|set|env|time|sudo|nohup|*=*) shift ;;
            *) break ;;
          esac
        done
        [ $# -gt 0 ] && /usr/bin/basename -- "$1"
      }

      FILE=$(field tool_input.file_path); [ -z "$FILE" ] && FILE=$(field tool_input.notebook_path)
      [ -n "$FILE" ] && FILE=$(/usr/bin/basename -- "$FILE")
      HOST=$(field tool_input.url); HOST=${HOST#*://}; HOST=${HOST%%[/?#]*}; [ -n "$HOST" ] && HOST="https://$HOST"
      PROG=$(program "$(field tool_input.command)")

      BODY=$(printf '{"event":"%s","payload":{"session_id":"%s","cwd":"%s","transcript_path":"%s","tool_name":"%s","notification_type":"%s","message":"%s","error":"%s","tool_input":{"description":"%s","file_path":"%s","url":"%s","query":"%s","skill":"%s","command":"%s"}}}' \
        "$(esc "$EVENT")" "$(esc "$(field session_id)")" "$(esc "$(field cwd)")" "$(esc "$(field transcript_path)")" \
        "$(esc "$(field tool_name)")" "$(esc "$(field notification_type)")" "$(esc "$(field message)")" "$(esc "$(field error)")" \
        "$(esc "$(field tool_input.description)")" "$(esc "$FILE")" "$(esc "$HOST")" "$(esc "$(field tool_input.query)")" \
        "$(esc "$(field tool_input.skill)")" "$(esc "$PROG")")

      /usr/bin/curl -s -m 2 --unix-socket "$SOCKET" -X POST "http://localhost/claude-event" \
        -H "Content-Type: application/json" -H "X-BarDeck-Token: $TOKEN" \
        --data-binary "$BODY" >/dev/null 2>&1
    ) >/dev/null 2>&1 &

    exit 0

    """#

    static func command(for event: String, scriptPath: String) -> String {
        "\"\(scriptPath)\" \(event)"
    }

    // MARK: - Pure JSON edits (unit-tested)

    /// Adds our hook to every event that doesn't already have it. Everything else is kept.
    static func adding(to settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(scriptPath) == true }
            }
            guard !present else { continue }
            var group: [String: Any] = ["hooks": [["type": "command", "command": command(for: event, scriptPath: scriptPath)]]]
            if matcherEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Removes only our hook commands; empty groups and events are dropped.
    static func removing(from settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let commands = group["hooks"] as? [[String: Any]] else { return group }
                let others = commands.filter { ($0["command"] as? String)?.contains(scriptPath) != true }
                if others.isEmpty { return nil }
                var copy = group
                copy["hooks"] = others
                return copy
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return settings
    }

    static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(scriptPath) == true }
            }
        }
    }

    // MARK: - Files

    enum HookError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Couldn't read \(path) as JSON. Nothing was changed."
            }
        }
    }

    static func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HookError.unreadable(url.path)
        }
        return object
    }

    /// Writes a fresh token, the script and the hook entries. Returns the new token.
    @discardableResult
    static func install(settingsURL: URL = defaultSettingsURL, scriptURL: URL = scriptURL,
                        tokenURL: URL = tokenURL,
                        socketPath: String = ClaudeEventServer.socketURL.path) throws -> String {
        let settings = try readSettings(settingsURL)
        let fm = FileManager.default
        let folder = scriptURL.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let token = makeToken()
        try writePrivate(Data(token.utf8), to: tokenURL, mode: 0o600)
        try writePrivate(Data(script(socketPath: socketPath, token: token).utf8), to: scriptURL, mode: 0o700)
        if tokenURL == Self.tokenURL { cachedToken = .some(token) }
        try write(adding(to: settings, scriptPath: scriptURL.path), to: settingsURL)
        return token
    }

    static func uninstall(settingsURL: URL = defaultSettingsURL, scriptURL: URL = scriptURL,
                          tokenURL: URL = tokenURL) throws {
        let settings = try readSettings(settingsURL)
        try write(removing(from: settings, scriptPath: scriptURL.path), to: settingsURL)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: tokenURL)
        if tokenURL == Self.tokenURL { cachedToken = .some(nil) }
    }

    /// Created with the final permissions, so the secret is never readable by others, even briefly.
    private static func writePrivate(_ data: Data, to url: URL, mode: mode_t) throws {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        fchmod(fd, mode)
    }

    static func isInstalled(settingsURL: URL = defaultSettingsURL, scriptURL: URL = scriptURL) -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              let settings = try? readSettings(settingsURL) else { return false }
        return isInstalled(in: settings, scriptPath: scriptURL.path)
    }

    /// Keeps one backup of the file as it was before BarDeck first touched it.
    private static func write(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("bardeck-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// `~/Library/Application Support/BarDeck/`
enum AppSupport {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BarDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The socket, the token and the hook script live here: you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()
}
