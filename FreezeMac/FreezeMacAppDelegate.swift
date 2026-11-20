import AppKit

@MainActor
final class FreezeMacAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindowHandler: (() -> Void)?

    /// The app's own window; overlay panels share the process but are never "the window".
    private var mainWindows: [NSWindow] {
        NSApplication.shared.windows.filter { !($0 is NSPanel) && $0.title == "Frosty" }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)

        let prefs = AppPreferences.load()
        if prefs.openMainWindowAtLaunch {
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.async {
                self.mainWindows.forEach { $0.close() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let openMainWindowHandler {
                openMainWindowHandler()
            } else {
                mainWindows.forEach { $0.makeKeyAndOrderFront(nil) }
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }
}
