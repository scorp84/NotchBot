import AppKit
import Combine

/// Polls every monitor once a second, merges the results and turns state
/// changes into notch events (finished → celebrate, failed → warn, waiting → nudge).
final class AgentStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var completedToday = 0
    @Published private(set) var workedToday: TimeInterval = 0
    @Published private(set) var cursorConnected = HookInstaller.isCursorInstalled
    @Published private(set) var claudeConnected = HookInstaller.isClaudeInstalled
    /// Plan windows read from the harnesses' own local files (Claude, Codex).
    @Published private(set) var plans: [PlanUsage] = []
    @Published private(set) var now = Date()

    @Published var soundsOn: Bool { didSet { defaults.set(soundsOn, forKey: "soundsOn") } }
    @Published var peekOnFinish: Bool { didSet { defaults.set(peekOnFinish, forKey: "peekOnFinish") } }

    /// Fired on the main thread for things worth popping the notch open for.
    var onPeek: ((PeekEvent) -> Void)?

    private let monitors: [AgentMonitor] = [ClaudeMonitor(), CodexMonitor(), CursorMonitor()]
    private let usage = PlanUsageMonitor()
    private let queue = DispatchQueue(label: "notchbot.poll", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var previous: [String: AgentState] = [:]
    private var workingSince: [String: Date] = [:]
    private var finished: [String: (at: Date, took: TimeInterval?, failed: Bool)] = [:]
    private var primed = false
    private let defaults = UserDefaults.standard

    /// How long an idle session stays listed after its last activity.
    private let idleListWindow: TimeInterval = 30 * 60
    /// How long a finished session shows the "done" (or "failed") state.
    private let doneWindow: TimeInterval = 10 * 60

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["soundsOn": true, "peekOnFinish": true])
        _soundsOn = Published(initialValue: d.bool(forKey: "soundsOn"))
        _peekOnFinish = Published(initialValue: d.bool(forKey: "peekOnFinish"))
        loadStats()
    }

    func start() {
        HookInstaller.prepare()
        // Older installs miss the events behind the approval guess; same consent, so top them up.
        if HookInstaller.isCursorInstalled, !HookInstaller.cursorHasAllEvents { try? HookInstaller.installCursor() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            let raw = self.monitors.flatMap { $0.poll(now: now) }
            let plans = self.usage.poll(now: now)
            DispatchQueue.main.async {
                if plans != self.plans { self.plans = plans }
                self.apply(raw, now: now)
            }
        }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel() }

    // MARK: - Derived

    var working: [AgentSession] { sessions.filter { $0.state == .working } }
    var waiting: [AgentSession] { sessions.filter { $0.state == .waiting } }
    var failed: [AgentSession] { sessions.filter { $0.state == .failed } }
    var isBusy: Bool { sessions.contains { $0.state == .working || $0.state == .waiting } }

    /// Most recent completion or failure if it happened in the last few seconds (drives the wing's ✓ / !).
    var justFinished: AgentSession? {
        sessions.filter { ($0.state == .done || $0.state == .failed) && now.timeIntervalSince($0.finishedAt ?? .distantPast) < 6 }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    func harnessesInPlay() -> [Harness] {
        Harness.allCases.filter { h in sessions.contains { $0.harness == h } }
    }

    /// The plan window closest to full, for the collapsed wing.
    var hotPlan: (harness: Harness, percent: Double, label: String)? {
        plans.compactMap { plan -> (Harness, Double, String)? in
            guard let window = plan.windows.first else { return nil }
            return (plan.harness, window.percent, window.label)
        }.max { $0.1 < $1.1 }
    }

    // MARK: - Merge

    private func apply(_ raw: [AgentSession], now: Date) {
        self.now = now
        rollStatsIfNewDay()
        var next: [String: AgentState] = [:]
        var list: [AgentSession] = []

        for var s in raw {
            let prev = previous[s.id]
            next[s.id] = s.state

            if s.state == .working || s.state == .waiting {
                // Keep the earliest start so multi-step turns don't reset the timer.
                let start = min(workingSince[s.id] ?? .distantFuture, s.workingSince ?? now)
                workingSince[s.id] = start
                s.workingSince = start
                finished[s.id] = nil
            }

            if primed, let prev, prev == .working || prev == .waiting, s.state == .idle {
                let took = workingSince[s.id].map { now.timeIntervalSince($0) }
                workingSince[s.id] = nil
                var event = s
                event.finishedAt = now
                event.lastTurnDuration = took
                switch s.lastEnd {
                case .completed:
                    finished[s.id] = (now, took, false)
                    recordCompletion(took)
                    event.state = .done
                    if soundsOn { NSSound(named: "Glass")?.play() }
                    if peekOnFinish { onPeek?(PeekEvent(kind: .finished, session: event)) }
                case .failed:
                    finished[s.id] = (now, took, true)
                    event.state = .failed
                    if soundsOn { NSSound(named: "Basso")?.play() }
                    onPeek?(PeekEvent(kind: .failed, session: event))
                case .interrupted:
                    break  // the user stopped it: back to idle, quietly
                }
            }

            if primed, prev != .waiting, s.state == .waiting, !s.guessedWait {
                if soundsOn { NSSound(named: "Tink")?.play() }
                onPeek?(PeekEvent(kind: .needsInput, session: s))
            }

            if s.state == .idle, let f = finished[s.id], now.timeIntervalSince(f.at) < doneWindow {
                s.state = f.failed ? .failed : .done
                s.finishedAt = f.at
                s.lastTurnDuration = f.took
            }

            let visible = s.state != .idle || now.timeIntervalSince(s.lastActivity) < idleListWindow
            if visible { list.append(s) }
        }

        // Sessions that vanished (process quit) while working count as finished silently.
        for id in previous.keys where next[id] == nil { workingSince[id] = nil }

        // Stable order: by state, then working ones by when they started (rows shouldn't jump around).
        list.sort {
            if $0.state != $1.state { return $0.state < $1.state }
            switch $0.state {
            case .working, .waiting:
                return ($0.workingSince ?? now, $0.id) < ($1.workingSince ?? now, $1.id)
            case .done, .failed:
                return ($0.finishedAt ?? now) > ($1.finishedAt ?? now)
            case .idle:
                return $0.lastActivity > $1.lastActivity
            }
        }
        previous = next
        primed = true
        if list != sessions { sessions = list }
        let connected = HookInstaller.isCursorInstalled
        if connected != cursorConnected { cursorConnected = connected }
        let claude = HookInstaller.isClaudeInstalled
        if claude != claudeConnected { claudeConnected = claude }
    }

    // MARK: - Cursor hooks

    /// Asks first: this edits the user's ~/.cursor/hooks.json.
    func connectCursor() {
        let alert = NSAlert()
        alert.messageText = "Connect Cursor?"
        alert.informativeText = "NotchBot will add a small hook bridge to ~/.cursor/hooks.json so Cursor can report agent activity. Your existing hooks are kept and a backup is saved as hooks.json.notchbot-backup. Restart Cursor afterwards."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookInstaller.installCursor()
            cursorConnected = true
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func disconnectCursor() {
        try? HookInstaller.uninstallCursor()
        cursorConnected = HookInstaller.isCursorInstalled
    }

    // MARK: - Claude hooks

    /// Asks first: this edits the user's ~/.claude/settings.json.
    func connectClaude() {
        let alert = NSAlert()
        alert.messageText = "Show Claude approvals?"
        alert.informativeText = "Claude Code doesn't write permission prompts anywhere NotchBot can see. NotchBot will add one Notification hook to ~/.claude/settings.json that reports them. Everything else in that file is kept and a backup is saved as settings.json.notchbot-backup. New Claude sessions pick it up."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookInstaller.installClaude()
            claudeConnected = true
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func disconnectClaude() {
        try? HookInstaller.uninstallClaude()
        claudeConnected = HookInstaller.isClaudeInstalled
    }

    // MARK: - Daily stats

    private var statsDay = ""
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func loadStats() {
        statsDay = Self.dayFormat.string(from: Date())
        completedToday = defaults.integer(forKey: "stats.\(statsDay).count")
        workedToday = defaults.double(forKey: "stats.\(statsDay).seconds")
    }

    private func rollStatsIfNewDay() {
        if Self.dayFormat.string(from: now) != statsDay { loadStats() }
    }

    private func recordCompletion(_ took: TimeInterval?) {
        completedToday += 1
        workedToday += took ?? 0
        defaults.set(completedToday, forKey: "stats.\(statsDay).count")
        defaults.set(workedToday, forKey: "stats.\(statsDay).seconds")
    }
}
