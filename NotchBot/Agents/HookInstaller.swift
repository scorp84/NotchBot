import Foundation

/// Installs the hook bridge that lets Cursor (activity) and Claude Code (permission
/// prompts) report to NotchBot.
///
/// The bridge is a small shell script in `~/.notchbot/` that appends every hook
/// payload to `~/.notchbot/events.jsonl`. Installing only adds NotchBot's own
/// entries to `~/.cursor/hooks.json` / `~/.claude/settings.json`; everything else
/// in those files is kept, and a backup is written next to each first.
enum HookInstaller {
    static let dir = FileUtil.home.appendingPathComponent(".notchbot")
    static let scriptURL = dir.appendingPathComponent("notchbot-hook")
    static let eventsURL = dir.appendingPathComponent("events.jsonl")
    static let cursorHooksURL = FileUtil.home.appendingPathComponent(".cursor/hooks.json")
    static let claudeSettingsURL = FileUtil.home.appendingPathComponent(".claude/settings.json")

    static let cursorEvents = [
        "sessionStart", "sessionEnd", "beforeSubmitPrompt", "stop",
        "postToolUse", "afterShellExecution", "afterFileEdit", "afterMCPExecution",
        "afterAgentThought", "afterAgentResponse",
        // A "before" with no matching "after" for a while usually means Cursor is asking for approval.
        // The bridge answers {} here, which Cursor treats as "no opinion": its own approval flow is unchanged.
        "beforeShellExecution", "beforeMCPExecution",
    ]

    private static let script = """
    #!/bin/sh
    # NotchBot hook bridge — forwards agent hook payloads to the NotchBot notch app.
    # Usage: notchbot-hook <agent> <event>   (payload JSON on stdin)
    dir="$HOME/.notchbot"
    mkdir -p "$dir"
    payload=$(cat | tr '\\n\\r' '  ')
    [ -z "$payload" ] && payload=null
    ts=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null || date +%s)
    printf '{"agent":"%s","event":"%s","ts":%s,"payload":%s}\\n' "${1:-unknown}" "${2:-}" "$ts" "$payload" >> "$dir/events.jsonl"
    if [ "$2" = "beforeSubmitPrompt" ]; then echo '{"continue":true}'; else echo '{}'; fi
    exit 0

    """

    /// Writes the bridge script and trims the event log. Safe to call on every launch.
    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? String(contentsOf: scriptURL, encoding: .utf8)) != script {
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Keep the log small: rotate once it passes 5 MB.
        if FileUtil.size(eventsURL) > 5_000_000 {
            let old = dir.appendingPathComponent("events.old.jsonl")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: eventsURL, to: old)
        }
    }

    static var isCursorInstalled: Bool {
        guard let text = try? String(contentsOf: cursorHooksURL, encoding: .utf8) else { return false }
        return text.contains("notchbot-hook")
    }

    static var isCursorPresent: Bool {
        FileManager.default.fileExists(atPath: FileUtil.home.appendingPathComponent(".cursor").path)
    }

    /// Whether the installed Cursor hooks cover every event this version listens to.
    static var cursorHasAllEvents: Bool {
        guard let text = try? String(contentsOf: cursorHooksURL, encoding: .utf8) else { return false }
        return cursorEvents.allSatisfy { text.contains("notchbot-hook' cursor \($0)") }
    }

    static func installCursor() throws {
        prepare()
        var root = try readCursorHooks()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in cursorEvents {
            var entries = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            entries.append([
                "command": "'\(scriptURL.path)' cursor \(event)",
                "timeout": 5,
            ])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        if root["version"] == nil { root["version"] = 1 }
        try writeCursorHooks(root)
    }

    static func uninstallCursor() throws {
        var root = try readCursorHooks()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks
        try writeCursorHooks(root)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains("notchbot-hook") == true
    }

    // MARK: Claude Code

    static var isClaudeInstalled: Bool {
        guard let text = try? String(contentsOf: claudeSettingsURL, encoding: .utf8) else { return false }
        return text.contains("notchbot-hook")
    }

    /// Adds one `Notification` hook (permission prompts and questions) to ~/.claude/settings.json.
    static func installClaude() throws {
        prepare()
        var root = try readJSONObject(claudeSettingsURL, empty: [:])
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = (hooks["Notification"] as? [[String: Any]] ?? []).filter { !isOurGroup($0) }
        groups.append(["hooks": [["type": "command", "command": "'\(scriptURL.path)' claude Notification", "timeout": 5]]])
        hooks["Notification"] = groups
        root["hooks"] = hooks
        try writeJSONObject(root, to: claudeSettingsURL, backupName: "settings.json.notchbot-backup")
    }

    static func uninstallClaude() throws {
        var root = try readJSONObject(claudeSettingsURL, empty: [:])
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurGroup($0) }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSONObject(root, to: claudeSettingsURL, backupName: "settings.json.notchbot-backup")
    }

    private static func isOurGroup(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains(where: isOurs) == true
    }

    private static func readCursorHooks() throws -> [String: Any] {
        try readJSONObject(cursorHooksURL, empty: ["version": 1, "hooks": [String: Any]()])
    }

    private static func writeCursorHooks(_ root: [String: Any]) throws {
        try writeJSONObject(root, to: cursorHooksURL, backupName: "hooks.json.notchbot-backup")
    }

    // MARK: JSON files

    private static func readJSONObject(_ url: URL, empty: [String: Any]) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return empty }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NotchBot", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) isn't a JSON object"])
        }
        return obj
    }

    private static func writeJSONObject(_ root: [String: Any], to url: URL, backupName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent(backupName)
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

/// Tails `~/.notchbot/events.jsonl` for one agent's hook events. Each monitor owns one.
final class HookEventReader {
    struct Event {
        let name: String
        let payload: [String: Any]
        let at: Date
    }

    private let agent: String
    private var offset: UInt64 = 0
    private var primed = false

    init(agent: String) { self.agent = agent }

    /// Events appended since the last call (on first call, only the last ~1 MB).
    func read() -> [Event] {
        let url = HookInstaller.eventsURL
        let size = FileUtil.size(url)
        if size < offset { offset = 0 }  // file was rotated
        guard size > offset else { return [] }

        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        if !primed, size > 1_000_000 { offset = size - 1_000_000 }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd() else { return [] }

        // Only consume complete lines; a partially written one waits for the next poll.
        guard let lastNL = data.lastIndex(of: 0x0A) else { return [] }
        let complete = data[data.startIndex...lastNL]
        offset += UInt64(complete.count)
        primed = true

        guard let text = String(data: complete, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let obj = FileUtil.json(line), obj["agent"] as? String == agent,
                  let payload = obj["payload"] as? [String: Any] else { return nil }
            let at = (obj["ts"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
            let name = (payload["hook_event_name"] as? String) ?? (obj["event"] as? String) ?? ""
            return Event(name: name, payload: payload, at: at)
        }
    }
}
