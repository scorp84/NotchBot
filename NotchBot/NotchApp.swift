import SwiftUI

/// Entry point.
/// NotchBot: agent activity at a glance, right in the notch.
@main
struct NotchBotApp: App {
    @NSApplicationDelegateAdaptor(NotchAppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI requires a scene. This one never appears in the menu bar.
        // The notch panel and status item are AppKit; their menu is the settings UI.
        MenuBarExtra("NotchBot", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }
    }
}
