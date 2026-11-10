import AppKit

/// Brings the app that hosts a session to the front.
enum AppLauncher {
    static func focus(_ s: AgentSession) {
        switch s.harness {
        case .claude:
            // CLI sessions: walk up the process tree to the terminal / editor that owns it.
            if let pid = s.pid, let app = owningApp(of: pid) {
                app.activate()
            } else {
                openApp(s.harness.bundleID)
            }
        case .codex:
            if s.host?.localizedCaseInsensitiveContains("desktop") == true || s.host == nil {
                openApp(s.harness.bundleID)
            }
        case .cursor:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.harness.bundleID) else { return }
            let config = NSWorkspace.OpenConfiguration()
            if let cwd = s.cwd {
                // Opening the folder focuses the window that already has it open.
                NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL, configuration: config)
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            }
        }
    }

    private static func openApp(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// First ancestor process that is a regular GUI app (Terminal, iTerm, VS Code, Claude…).
    static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
