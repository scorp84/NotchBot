import SwiftUI

/// The agent harnesses NotchBot knows how to watch.
enum Harness: String, CaseIterable, Identifiable {
    case claude, codex, cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Bundle id of the app that hosts this harness, used to focus it.
    var bundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.89, green: 0.50, blue: 0.36)  // warm terracotta
        case .codex: return Color(red: 0.40, green: 0.66, blue: 1.00)   // sky blue
        case .cursor: return Color(red: 0.74, green: 0.58, blue: 1.00)  // lavender
        }
    }
}

enum AgentState: Int, Comparable {
    case waiting = 0   // blocked on the user (permission, question)
    case failed = 1    // the last turn ended in an error, recently
    case working = 2
    case done = 3      // finished recently
    case idle = 4

    static func < (lhs: AgentState, rhs: AgentState) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .waiting: return "needs you"
        case .failed: return "failed"
        case .working: return "working"
        case .done: return "done"
        case .idle: return "idle"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return Color(red: 1.0, green: 0.74, blue: 0.25)
        case .failed: return Color(red: 1.0, green: 0.43, blue: 0.43)
        case .working: return Color.white
        case .done: return Color(red: 0.36, green: 0.88, blue: 0.55)
        case .idle: return Color.white.opacity(0.35)
        }
    }
}

/// How the most recent turn ended, when the harness says so.
enum TurnEnd: Equatable {
    case completed
    case interrupted  // stopped by the user: neither a success nor a failure
    case failed
}

/// One agent conversation / thread as seen by NotchBot.
struct AgentSession: Identifiable, Equatable {
    let id: String
    let harness: Harness
    var title: String
    var project: String
    var cwd: String?
    var state: AgentState
    var activity: String?
    var workingSince: Date?
    var lastActivity: Date
    var finishedAt: Date?
    var lastTurnDuration: TimeInterval?
    /// Sub-agents currently working on behalf of this session.
    var helpers: Int = 0
    /// Native process id, when the harness exposes one (used to find the host app).
    var pid: pid_t?
    /// Free-form hint about where the session runs ("claude-desktop", "Codex Desktop", "cli"...).
    var host: String?
    /// How the last turn ended. Only meaningful once the session is idle.
    var lastEnd: TurnEnd = .completed
    /// `waiting` inferred from silence rather than reported (Cursor approvals): shown, but no sound or banner.
    var guessedWait = false
}

/// Something worth popping the notch open for.
struct PeekEvent: Identifiable, Equatable {
    enum Kind { case finished, needsInput, failed }
    let id = UUID()
    let kind: Kind
    let session: AgentSession
}

/// A source of agent sessions. `poll` is always called on the same background queue.
protocol AgentMonitor: AnyObject {
    var harness: Harness { get }
    func poll(now: Date) -> [AgentSession]
}

extension String {
    var lastPathComponent: String { (self as NSString).lastPathComponent }

    func clipped(_ max: Int) -> String {
        let oneLine = self.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > max ? String(oneLine.prefix(max - 1)) + "…" : oneLine
    }
}

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }

    static func friendly(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func ago(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 10 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    /// How long until a plan window resets: "in 4h", "in 3d".
    static func resets(_ date: Date, now: Date) -> String {
        let s = Int(date.timeIntervalSince(now))
        if s <= 0 { return "now" }
        if s < 3600 { return "in \((s + 59) / 60)m" }
        if s < 36 * 3600 { return "in \((s + 3599) / 3600)h" }
        return "in \((s + 86399) / 86400)d"
    }
}
