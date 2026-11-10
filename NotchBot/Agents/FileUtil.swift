import Foundation

enum FileUtil {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Complete JSON lines from the last `bytes` of a file, oldest first.
    /// The first (possibly truncated) line is dropped when we didn't start at offset 0.
    static func tailLines(_ url: URL, bytes: UInt64) -> [Substring] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        let start = end > bytes ? end - bytes : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Reads the first line of a file (stopping after `limit` bytes).
    static func firstLine(_ url: URL, limit: Int = 2_000_000) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var buffer = Data()
        while buffer.count < limit {
            guard let chunk = try? h.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            if let nl = chunk.firstIndex(of: 0x0A) {
                buffer.append(chunk[chunk.startIndex..<nl])
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
        }
        return String(data: buffer, encoding: .utf8)
    }

    static func json(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

/// Turns raw tool calls into short, human "what is it doing" lines.
enum ActivityText {
    /// `cd /long/path && swift test` → `swift test`; home directory → `~`.
    static func shortCommand(_ raw: String) -> String {
        var c = raw.components(separatedBy: "\n").first ?? raw
        if c.hasPrefix("cd ") {
            let seps = [" && ", "; "].compactMap { c.range(of: $0) }.sorted { $0.lowerBound < $1.lowerBound }
            if let r = seps.first { c = String(c[r.upperBound...]) }
        }
        c = c.replacingOccurrences(of: FileUtil.home.path, with: "~")
        return c.clipped(70)
    }

    static func tool(_ rawName: String, input: [String: Any]?) -> String {
        let name = rawName
        let i = input ?? [:]
        func str(_ k: String) -> String? { i[k] as? String }
        func file(_ k: String) -> String? { str(k).map { $0.lastPathComponent } }

        switch name.lowercased() {
        case "bash", "shell", "exec_command", "run_terminal_cmd", "terminal":
            if let c = str("command") ?? str("cmd") { return "$ " + shortCommand(c) }
            return "Running a command"
        case "edit", "multiedit", "str_replace", "edit_file", "search_replace", "apply_patch":
            if let f = file("file_path") ?? file("path") ?? file("target_file") { return "Editing \(f)" }
            return "Patching files"
        case "write", "write_file", "create_file":
            if let f = file("file_path") ?? file("path") { return "Writing \(f)" }
            return "Writing a file"
        case "read", "read_file", "view":
            if let f = file("file_path") ?? file("path") ?? file("target_file") { return "Reading \(f)" }
            return "Reading files"
        case "grep", "glob", "codebase_search", "file_search", "grep_search", "list_dir", "ls":
            if let p = str("pattern") ?? str("query") { return "Searching “\(p.clipped(40))”" }
            return "Searching the codebase"
        case "webfetch", "web_fetch", "websearch", "web_search":
            if let q = str("query") ?? str("url") { return "Browsing \(q.clipped(50))" }
            return "Browsing the web"
        case "agent", "task", "spawn_agent":
            if let d = str("description") { return "Delegating: \(d.clipped(50))" }
            return "Spinning up a helper"
        case "wait_agent":
            return "Waiting on helpers"
        case "todowrite", "update_plan", "mcp__ccd_turn__update_plan":
            return "Updating the plan"
        default:
            if name.hasPrefix("mcp__") {
                let tool = name.components(separatedBy: "__").last ?? name
                return "Using \(tool.replacingOccurrences(of: "_", with: " "))"
            }
            return "Using \(name)"
        }
    }
}
