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
    @Published public var criticalThreshold: Double = 100.0
    @Published public var curveTempSource: CurveTempSource = .cpuAverage
    @Published public var menuBarTempSource: MenuBarTempSource = .cpuAverage
    @Published public var menuBarLayoutStyle: MenuBarLayoutStyle = .stackedDual
    @Published public var rampUpRate: Double = 120.0 // Max RPM acceleration per second
    @Published public var rampDownRate: Double = 60.0 // Max RPM deceleration per second
    @Published public var tempSmoothingAlpha: Double = 0.25 // EMA alpha (0.1..0.8)
    @Published public var currentCommandedPercentage: Double = 0.0
    private var commandedRPMs: [Int: Double] = [:]
    private var lastTickTime: Date? = nil
    private var didRestoreAutoHardware: Bool = false

    // Telemetry Filtering & Deadband State
    private var smoothedFanRPM: [Int: Double] = [:]
    private var lastDisplayRPM: [Int: Int] = [:]
    private var smoothedCpuAvg: Double? = nil
    private var smoothedCpuPeak: Double? = nil
    private var lastDisplayIntTemp: Int? = nil
    private var overheatTriggerTicks: Int = 0
    private var overheatClearTicks: Int = 0

    @Published public var isDirectRoot: Bool = false
    @Published public var isHelperConnected: Bool = false
    @Published public var isOverheating: Bool = false
    @Published public var statusMessage: String = "Ready"

    // Telemetry history for charts (last 30 data points)
    @Published public var tempHistory: [Double] = []
    @Published public var fanHistory: [Double] = []

    public var curveDrivingTemp: Double {
        switch curveTempSource {
        case .cpuAverage: return thermals.cpuAvg
        case .cpuPeak: return thermals.cpuPeak
        }
    }

    public var currentDisplayTemp: Double {
        switch menuBarTempSource {
        case .cpuAverage: return thermals.cpuAvg
        case .cpuPeak: return thermals.cpuPeak
        }
    }

    public var currentDisplayIntTemp: Int {
        let t = currentDisplayTemp
        if let last = lastDisplayIntTemp {
            // 0.6°C deadband around integer transition to prevent flip-flopping
            if abs(t - Double(last)) >= 0.6 {
                let next = Int(t.rounded())
                lastDisplayIntTemp = next
                return next
            } else {
                return last
            }
        } else {
            let initial = Int(t.rounded())
            lastDisplayIntTemp = initial
            return initial
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
            let rawActual = Double(smc_get_fan_rpm(Int32(i)))
            let minRpm = Double(smc_get_fan_min_rpm(Int32(i)))
            let maxRpm = Double(smc_get_fan_max_rpm(Int32(i)))
            let target = Double(smc_get_fan_target_rpm(Int32(i)))
            let mode = Int(smc_get_fan_mode(Int32(i)))

            // Responsive physical tachometer smoothing (alpha = 0.5)
            let smoothed: Double
            if let prev = smoothedFanRPM[i], rawActual > 0 {
                smoothed = (0.5 * rawActual) + (0.5 * prev)
            } else {
                smoothed = rawActual
            }
            smoothedFanRPM[i] = smoothed

            // True physical tachometer RPM (single RPM precision, matching Macs Fan Control)
            let currentDisplay = Int(smoothed.rounded())
            lastDisplayRPM[i] = currentDisplay

            let name: String
            if fanCount == 2 {
                name = (i == 0) ? "Left Fan (CPU)" : "Right Fan (GPU)"
            } else {
                name = "Fan #\(i + 1)"
            }

            currentFans.append(FanData(
                index: i,
                name: name,
                currentRPM: smoothed,
                rawRPM: rawActual,
                displayRPM: currentDisplay,
                minRPM: minRpm > 0 ? minRpm : 1200,
                maxRPM: maxRpm > 0 ? maxRpm : 7000,
                targetRPM: target,
                modeRaw: mode
            ))
        }

        if !currentFans.isEmpty {
            self.fans = currentFans
        }

        let rawAvg = Double(smc_get_cpu_core_avg())
        let rawPeak = Double(smc_get_cpu_core_peak())
        let battery = Double(sensors_get_battery_temp())
        let storage = Double(sensors_get_storage_temp())
        let thermalState = ProcessInfo.processInfo.thermalState

        // Apply Exponential Moving Average filter on SoC temperatures
        let alpha = min(0.9, max(0.05, tempSmoothingAlpha))
        let smoothAvg: Double
        if let prev = smoothedCpuAvg {
            smoothAvg = (alpha * rawAvg) + ((1.0 - alpha) * prev)
        } else {
            smoothAvg = rawAvg
        }
        smoothedCpuAvg = smoothAvg

        let smoothPeak: Double
        if let prev = smoothedCpuPeak {
            smoothPeak = (alpha * rawPeak) + ((1.0 - alpha) * prev)
        } else {
            smoothPeak = rawPeak
        }
        smoothedCpuPeak = smoothPeak

        self.thermals = ThermalData(
            cpuAvg: smoothAvg,
            cpuPeak: smoothPeak,
            rawCpuAvg: rawAvg,
            rawCpuPeak: rawPeak,
            battery: battery,
            storage: storage,
            thermalPressure: thermalState
        )

        tempHistory.append(smoothAvg)
        if tempHistory.count > 30 { tempHistory.removeFirst() }

        let avgRpm = currentFans.isEmpty ? 0.0 : currentFans.map(\.currentRPM).reduce(0, +) / Double(currentFans.count)
        fanHistory.append(avgRpm)
        if fanHistory.count > 30 { fanHistory.removeFirst() }

        // Thermal Overheat Safety Evaluation
        // On Apple Silicon, peak junction temperatures spike to ~95-100°C for milliseconds.
        // True thermal emergency requires sustained extreme temperatures.
        let isEmergencyCandidate: Bool
        if smoothAvg >= 95.0 {
            // Bulk SoC average is dangerously high
            isEmergencyCandidate = true
        } else if rawPeak >= criticalThreshold && smoothPeak >= criticalThreshold {
            // Sustained peak core temperature above critical threshold
            overheatTriggerTicks += 1
            isEmergencyCandidate = (overheatTriggerTicks >= 4) // Sustained for >= 2.0s (4 ticks at 0.5s)
        } else {
            overheatTriggerTicks = max(0, overheatTriggerTicks - 1)
            isEmergencyCandidate = false
        }

        if !isOverheating {
            if isEmergencyCandidate {
                isOverheating = true
                overheatClearTicks = 0
                if activeMode != .auto {
                    statusMessage = "⚠️ CRITICAL TEMP: Overheat Failsafe Engaged"
                }
            }
        } else {
            // Overheat Hysteresis Release Guard:
            // Only release emergency state when temps cool significantly below threshold:
            // Bulk average must be below 84°C AND peak must be below (criticalThreshold - 8°C)
            let safeAvg = smoothAvg < 84.0
            let safePeak = smoothPeak < (criticalThreshold - 8.0)
            if safeAvg && safePeak {
                overheatClearTicks += 1
                if overheatClearTicks >= 4 { // Sustained cool for >= 2.0s
                    isOverheating = false
                    overheatClearTicks = 0
                    overheatTriggerTicks = 0
                    if activeMode != .auto {
                        statusMessage = "Thermal state normalized"
                    }
                }
            } else {
                overheatClearTicks = 0
            }
        }
    }

    // MARK: - Active Control Loop
    public func applyFanControl() {
        guard !fans.isEmpty else { return }

        // STRICT GUARANTEE: In macOS Auto mode, the app must NEVER influence fan speed.
        // Firmware has exclusive, unhindered control.
        if activeMode == .auto {
            let avg = fans.isEmpty ? 0.0 : fans.map(\.percentage).reduce(0, +) / Double(fans.count)
            currentCommandedPercentage = avg
            statusMessage = "macOS Firmware Controlling Fans"
            commandedRPMs.removeAll()
            curveEngine.resetSmoothing()
            lastTickTime = nil
            if hasHardwareControl && !didRestoreAutoHardware {
                writeAuto()
                didRestoreAutoHardware = true
            }
            return
        }

        // Compute elapsed time dt for precise slew-rate integration
        let now = Date()
        let dt: Double
        if let last = lastTickTime {
            dt = min(2.0, max(0.05, now.timeIntervalSince(last)))
        } else {
            dt = 0.5
        }
        lastTickTime = now

        let maxInc = rampUpRate * dt
        let maxDec = rampDownRate * dt

        // Emergency Overheat Safety Check (Only active when the app is actively controlling fans)
        if isOverheating {
            currentCommandedPercentage = 100.0
            if hasHardwareControl {
                for fan in fans {
                    let current = commandedRPMs[fan.index] ?? fan.currentRPM
                    let nextRPM = CurveEngine.slewLimit(
                        current: current,
                        target: fan.maxRPM,
                        maxIncrease: rampUpRate * dt * 2.5,
                        maxDecrease: maxDec
                    )
                    commandedRPMs[fan.index] = nextRPM
                    writeFanSpeed(index: fan.index, rpm: nextRPM)
                }
            }
            return
        }

        switch activeMode {
        case .auto:
            return // Handled above

        case .turbo:
            currentCommandedPercentage = 100.0
            statusMessage = "100% Full Blast Max Cooling"
            if hasHardwareControl {
                for fan in fans {
                    commandedRPMs[fan.index] = fan.maxRPM
                    writeFanSpeed(index: fan.index, rpm: fan.maxRPM)
                }
            }

        case .manual:
            let pct = fans.first.map { f in
                f.maxRPM > f.minRPM ? ((manualRPM - f.minRPM) / (f.maxRPM - f.minRPM)) * 100.0 : 50.0
            } ?? 50.0
            currentCommandedPercentage = pct
            statusMessage = "Manual Target: \(Int(manualRPM)) RPM"
            if hasHardwareControl {
                for fan in fans {
                    let clamped = max(fan.minRPM, min(fan.maxRPM, manualRPM))
                    let current = commandedRPMs[fan.index] ?? fan.currentRPM
                    let nextRPM = CurveEngine.slewLimit(
                        current: current,
                        target: clamped,
                        maxIncrease: maxInc,
                        maxDecrease: maxDec
                    )
                    commandedRPMs[fan.index] = nextRPM
                    writeFanSpeed(index: fan.index, rpm: nextRPM)
                }
            }

        case .curve:
            curveEngine.hysteresisBand = hysteresisBand
            curveEngine.criticalThreshold = criticalThreshold
            curveEngine.emaAlpha = tempSmoothingAlpha

            let drivingTemp = curveDrivingTemp
            let smoothedTemp = curveEngine.smoothTemperature(drivingTemp)
            let targetPercent = curveEngine.evaluate(temp: smoothedTemp, points: activePoints, useHysteresis: true)

            for fan in fans {
                let targetRPM = curveEngine.percentToRPM(percent: targetPercent, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                let current = commandedRPMs[fan.index] ?? fan.currentRPM
                let nextRPM = CurveEngine.slewLimit(
                    current: current,
                    target: targetRPM,
                    maxIncrease: maxInc,
                    maxDecrease: maxDec
                )
                commandedRPMs[fan.index] = nextRPM

                if hasHardwareControl {
                    writeFanSpeed(index: fan.index, rpm: nextRPM)
                }
            }

            // Sync currentCommandedPercentage continuously with the slewed fan RPM to eliminate step jumps in UI
            if let firstFan = fans.first, let firstCommanded = commandedRPMs[firstFan.index] {
                let pct = firstFan.maxRPM > firstFan.minRPM ?
                    ((firstCommanded - firstFan.minRPM) / (firstFan.maxRPM - firstFan.minRPM)) * 100.0 : targetPercent
                currentCommandedPercentage = max(0.0, min(100.0, pct))
            } else {
                currentCommandedPercentage = targetPercent
            }

            let firstCommanded = commandedRPMs.values.first ?? (fans.first?.currentRPM ?? 0)
            statusMessage = hasHardwareControl ?
                String(format: "Curve Active: %.1f°C (%.0f%%) • Target: %.0f RPM", drivingTemp, currentCommandedPercentage, firstCommanded) :
                "Curve Simulation (Install Helper for Control)"
        }
    }

    private func writeFanSpeed(index: Int, rpm: Double) {
        guard activeMode != .auto else {
            // Absolute prohibition: never write fan speed targets in macOS auto mode
            return
        }
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
        if mode == .auto {
            self.didRestoreAutoHardware = false
        } else {
            // Seed commandedRPMs with current physical fan speeds so slewing starts smoothly without steps
            for fan in fans {
                if commandedRPMs[fan.index] == nil {
                    commandedRPMs[fan.index] = fan.currentRPM
                }
            }
        }
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
        UserDefaults.standard.set(curveTempSource.rawValue, forKey: "CurveTempSource")
        UserDefaults.standard.set(menuBarTempSource.rawValue, forKey: "MenuBarTempSource")
        UserDefaults.standard.set(rampUpRate, forKey: "RampUpRate")
        UserDefaults.standard.set(rampDownRate, forKey: "RampDownRate")
        UserDefaults.standard.set(tempSmoothingAlpha, forKey: "TempSmoothingAlpha")

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

        if let curveSourceStr = UserDefaults.standard.string(forKey: "CurveTempSource"),
           let curveSource = CurveTempSource(rawValue: curveSourceStr) {
            self.curveTempSource = curveSource
        }

        if let sourceStr = UserDefaults.standard.string(forKey: "MenuBarTempSource"),
           let source = MenuBarTempSource(rawValue: sourceStr) {
            let isUserCustomized = UserDefaults.standard.bool(forKey: "UserExplicitlySetMenuBarTempSource")
            self.menuBarTempSource = isUserCustomized ? source : .cpuAverage
        } else {
            self.menuBarTempSource = .cpuAverage
        }

        if let layoutStr = UserDefaults.standard.string(forKey: "MenuBarLayoutStyle"),
           let layout = MenuBarLayoutStyle(rawValue: layoutStr) {
            self.menuBarLayoutStyle = layout
        }

        let savedUp = UserDefaults.standard.double(forKey: "RampUpRate")
        if savedUp >= 20.0 { self.rampUpRate = savedUp }

        let savedDown = UserDefaults.standard.double(forKey: "RampDownRate")
        if savedDown >= 10.0 { self.rampDownRate = savedDown }

        let savedAlpha = UserDefaults.standard.double(forKey: "TempSmoothingAlpha")
        if savedAlpha > 0.05 && savedAlpha <= 1.0 { self.tempSmoothingAlpha = savedAlpha }

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
        if savedCrit > 70.0 {
            // Migrate legacy default 95.0 to Apple Silicon safe 100.0
            self.criticalThreshold = (savedCrit == 95.0) ? 100.0 : savedCrit
        } else {
            self.criticalThreshold = 100.0
        }
    }
}
