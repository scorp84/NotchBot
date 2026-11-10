import SwiftUI

/// Entry point.
/// NotchBot: agent activity at a glance, right in the notch.
@main
struct NotchBotApp: App {
    @NSApplicationDelegateAdaptor(NotchAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
