import Foundation

/// Watches Claude Code sessions (CLI and the Claude desktop app's Code tab).
///
/// Claude Code keeps a tiny live status file per running process in
/// `~/.claude/sessions/<pid>.json` with `status: busy | idle`. For the "what is it
/// doing" line, and how a turn ended (API error, interrupted), we tail the session
/// transcript in `~/.claude/projects/<encoded cwd>/<sessionId>.jsonl`.
///
/// A permission prompt doesn't change the status file (it stays `busy`), so the
/// optional `Notification` hook (see `HookInstaller.installClaude`) reports those.
/// The prompt counts as open until the transcript moves on.
final class ClaudeMonitor: AgentMonitor {
    let harness = Harness.claude

    private let root = FileUtil.home.appendingPathComponent(".claude")
    private var tailCache: [String: (mtime: Date, tail: Tail)] = [:]
    private let events = HookEventReader(agent: "claude")
    /// Open permission prompts / questions per session id: when they were raised and what they say.
    private var prompts: [String: (at: Date, message: String)] = [:]

    private struct Tail {
        var text: String?
        var end: TurnEnd = .completed
    }

    private struct SessionFile: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let name: String?
        let status: String?
        let startedAt: Double?
        let updatedAt: Double?
        let statusUpdatedAt: Double?
        let entrypoint: String?
    }

    func poll(now: Date) -> [AgentSession] {
        for e in events.read() where e.name == "Notification" {
            guard let id = e.payload["session_id"] as? String else { continue }
            switch e.payload["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog":
                prompts[id] = (e.at, (e.payload["message"] as? String) ?? "Waiting for your approval")
            default:
                break  // idle_prompt and friends: the turn is already over
            }
        }

        let dir = root.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }

        var result: [AgentSession] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? JSONDecoder().decode(SessionFile.self, from: data),
                  FileUtil.isAlive(s.pid) else { continue }

            let status = (s.status ?? "idle").lowercased()
            let state: AgentState
            switch status {
            case "busy", "working", "running", "streaming": state = .working
            case "idle", "ready", "done": state = .idle
            default: state = .waiting  // "waiting", "permission", "input"... anything that isn't plainly busy or idle
            }

            let statusDate = (s.statusUpdatedAt ?? s.updatedAt).map { Date(timeIntervalSince1970: $0 / 1000) }
            let project = s.cwd?.lastPathComponent ?? "Claude"
            let transcript = transcriptURL(cwd: s.cwd, sessionId: s.sessionId)
            let transcriptDate = transcript.flatMap(FileUtil.mtime)

            var session = AgentSession(
                id: "claude:\(s.sessionId)",
                harness: .claude,
                title: (s.name?.isEmpty == false ? s.name! : project),
                project: project,
                cwd: s.cwd,
                state: state,
                activity: nil,
                workingSince: state == .working ? statusDate : nil,
                lastActivity: max(statusDate ?? .distantPast, transcriptDate ?? .distantPast),
                pid: s.pid,
                host: s.entrypoint
            )
            if let transcript {
                let tail = self.tail(transcript, key: s.sessionId)
                if state != .idle {
                    session.activity = tail.text
                } else {
                    session.lastEnd = tail.end
                    if tail.end == .failed { session.activity = tail.text }
                }
            }

            // An open permission prompt: the transcript hasn't moved since it was raised.
            if let prompt = prompts[s.sessionId] {
                if state == .working, (transcriptDate ?? .distantPast) <= prompt.at.addingTimeInterval(0.3) {
                    session.state = .waiting
                    session.activity = prompt.message
                } else {
                    prompts[s.sessionId] = nil
                }
            }
            result.append(session)
        }
        return result
    }

    private func transcriptURL(cwd: String?, sessionId: String) -> URL? {
        guard let cwd else { return nil }
        let encoded = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let url = root.appendingPathComponent("projects/\(encoded)/\(sessionId).jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Latest tool call / thinking step from the end of the transcript, and how the turn ended.
    private func tail(_ url: URL, key: String) -> Tail {
        guard let mtime = FileUtil.mtime(url) else { return Tail() }
        if let cached = tailCache[key], cached.mtime == mtime { return cached.tail }

        var text: String?
        var end = TurnEnd.completed
        for line in FileUtil.tailLines(url, bytes: 192 * 1024).reversed() {
            guard line.contains("\"type\":\"assistant\"") || line.contains("\"type\":\"user\"") else { continue }
            guard let obj = FileUtil.json(line), let type = obj["type"] as? String else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            let content = (obj["message"] as? [String: Any])?["content"]

            if obj["isApiErrorMessage"] as? Bool == true {
                end = .failed
                let blocks = content as? [[String: Any]]
                text = (blocks?.first?["text"] as? String)?.clipped(80) ?? "API error"
                break
            }
            if type == "user", Self.text(of: content).hasPrefix("[Request interrupted") {
                end = .interrupted
                break
            }

            if type == "user" {
                // A tool result is the latest thing: the model is digesting it.
                if let blocks = content as? [[String: Any]], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    text = "Thinking…"
                    break
                }
                text = "Reading your prompt…"
                break
            }
            guard let blocks = content as? [[String: Any]], let last = blocks.last else { continue }
            switch last["type"] as? String {
            case "tool_use":
                text = ActivityText.tool(last["name"] as? String ?? "tool", input: last["input"] as? [String: Any])
            case "thinking", "redacted_thinking":
                text = "Thinking…"
            case "text":
                text = "Writing a reply…"
            default:
                continue
            }
            break
        }
        let result = Tail(text: text, end: end)
        tailCache[key] = (mtime, result)
        return result
    }

    private static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        let blocks = content as? [[String: Any]]
        return blocks?.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    }
}
