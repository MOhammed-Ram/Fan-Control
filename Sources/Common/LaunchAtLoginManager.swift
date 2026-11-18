import Foundation
import ServiceManagement
import AppKit

public final class LaunchAtLoginManager: @unchecked Sendable {
    public static let shared = LaunchAtLoginManager()
    private let agentPlistLabel = "com.macfancontrol.curveapp"

    private var launchAgentPlistURL: URL {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let agentsDir = libraryDir.appendingPathComponent("LaunchAgents")
        return agentsDir.appendingPathComponent("\(agentPlistLabel).plist")
    }

    public var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: launchAgentPlistURL.path) ||
            UserDefaults.standard.bool(forKey: "StartAtLogin")
    }

    /// Cleans up duplicate SMAppService + LaunchAgent registrations from older versions
    /// and ensures existing LaunchAgent plists use single-instance `/usr/bin/open`.
    public func cleanupDuplicateRegistrations() {
        var wasSMAppEnabled = false
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                wasSMAppEnabled = true
                try? SMAppService.mainApp.unregister()
            }
        }

        let hasPlist = FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
        if wasSMAppEnabled || hasPlist || UserDefaults.standard.bool(forKey: "StartAtLogin") {
            UserDefaults.standard.set(true, forKey: "StartAtLogin")
            manageLaunchAgent(enabled: true)
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: "StartAtLogin")

        // Ensure SMAppService is unregistered so LaunchAgent is the single launch mechanism
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
        }

        // Manage user LaunchAgent plist for reliable single-instance background launch
        manageLaunchAgent(enabled: enabled)
        return true
    }

    private func manageLaunchAgent(enabled: Bool) {
        let fileManager = FileManager.default
        let plistURL = launchAgentPlistURL
        let agentsDir = plistURL.deletingLastPathComponent()

        if enabled {
            let appBundlePath: String
            if Bundle.main.bundlePath.hasPrefix("/Applications/") {
                appBundlePath = Bundle.main.bundlePath
            } else if fileManager.fileExists(atPath: "/Applications/FanControl.app") {
                appBundlePath = "/Applications/FanControl.app"
            } else {
                appBundlePath = Bundle.main.bundlePath
            }

            let plistDict: [String: Any] = [
                "Label": agentPlistLabel,
                "ProgramArguments": ["/usr/bin/open", "-a", appBundlePath, "--args", "--background"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]

            do {
                try fileManager.createDirectory(at: agentsDir, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
                try data.write(to: plistURL)
            } catch {
                print("Failed to write LaunchAgent plist: \(error)")
            }
        } else {
            try? fileManager.removeItem(at: plistURL)
        }
    }
}
