import SwiftUI
import ServiceManagement

/// App delegate that wires the agent store to the notch window and menu bar icon.
class NotchAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var notchWindow: NotchWindow?
    var statusItem: NSStatusItem?
    let store = AgentStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--dump") { dumpAndExit() }

        setupMenuBar()
        notchWindow = NotchWindow(store: store)
        notchWindow?.onOpenSettings = { [weak self] point in
            self?.popSettingsMenu(at: point)
        }
        store.start()

        // Preview helpers: `open NotchBot.app --args --show` / `--peek`
        let args = CommandLine.arguments
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            if args.contains("--show") { self.notchWindow?.expand() }
            if args.contains("--peek"), let s = self.store.sessions.first {
                var done = s
                done.lastTurnDuration = 252
                self.notchWindow?.peek(PeekEvent(kind: .finished, session: done))
            }
        }
    }

    /// `NotchBot --dump` prints what the monitors see, for debugging detection.
    private func dumpAndExit() {
        HookInstaller.prepare()
        let monitors: [AgentMonitor] = [ClaudeMonitor(), CodexMonitor(), CursorMonitor()]
        let now = Date()
        for s in monitors.flatMap({ $0.poll(now: now) }).sorted(by: { $0.lastActivity > $1.lastActivity }) {
            let since = s.workingSince.map { Fmt.duration(now.timeIntervalSince($0)) } ?? "-"
            print("[\(s.harness.displayName)] \(s.state.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(since.padding(toLength: 7, withPad: " ", startingAt: 0)) \(s.project) — \(s.title.clipped(50)) | \(s.activity ?? "") \(s.helpers > 0 ? "(+\(s.helpers) helpers)" : "")")
        }
        print("cursor hooks installed: \(HookInstaller.isCursorInstalled) (all events: \(HookInstaller.cursorHasAllEvents))")
        print("claude hook installed: \(HookInstaller.isClaudeInstalled)")
        for plan in PlanUsageMonitor().poll(now: now) {
            let windows = plan.windows.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: ", ")
            let note = plan.note.map { " (\($0))" } ?? ""
            print("plan \(plan.harness.displayName): \(windows)\(note)")
        }
        exit(0)
    }

    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "NotchBot")
        button.image?.size = NSSize(width: 14, height: 14)
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    /// Rebuilt every time it opens so toggles and session counts are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let summary: String
        if !store.waiting.isEmpty { summary = "\(store.waiting.count) waiting on you" }
        else if !store.failed.isEmpty { summary = "\(store.failed.count) failed" }
        else if !store.working.isEmpty { summary = "\(store.working.count) working" }
        else { summary = "All quiet" }
        menu.addItem(NSMenuItem(title: "NotchBot — \(summary)", action: nil, keyEquivalent: ""))
        if store.completedToday > 0 {
            menu.addItem(NSMenuItem(title: "✓ \(store.completedToday) finished today", action: nil, keyEquivalent: ""))
        }
        for plan in store.plans {
            let windows = plan.windows.map { "\($0.label) \(Int($0.percent.rounded()))%" }.joined(separator: " · ")
            let note = plan.note.map { " · \($0)" } ?? ""
            menu.addItem(NSMenuItem(title: "\(plan.harness.displayName)  \(windows)\(note)", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())

        menu.addItem(item("Show Agents", #selector(toggleTray), key: "a"))
        menu.addItem(.separator())

        if store.cursorConnected {
            menu.addItem(item("Disconnect Cursor Hooks", #selector(disconnectCursor)))
        } else {
            menu.addItem(item("Connect Cursor…", #selector(connectCursor)))
        }
        if store.claudeConnected {
            menu.addItem(item("Disconnect Claude Approvals", #selector(disconnectClaude)))
        } else {
            menu.addItem(item("Show Claude Approvals…", #selector(connectClaude)))
        }
        menu.addItem(.separator())

        menu.addItem(item("Sounds", #selector(toggleSounds), state: store.soundsOn))
        menu.addItem(item("Pop Open When Agents Finish", #selector(togglePeek), state: store.peekOnFinish))
        menu.addItem(item("Launch at Login", #selector(toggleLogin), state: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quit NotchBot", #selector(quitApp), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", state: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let state { i.state = state ? .on : .off }
        return i
    }

    /// Same menu as the status item, anchored at the pointer. The notch panel
    /// sits above the menu bar and can cover its own icon, so the tray gear
    /// and a right-click on the notch open it from here instead.
    private func popSettingsMenu(at screenPoint: NSPoint) {
        let menu = NSMenu()
        menu.delegate = self
        notchWindow?.popUp(menu, at: screenPoint)
    }

    @objc func toggleTray() { notchWindow?.toggle() }
    @objc func toggleSounds() { store.soundsOn.toggle() }
    @objc func togglePeek() { store.peekOnFinish.toggle() }
    @objc func disconnectCursor() { store.disconnectCursor() }

    @objc func connectCursor() { store.connectCursor() }
    @objc func connectClaude() { store.connectClaude() }
    @objc func disconnectClaude() { store.disconnectClaude() }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Clean Quit

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        notchWindow?.destroy()
        notchWindow = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
}
