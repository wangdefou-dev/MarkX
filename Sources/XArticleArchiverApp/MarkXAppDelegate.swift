import AppKit

final class MarkXAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MarkXWindowPolicy.enforceSingleMainWindow()
        MarkXWindowPolicy.closeRestoredProgressWindows()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MarkXWindowPolicy.enforceSingleMainWindow()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        MarkXWindowPolicy.enforceSingleMainWindow()
        return true
    }
}
