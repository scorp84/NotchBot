import AppKit

/// Watches Cursor agent chats (IDE and cursor-agent CLI) through Cursor hooks.
///
/// Cursor doesn't leave a readable live status on disk, so NotchBot registers a
/// tiny bridge script in `~/.cursor/hooks.json` (see `HookInstaller`). Each hook
/// call appends the payload to `~/.notchbot/events.jsonl`, which we tail here.
final class CursorMonitor: AgentMonitor {
    let harness = Harness.cursor
    static let bundleID = Harness.cursor.bundleID

    private let events = HookEventReader(agent: "cursor")
    private var wasRunning = false
    private var sessions: [String: AgentSession] = [:]
    /// Shell / MCP calls announced by a "before" hook that haven't reported back yet.
    private var pending: [String: Date] = [:]
    /// Cursor asks before running most commands; a call still pending after this long is probably waiting on you.
    private let approvalGuess: TimeInterval = 8

    func poll(now: Date) -> [AgentSession] {
        for e in events.read() { apply(e.payload, name: e.name, at: e.at) }

        // A working chat that has been silent for a long time probably got interrupted.
        for (id, s) in sessions where s.state == .working && now.timeIntervalSince(s.lastActivity) > 10 * 60 {
            sessions[id]?.state = .idle
            sessions[id]?.activity = nil
            sessions[id]?.lastEnd = .interrupted  // we never saw it end: don't claim it finished
        }
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastActivity) < 3 * 3600 }

        // Cursor just quit → its IDE chats can't be running anymore (cursor-agent CLI chats keep going).
        let cursorRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if wasRunning, !cursorRunning {
            for (id, s) in sessions where s.state != .idle {
                sessions[id]?.state = .idle
                sessions[id]?.activity = nil
                sessions[id]?.lastEnd = .interrupted  // we never saw it end: don't claim it finished
            }
        }
        wasRunning = cursorRunning

        // A chat that was opened but never prompted isn't worth a row.
        return sessions.values.filter { $0.title != "New chat" || $0.state != .idle }.map { s in
            guard s.state == .working, let since = pending[s.id], now.timeIntervalSince(since) > approvalGuess else { return s }
            var s = s
            s.state = .waiting
            s.guessedWait = true
            s.activity = "Approval? " + (s.activity ?? "")
            return s
        }
    }

    private func apply(_ p: [String: Any], name: String, at ts: Date) {
        guard let conv = p["conversation_id"] as? String ?? p["session_id"] as? String else { return }
        let roots = p["workspace_roots"] as? [String]
        let cwd = roots?.first ?? (p["cwd"] as? String)
        let id = "cursor:\(conv)"

        if name == "sessionEnd" {
            sessions[id] = nil
            pending[id] = nil
            return
        }
        // Any sign of life after a "before" means the call went ahead (or was declined).
        if name == "beforeShellExecution" || name == "beforeMCPExecution" {
            pending[id] = ts
        } else {
            pending[id] = nil
        }

        var s = sessions[id] ?? AgentSession(
            id: id,
            harness: .cursor,
            title: "New chat",
            project: cwd?.lastPathComponent ?? "Cursor",
            cwd: cwd,
            state: .idle,
            lastActivity: ts,
            host: (p["is_background_agent"] as? Bool == true) ? "background" : nil
        )
        if let cwd, s.cwd == nil {
            s.cwd = cwd
            s.project = cwd.lastPathComponent
        }
        s.lastActivity = ts

        func startWorking() {
            if s.state != .working { s.workingSince = ts }
            s.state = .working
        }

        switch name {
        case "sessionStart":
            break
        case "beforeSubmitPrompt":
            if let prompt = p["prompt"] as? String, !prompt.isEmpty, s.title == "New chat" {
                s.title = prompt.clipped(60)
            }
            s.workingSince = ts
            s.state = .working
            s.lastEnd = .completed
            s.activity = "Reading your prompt…"
        case "afterAgentThought":
            startWorking(); s.activity = "Thinking…"
        case "afterAgentResponse":
            startWorking(); s.activity = "Writing a reply…"
        case "afterShellExecution", "beforeShellExecution":
            startWorking()
            s.activity = (p["command"] as? String).map { "$ " + ActivityText.shortCommand($0) } ?? "Running a command"
        case "afterFileEdit":
            startWorking()
            s.activity = (p["file_path"] as? String).map { "Editing \($0.lastPathComponent)" } ?? "Editing files"
        case "beforeReadFile":
            startWorking()
            s.activity = (p["file_path"] as? String).map { "Reading \($0.lastPathComponent)" } ?? "Reading files"
        case "afterMCPExecution", "beforeMCPExecution":
            startWorking()
            s.activity = "Using \((p["tool_name"] as? String) ?? "a tool")"
        case "preToolUse", "postToolUse":
            startWorking()
            s.activity = ActivityText.tool(p["tool_name"] as? String ?? "tool", input: p["tool_input"] as? [String: Any])
        case "stop":
            s.state = .idle
            s.activity = nil
            switch p["status"] as? String {
            case "aborted":
                s.lastEnd = .interrupted
            case "error":
                s.lastEnd = .failed
                s.activity = "Stopped with an error"
            default:
                s.lastEnd = .completed
            }
        default:
            break
        }
        sessions[id] = s
    }
}
