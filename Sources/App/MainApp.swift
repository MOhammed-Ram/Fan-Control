import AppKit
import SwiftUI
import UserNotifications
import Darwin

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow?
    var aboutWindow: NSWindow?
    var menuBarController: MenuBarController?
    let fanManager = FanManager.shared
    let uiState = UIState()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent macOS "Reopen windows when logging back in" (TAL) from launching a duplicate instance alongside LaunchAgent
        NSApp.disableRelaunchOnLogin()

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        let isBackgroundLaunch = CommandLine.arguments.contains("--background") ||
            CommandLine.arguments.contains("-background") ||
            fanManager.startMinimized

        // Setup Window with Fixed Dimensions (Showing all elements without scrolling or clipping)
        let fixedSize = NSSize(width: 860, height: 860)
        let contentView = ContentView(manager: fanManager, uiState: uiState)
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: fixedSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Mac Fan Speed Curve Controller"
        window.titleVisibility = .visible
        window.contentViewController = hostingController
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        self.window = window

        // Setup Upper OS Status Bar Item with Interactive Controls
        menuBarController = MenuBarController(manager: fanManager)
        menuBarController?.onOpenWindow = { [weak self] in
            guard let self = self, let win = self.window else { return }
            if !self.fanManager.runAsMenuBarOnly {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            win.setContentSize(fixedSize)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
        menuBarController?.onOpenSettings = { [weak self] in
            self?.showSettingsWindow()
        }
        menuBarController?.onOpenAbout = { [weak self] in
            self?.showAboutWindow()
        }

        // Configure Background / Menu Bar Agent Mode
        if fanManager.runAsMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }

        if !isBackgroundLaunch {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }

        setupMainMenu()
    }

    @objc func showSettingsWindow() {
        aboutWindow?.close()
        guard let win = window else { return }
        let wasVisible = win.isVisible
        if !fanManager.runAsMenuBarOnly {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.setContentSize(NSSize(width: 860, height: 860))
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        uiState.showingAbout = false
        if wasVisible {
            uiState.showingSettings = true
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.uiState.showingSettings = true
            }
        }
    }

    @objc func showAboutWindow() {
        if let mainWin = window, mainWin.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            mainWin.makeKeyAndOrderFront(nil)
            uiState.showingSettings = false
            uiState.showingAbout = true
            return
        }

        if aboutWindow == nil {
            let aboutSize = NSSize(width: 380, height: 390)
            let aboutView = AboutSheetView(manager: fanManager) { [weak self] in
                self?.aboutWindow?.close()
            }
            let hosting = NSHostingController(rootView: aboutView)
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: aboutSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.center()
            win.title = "About Fan Control"
            win.contentViewController = hosting
            win.isReleasedWhenClosed = false
            win.isRestorable = false
            self.aboutWindow = win
        }

        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        aboutWindow?.orderFrontRegardless()
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutMenuItem = NSMenuItem(title: "About Fan Control", action: #selector(showAboutWindow), keyEquivalent: "")
        aboutMenuItem.target = self
        appMenu.addItem(aboutMenuItem)
        appMenu.addItem(NSMenuItem.separator())
        let prefsMenuItem = NSMenuItem(title: "Preferences...", action: #selector(showSettingsWindow), keyEquivalent: ",")
        prefsMenuItem.target = self
        appMenu.addItem(prefsMenuItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Fan Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Fan Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(closeItem)
        let miniItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(miniItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func windowWillClose(_ notification: Notification) {
        if fanManager.runAsMenuBarOnly {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !fanManager.runAsMenuBarOnly {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.setContentSize(NSSize(width: 860, height: 860))
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        fanManager.stopPolling()
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
    private static var instanceLockFd: Int32 = -1

    static func main() {
        let isBackground = CommandLine.arguments.contains("--background") ||
            CommandLine.arguments.contains("-background")

        let lockPath = "/tmp/com.macfancontrol.curveapp.\(getuid()).lock"
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        var lockAcquired = false
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockAcquired = true
                instanceLockFd = fd
            } else {
                Darwin.close(fd)
            }
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.macfancontrol.curveapp")
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }

        if !lockAcquired {
            // Another v1.3.0+ instance already holds the atomic kernel lock; exit this duplicate instance
            if !isBackground, let otherApp = otherApps.first {
                otherApp.activate()
            }
            exit(0)
        }

        // We hold the exclusive lock; terminate any legacy (pre-v1.3.0) unlocked instances so only one remains
        for legacyApp in otherApps {
            legacyApp.terminate()
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
