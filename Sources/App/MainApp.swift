import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var menuBarController: MenuBarController?
    let fanManager = FanManager.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup Window
        let contentView = ContentView(manager: fanManager)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mac Fan Speed Curve Controller"
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 780, height: 700)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.window = window

        // Setup Upper OS Status Bar Item with Interactive Controls
        menuBarController = MenuBarController(manager: fanManager)
        menuBarController?.onOpenWindow = { [weak self] in
            guard let self = self, let win = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if smc_is_root() {
            smc_set_all_auto()
        } else {
            _ = HelperClient.shared.setAuto()
        }
        smc_close()
        sensors_close()
    }
}

@main
@MainActor
struct Launcher {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
