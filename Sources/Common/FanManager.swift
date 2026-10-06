import Foundation
import Combine
import AppKit

@MainActor
public final class FanManager: ObservableObject {
    public static let shared = FanManager()

    // MARK: - Published State
    @Published public var fans: [FanData] = []
    @Published public var thermals: ThermalData = ThermalData()
    @Published public var activeMode: FanMode = .auto
    @Published public var activePreset: ProfilePreset = .balanced
    @Published public var customPoints: [CurvePoint] = ProfilePreset.balanced.defaultPoints
    @Published public var manualRPM: Double = 3500.0
    @Published public var linkFans: Bool = true
    @Published public var hysteresisBand: Double = 2.0
    @Published public var criticalThreshold: Double = 95.0
    @Published public var menuBarTempSource: MenuBarTempSource = .cpuPeak
    @Published public var menuBarLayoutStyle: MenuBarLayoutStyle = .stackedDual
    @Published public var isDirectRoot: Bool = false
    @Published public var isHelperConnected: Bool = false
    @Published public var isOverheating: Bool = false
    @Published public var statusMessage: String = "Ready"

    // Telemetry history for charts (last 30 data points)
    @Published public var tempHistory: [Double] = []
    @Published public var fanHistory: [Double] = []

    public var currentDisplayTemp: Double {
        switch menuBarTempSource {
        case .cpuAverage: return thermals.cpuAvg
        case .cpuPeak: return thermals.cpuPeak
        }
    }

    public var hasHardwareControl: Bool {
        return isDirectRoot || isHelperConnected
    }

    // MARK: - Internal
    private var timer: Timer?
    private let curveEngine = CurveEngine()
    private let helperClient = HelperClient.shared
    private var isSMCInitialized = false

    public init() {
        self.isDirectRoot = smc_is_root()
        loadSettings()
        setupHardware()
        setupSleepWakeHandlers()
        startPolling()
    }

    isolated deinit {
        stopPolling()
        if smc_is_root() {
            smc_set_all_auto()
        } else {
            _ = HelperClient.shared.setAuto()
        }
        smc_close()
        sensors_close()
    }

    // MARK: - Setup
    private func setupHardware() {
        _ = smc_open()
        _ = sensors_init()
        isSMCInitialized = true
        checkControlPermissions()
        pollHardware()
    }

    public func checkControlPermissions() {
        self.isDirectRoot = smc_is_root()
        if !self.isDirectRoot {
            self.isHelperConnected = helperClient.isConnected
        } else {
            self.isHelperConnected = true
        }
    }

    private func setupSleepWakeHandlers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.hasHardwareControl {
                    self.resetToAuto()
                }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.checkControlPermissions()
                self.pollHardware()
                self.applyFanControl()
            }
        }
    }

    // MARK: - Polling Loop
    public func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        // Periodically verify helper connectivity if not direct root
        if !isDirectRoot {
            self.isHelperConnected = helperClient.isConnected
        }
        pollHardware()
        applyFanControl()
    }

    // MARK: - Hardware Reading
    public func pollHardware() {
        let fanCount = Int(smc_get_fan_count())
        var currentFans: [FanData] = []

        for i in 0..<fanCount {
            let actual = Double(smc_get_fan_rpm(Int32(i)))
            let minRpm = Double(smc_get_fan_min_rpm(Int32(i)))
            let maxRpm = Double(smc_get_fan_max_rpm(Int32(i)))
            let target = Double(smc_get_fan_target_rpm(Int32(i)))
            let mode = Int(smc_get_fan_mode(Int32(i)))

            let name: String
            if fanCount == 2 {
                name = (i == 0) ? "Left Fan (CPU)" : "Right Fan (GPU)"
            } else {
                name = "Fan #\(i + 1)"
            }

            currentFans.append(FanData(
                index: i,
                name: name,
                currentRPM: actual,
                minRPM: minRpm > 0 ? minRpm : 1200,
                maxRPM: maxRpm > 0 ? maxRpm : 7000,
                targetRPM: target,
                modeRaw: mode
            ))
        }

        if !currentFans.isEmpty {
            self.fans = currentFans
        }

        let cpuAvg = Double(smc_get_cpu_core_avg())
        let cpuMax = Double(smc_get_cpu_core_peak())
        let battery = Double(sensors_get_battery_temp())
        let storage = Double(sensors_get_storage_temp())
        let thermalState = ProcessInfo.processInfo.thermalState

        self.thermals = ThermalData(
            cpuAvg: cpuAvg,
            cpuPeak: cpuMax,
            battery: battery,
            storage: storage,
            thermalPressure: thermalState
        )

        tempHistory.append(cpuAvg)
        if tempHistory.count > 30 { tempHistory.removeFirst() }

        let avgRpm = currentFans.isEmpty ? 0.0 : currentFans.map(\.currentRPM).reduce(0, +) / Double(currentFans.count)
        fanHistory.append(avgRpm)
        if fanHistory.count > 30 { fanHistory.removeFirst() }

        if cpuMax >= criticalThreshold {
            if !isOverheating {
                isOverheating = true
                statusMessage = "⚠️ CRITICAL TEMP: Overheat Failsafe Engaged"
            }
        } else {
            if isOverheating {
                isOverheating = false
                statusMessage = "Thermal state normalized"
            }
        }
    }

    // MARK: - Active Control Loop
    public func applyFanControl() {
        guard !fans.isEmpty else { return }

        // Emergency Overheat Safety Check
        if isOverheating {
            if hasHardwareControl {
                for fan in fans {
                    writeFanSpeed(index: fan.index, rpm: fan.maxRPM)
                }
            }
            return
        }

        switch activeMode {
        case .auto:
            statusMessage = "macOS Firmware Controlling Fans"
            if hasHardwareControl {
                writeAuto()
            }

        case .turbo:
            statusMessage = "100% Full Blast Max Cooling"
            if hasHardwareControl {
                for fan in fans {
                    writeFanSpeed(index: fan.index, rpm: fan.maxRPM)
                }
            }

        case .manual:
            statusMessage = "Manual Fixed Speed: \(Int(manualRPM)) RPM"
            if hasHardwareControl {
                for fan in fans {
                    let clamped = max(fan.minRPM, min(fan.maxRPM, manualRPM))
                    writeFanSpeed(index: fan.index, rpm: clamped)
                }
            }

        case .curve:
            curveEngine.hysteresisBand = hysteresisBand
            curveEngine.criticalThreshold = criticalThreshold

            let points = activePoints
            let currentTemp = thermals.cpuAvg
            let targetPercent = curveEngine.evaluate(temp: currentTemp, points: points, useHysteresis: true)

            for fan in fans {
                let targetRPM = curveEngine.percentToRPM(percent: targetPercent, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                if hasHardwareControl {
                    writeFanSpeed(index: fan.index, rpm: targetRPM)
                }
            }

            statusMessage = hasHardwareControl ?
                "Curve Active: \(Int(targetPercent))% Target" :
                "Curve Simulation (Install Helper for Control)"
        }
    }

    private func writeFanSpeed(index: Int, rpm: Double) {
        if isDirectRoot {
            _ = smc_set_fan_target(Int32(index), Float(rpm))
        } else if isHelperConnected {
            _ = helperClient.setFan(index: index, rpm: rpm)
        }
    }

    private func writeAuto() {
        if isDirectRoot {
            _ = smc_set_all_auto()
        } else if isHelperConnected {
            _ = helperClient.setAuto()
        }
    }

    // MARK: - Active Curve Points
    public var activePoints: [CurvePoint] {
        if activePreset == .custom {
            return customPoints
        }
        return activePreset.defaultPoints
    }

    public var currentCommandedPercentage: Double {
        if activeMode == .turbo { return 100.0 }
        if activeMode == .auto {
            let avg = fans.isEmpty ? 0.0 : fans.map(\.percentage).reduce(0, +) / Double(fans.count)
            return avg
        }
        if activeMode == .manual {
            guard let first = fans.first, first.maxRPM > first.minRPM else { return 50.0 }
            return ((manualRPM - first.minRPM) / (first.maxRPM - first.minRPM)) * 100.0
        }
        return curveEngine.evaluate(temp: thermals.cpuAvg, points: activePoints, useHysteresis: false)
    }

    // MARK: - Presets & Modes
    public func selectPreset(_ preset: ProfilePreset) {
        self.activePreset = preset
        if preset != .custom {
            self.customPoints = preset.defaultPoints
        }
        saveSettings()
        applyFanControl()
    }

    public func setMode(_ mode: FanMode) {
        self.activeMode = mode
        saveSettings()
        applyFanControl()
    }

    public func setEmergencyTurbo() {
        setMode(.turbo)
    }

    public func resetToAuto() {
        setMode(.auto)
    }

    // MARK: - One-Click Privileged Helper Installer
    public func installPrivilegedHelper() {
        let scriptPath = Bundle.main.bundlePath + "/Contents/Resources/install-helper.sh"
        let fallbackPath = "/Users/mohamedram/Fan-Control/Scripts/install-helper.sh"
        let targetScript = FileManager.default.fileExists(atPath: scriptPath) ? scriptPath : fallbackPath

        let appleScriptSource = "do shell script \"bash '\(targetScript)'\" with administrator privileges"
        var error: NSDictionary?
        if let script = NSAppleScript(source: appleScriptSource) {
            script.executeAndReturnError(&error)
            if let err = error {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Authorization failed"
                self.statusMessage = "Helper Install: \(msg)"
                print("Helper installation failed: \(msg)")
            } else {
                // Wait briefly for daemon to initialize
                for _ in 0..<10 {
                    usleep(200000)
                    if HelperClient.shared.ping() {
                        break
                    }
                }
                checkControlPermissions()
                self.statusMessage = isHelperConnected ? "Helper Connected & Active" : "Helper loaded"
                applyFanControl()
            }
        }
    }

    // MARK: - Persistence
    private func saveSettings() {
        UserDefaults.standard.set(activeMode.rawValue, forKey: "ActiveMode")
        UserDefaults.standard.set(activePreset.rawValue, forKey: "ActivePreset")
        UserDefaults.standard.set(manualRPM, forKey: "ManualRPM")
        UserDefaults.standard.set(linkFans, forKey: "LinkFans")
        UserDefaults.standard.set(hysteresisBand, forKey: "HysteresisBand")
        UserDefaults.standard.set(criticalThreshold, forKey: "CriticalThreshold")
        UserDefaults.standard.set(menuBarTempSource.rawValue, forKey: "MenuBarTempSource")
        UserDefaults.standard.set(menuBarLayoutStyle.rawValue, forKey: "MenuBarLayoutStyle")

        if let encoded = try? JSONEncoder().encode(customPoints) {
            UserDefaults.standard.set(encoded, forKey: "CustomPoints")
        }
    }

    private func loadSettings() {
        if let modeStr = UserDefaults.standard.string(forKey: "ActiveMode"),
           let mode = FanMode(rawValue: modeStr) {
            self.activeMode = mode
        }

        if let presetStr = UserDefaults.standard.string(forKey: "ActivePreset"),
           let preset = ProfilePreset(rawValue: presetStr) {
            self.activePreset = preset
        }

        if let sourceStr = UserDefaults.standard.string(forKey: "MenuBarTempSource"),
           let source = MenuBarTempSource(rawValue: sourceStr) {
            self.menuBarTempSource = source
        }

        if let layoutStr = UserDefaults.standard.string(forKey: "MenuBarLayoutStyle"),
           let layout = MenuBarLayoutStyle(rawValue: layoutStr) {
            self.menuBarLayoutStyle = layout
        }

        let savedRPM = UserDefaults.standard.double(forKey: "ManualRPM")
        if savedRPM > 1000 { self.manualRPM = savedRPM }

        if let data = UserDefaults.standard.data(forKey: "CustomPoints"),
           let decoded = try? JSONDecoder().decode([CurvePoint].self, from: data) {
            self.customPoints = decoded
        } else {
            self.customPoints = ProfilePreset.balanced.defaultPoints
        }

        let savedHyst = UserDefaults.standard.double(forKey: "HysteresisBand")
        if savedHyst > 0.5 { self.hysteresisBand = savedHyst }

        let savedCrit = UserDefaults.standard.double(forKey: "CriticalThreshold")
        if savedCrit > 70.0 { self.criticalThreshold = savedCrit }
    }
}
