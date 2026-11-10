import Foundation

/// One plan window, as a percent already used (0–100).
struct UsageWindow: Equatable {
    var percent: Double
    var resetsAt: Date?
    /// Short name of the window: "5h", "week".
    var label: String
}

/// The latest plan usage NotchBot could read for one harness.
/// Cursor has no local usage snapshot, so it never appears here.
struct PlanUsage: Identifiable, Equatable {
    let harness: Harness
    var windows: [UsageWindow]
    /// Extra bit that fits on the row, such as "Pro · $145".
    var note: String?
    /// When the harness itself recorded this snapshot.
    var asOf: Date

    var id: String { harness.rawValue }

    /// Windows that have not reset yet, hottest first.
    func live(now: Date) -> PlanUsage? {
        let open = windows.filter { $0.resetsAt.map { $0 > now } ?? true }
        guard !open.isEmpty else { return nil }
        var copy = self
        copy.windows = open.sorted { a, b in
            if a.percent != b.percent { return a.percent > b.percent }
            return (a.resetsAt ?? .distantFuture) < (b.resetsAt ?? .distantFuture)
        }
        return copy
    }
}

/// Reads plan usage the harnesses already write locally. Never calls their APIs.
///
/// - Claude Code caches the account snapshot in `~/.claude.json` (`cachedUsageUtilization`).
/// - Codex appends `rate_limits` on every `token_count` event in the rollout.
final class PlanUsageMonitor {
    private let claudeURL = FileUtil.home.appendingPathComponent(".claude.json")
    private let codexRoot = FileUtil.home.appendingPathComponent(".codex/sessions")

    private var claudeMtime: Date?
    private var claudeCache: PlanUsage?
    private var codexChecked: Date?
    private var codexSignature: Date?
    private var codexCache: PlanUsage?

    func poll(now: Date) -> [PlanUsage] {
        var plans: [PlanUsage] = []
        if let claude = claude(now: now)?.live(now: now) { plans.append(claude) }
        if let codex = codex(now: now)?.live(now: now) { plans.append(codex) }
        return plans
    }

    // MARK: - Claude

    private func claude(now: Date) -> PlanUsage? {
        guard let mtime = FileUtil.mtime(claudeURL) else { return nil }
        if mtime == claudeMtime { return claudeCache }
        claudeMtime = mtime
        guard let data = try? Data(contentsOf: claudeURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let util = cache["utilization"] as? [String: Any] else {
            return claudeCache
        }
        var windows: [UsageWindow] = []
        if let w = Self.window(util["five_hour"], label: "5h", percentKey: "utilization") { windows.append(w) }
        if let w = Self.window(util["seven_day"], label: "week", percentKey: "utilization") { windows.append(w) }
        guard !windows.isEmpty else {
            claudeCache = nil
            return nil
        }
        let asOf = Self.date(from: cache["fetchedAtMs"]) ?? mtime
        let plan = PlanUsage(harness: .claude, windows: windows, note: nil, asOf: asOf)
        claudeCache = plan
        return plan
    }

    // MARK: - Codex

    private func codex(now: Date) -> PlanUsage? {
        if let codexChecked, now.timeIntervalSince(codexChecked) < 8 { return codexCache }
        codexChecked = now

        let files = recentRollouts(now: now)
        let signature = files.first.flatMap { FileUtil.mtime($0) }
        if signature == codexSignature { return codexCache }
        codexSignature = signature

        for url in files.prefix(4) {
            guard let found = latestLimits(in: url) else { continue }
            codexCache = found
            return found
        }
        return codexCache
    }

    /// Today's rollout folder and the six before it. A weekly window can still be
    /// the latest news after a quiet day.
    private func recentRollouts(now: Date) -> [URL] {
        let cal = Calendar.current
        var files: [URL] = []
        for offset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let path = String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)
            let dir = codexRoot.appendingPathComponent(path)
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            files += items.filter { $0.pathExtension == "jsonl" }
        }
        return files.sorted { (FileUtil.mtime($0) ?? .distantPast) > (FileUtil.mtime($1) ?? .distantPast) }
    }

    /// The last `rate_limits` object in the tail of a rollout.
    private func latestLimits(in url: URL) -> PlanUsage? {
        let lines = FileUtil.tailLines(url, bytes: 256 * 1024)
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\""), line.contains("token_count"),
                  let obj = FileUtil.json(line),
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            var windows: [UsageWindow] = []
            if let w = Self.window(limits["primary"], label: "week", percentKey: "used_percent") { windows.append(w) }
            if let w = Self.window(limits["secondary"], label: "5h", percentKey: "used_percent") { windows.append(w) }
            guard !windows.isEmpty else { continue }

            let asOf = FileUtil.date(obj["timestamp"] as? String) ?? FileUtil.mtime(url) ?? Date()
            return PlanUsage(harness: .codex, windows: windows, note: Self.codexNote(limits), asOf: asOf)
        }
        return nil
    }

    // MARK: - Parsing

    /// A window object. Claude uses `utilization` and an ISO `resets_at`; Codex uses
    /// `used_percent`, `window_minutes` and a unix `resets_at`.
    private static func window(_ raw: Any?, label fallback: String, percentKey: String) -> UsageWindow? {
        guard let d = raw as? [String: Any], let percent = number(d[percentKey]) else { return nil }
        let label = (d["window_minutes"] as? NSNumber).map { Self.label(minutes: $0.intValue) } ?? fallback
        return UsageWindow(percent: min(max(percent, 0), 100), resetsAt: date(from: d["resets_at"]), label: label)
    }

    private static func label(minutes: Int) -> String {
        if minutes <= 360 { return "5h" }
        if minutes <= 1_500 { return "day" }
        return "week"
    }

    private static func codexNote(_ limits: [String: Any]) -> String? {
        var parts: [String] = []
        if let name = planName(limits["plan_type"] as? String) { parts.append(name) }
        if let credits = limits["credits"] as? [String: Any],
           credits["has_credits"] as? Bool == true,
           credits["unlimited"] as? Bool != true,
           let balance = credits["balance"] as? String,
           let money = money(balance) {
            parts.append(money)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func planName(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "prolite", "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business", "enterprise": return "Business"
        case "free": return "Free"
        case "pro_plus", "proplus": return "Pro+"
        case "max": return "Max"
        default: return nil
        }
    }

    private static func money(_ raw: String) -> String? {
        guard let n = Double(raw) else { return nil }
        if abs(n - n.rounded()) < 0.05 || n >= 100 { return "$\(Int(n.rounded()))" }
        return String(format: "$%.2f", n)
    }

    private static func number(_ raw: Any?) -> Double? {
        (raw as? NSNumber)?.doubleValue
    }

    /// Claude sends ISO-8601 (sometimes with more than three fraction digits) or epoch millis.
    /// Codex sends epoch seconds.
    private static func date(from raw: Any?) -> Date? {
        if let n = raw as? NSNumber {
            let v = n.doubleValue
            guard v > 0 else { return nil }
            return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        }
        guard let s = raw as? String else { return nil }
        if let d = FileUtil.date(s) { return d }
        guard let dot = s.firstIndex(of: "."),
              let endFrac = s[s.index(after: dot)...].firstIndex(where: { !$0.isNumber }) else { return nil }
        let frac = s[s.index(after: dot)..<endFrac]
        let ms = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return FileUtil.date(String(s[..<dot]) + "." + ms + String(s[endFrac...]))
    }
}
