import Foundation

/// Watches Codex threads (Codex desktop app and the Codex CLI).
///
/// Every thread appends to a rollout file in `~/.codex/sessions/YYYY/MM/DD/`.
/// A turn opens with an `event_msg/task_started` and closes with `task_complete`
/// (or `turn_aborted`), so the last of those tells us whether it's working.
/// Thread titles live in `~/.codex/session_index.jsonl`.
final class CodexMonitor: AgentMonitor {
    let harness = Harness.codex

    private let root = FileUtil.home.appendingPathComponent(".codex")
    /// How far back a thread may have been touched to be considered at all.
    private let window: TimeInterval = 3 * 3600

    private struct Meta {
        let id: String
        let cwd: String?
        let originator: String?
        let threadSource: String
        let parentId: String?
        let nickname: String?
    }

    private struct Parsed {
        var mtime: Date
        var state: AgentState
        var workingSince: Date?
        var activity: String?
        var lastEvent: Date?
        var firstPrompt: String?
        var end: TurnEnd = .completed
    }

    private var metas: [URL: Meta] = [:]
    private var parsed: [URL: Parsed] = [:]
    private var names: [String: String] = [:]
    private var namesMtime: Date?
    private var dirCache: (checked: Date, files: [URL])?

    func poll(now: Date) -> [AgentSession] {
        loadNames()
        var sessions: [String: AgentSession] = [:]
        var helpersByParent: [String: Int] = [:]

        for url in recentRollouts(now: now) {
            guard let mtime = FileUtil.mtime(url), now.timeIntervalSince(mtime) < window else { continue }
            guard let meta = meta(for: url) else { continue }
            if meta.threadSource.hasPrefix("guardian") { continue }  // internal approval reviewers

            var p = parsed[url]
            if p == nil || p!.mtime != mtime {
                p = parse(url, mtime: mtime, previous: p)
                parsed[url] = p
            }
            guard var info = p else { continue }

            // A turn that went silent for a long time most likely died with its process.
            if info.state == .working, now.timeIntervalSince(mtime) > 15 * 60 {
                info.state = .idle
                info.end = .interrupted
            }

            if meta.threadSource == "subagent", let parent = meta.parentId {
                if info.state == .working { helpersByParent[parent, default: 0] += 1 }
                continue
            }

            let project = meta.cwd?.lastPathComponent ?? "Codex"
            let title = names[meta.id] ?? info.firstPrompt?.clipped(60) ?? project
            sessions[meta.id] = AgentSession(
                id: "codex:\(meta.id)",
                harness: .codex,
                title: title,
                project: project,
                cwd: meta.cwd,
                state: info.state,
                activity: info.state != .idle || info.end == .failed ? info.activity : nil,
                workingSince: info.state == .working ? info.workingSince : nil,
                lastActivity: info.lastEvent ?? mtime,
                host: meta.originator,
                lastEnd: info.end
            )
        }

        for (parent, count) in helpersByParent {
            sessions[parent]?.helpers = count
        }
        return Array(sessions.values)
    }

    // MARK: - Discovery

    /// Rollouts from today's and yesterday's folders (re-listed every few seconds).
    private func recentRollouts(now: Date) -> [URL] {
        if let c = dirCache, now.timeIntervalSince(c.checked) < 3 { return c.files }
        let cal = Calendar.current
        var files: [URL] = []
        for dayOffset in [0, -1] {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let path = String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
            let dir = root.appendingPathComponent(path)
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            files += items.filter { $0.pathExtension == "jsonl" }
        }
        dirCache = (now, files)
        return files
    }

    private func meta(for url: URL) -> Meta? {
        if let m = metas[url] { return m }
        guard let line = FileUtil.firstLine(url), let obj = FileUtil.json(Substring(line)),
              let p = obj["payload"] as? [String: Any], let id = p["id"] as? String ?? p["session_id"] as? String else { return nil }
        let m = Meta(
            id: id,
            cwd: p["cwd"] as? String,
            originator: p["originator"] as? String,
            threadSource: p["thread_source"] as? String ?? "user",
            parentId: p["parent_thread_id"] as? String,
            nickname: p["agent_nickname"] as? String
        )
        metas[url] = m
        return m
    }

    private func loadNames() {
        let url = root.appendingPathComponent("session_index.jsonl")
        guard let mtime = FileUtil.mtime(url), mtime != namesMtime else { return }
        namesMtime = mtime
        for line in FileUtil.tailLines(url, bytes: 2 * 1024 * 1024) {
            guard let o = FileUtil.json(line), let id = o["id"] as? String,
                  let name = o["thread_name"] as? String, !name.isEmpty else { continue }
            names[id] = name
        }
    }

    // MARK: - Parsing

    private func parse(_ url: URL, mtime: Date, previous: Parsed?) -> Parsed {
        var result = Parsed(mtime: mtime, state: .idle)
        var foundTurnBoundary = false
        var foundActivity = false
        /// An error reported after the last turn boundary, if any.
        var errorMessage: String?

        let lines = FileUtil.tailLines(url, bytes: 512 * 1024)
        for line in lines.reversed() {
            if foundTurnBoundary && foundActivity { break }
            guard let obj = FileUtil.json(line) else { continue }
            let ts = FileUtil.date(obj["timestamp"] as? String)
            if result.lastEvent == nil { result.lastEvent = ts }
            guard let payload = obj["payload"] as? [String: Any], let ptype = payload["type"] as? String else { continue }
            let kind = obj["type"] as? String

            if kind == "event_msg" {
                switch ptype {
                case "task_started", "turn_started":
                    if !foundTurnBoundary {
                        result.state = .working
                        result.workingSince = ts
                        foundTurnBoundary = true
                    }
                case "task_complete", "turn_complete", "turn_aborted":
                    if !foundTurnBoundary {
                        result.state = .idle
                        foundTurnBoundary = true
                        if ptype == "turn_aborted" {
                            result.end = payload["reason"] as? String == "interrupted" ? .interrupted : .failed
                        }
                        if let errorMessage {
                            result.end = .failed
                            result.activity = errorMessage
                            foundActivity = true
                        } else if result.end == .failed {
                            result.activity = "Turn aborted (\(payload["reason"] as? String ?? "error"))"
                            foundActivity = true
                        }
                    }
                case "error":
                    if !foundTurnBoundary, errorMessage == nil {
                        errorMessage = (payload["message"] as? String)?.clipped(80) ?? "Error"
                    }
                case "item_completed":
                    if !foundActivity, let item = payload["item"] as? [String: Any], let text = describe(item: item) {
                        result.activity = text
                        foundActivity = true
                    }
                case "user_message":
                    if result.firstPrompt == nil { result.firstPrompt = payload["message"] as? String }
                default:
                    if ptype.contains("approval_request"), !foundTurnBoundary, !foundActivity {
                        result.state = .waiting
                        result.activity = "Waiting for your approval"
                        foundActivity = true
                    }
                }
            } else if kind == "response_item", !foundActivity {
                if ptype == "function_call" || ptype == "custom_tool_call", let name = payload["name"] as? String {
                    var input: [String: Any]?
                    if let args = payload["arguments"] as? String, let d = args.data(using: .utf8) {
                        input = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                    }
                    result.activity = ActivityText.tool(name, input: input)
                    foundActivity = true
                }
            }
        }

        if !foundTurnBoundary {
            // The whole tail is one long turn (or a brand new thread): trust freshness.
            if let previous, previous.state != .idle {
                result.state = previous.state
                result.workingSince = previous.workingSince
            } else if Date().timeIntervalSince(mtime) < 60 {
                result.state = .working
                result.workingSince = previous?.workingSince ?? mtime
            }
        }
        if result.state == .waiting, result.workingSince == nil { result.workingSince = previous?.workingSince }
        if result.firstPrompt == nil { result.firstPrompt = previous?.firstPrompt }
        return result
    }

    private func describe(item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "CommandExecution":
            if let cmd = item["command"] as? [String], let last = cmd.last { return "$ " + ActivityText.shortCommand(last) }
            return "Running a command"
        case "FileChange":
            if let changes = item["changes"] as? [String: Any], let first = changes.keys.first {
                return changes.count > 1 ? "Editing \(first.lastPathComponent) +\(changes.count - 1)" : "Editing \(first.lastPathComponent)"
            }
            return "Editing files"
        case "Reasoning": return "Thinking…"
        case "AgentMessage": return "Writing a reply…"
        case "WebSearch": return "Searching the web"
        case "McpToolCall":
            if let tool = item["tool"] as? String { return "Using \(tool)" }
            return "Using a tool"
        case "CollabAgentToolCall", "SubAgentActivity": return "Coordinating helpers"
        case "Plan", "PlanUpdate": return "Updating the plan"
        default: return nil
        }
    }
}
