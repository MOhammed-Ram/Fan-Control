import Foundation
import Combine
import AppKit
import CoreGraphics
import IOKit.ps
@preconcurrency import UserNotifications

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
    @Published public var manualRPMRight: Double = 3500.0
    @Published public var linkFans: Bool = true
    @Published public var hysteresisBand: Double = 2.0
    @Published public var criticalThreshold: Double = 100.0
    @Published public var curveTempSource: CurveTempSource = .cpuAverage
    @Published public var menuBarTempSource: MenuBarTempSource = .cpuAverage
    @Published public var menuBarLayoutStyle: MenuBarLayoutStyle = .stackedDual
    @Published public var temperatureUnit: TemperatureUnit = .celsius
    @Published public var rampUpRate: Double = 120.0 // Max RPM acceleration per second
    @Published public var rampDownRate: Double = 60.0 // Max RPM deceleration per second
    @Published public var tempSmoothingAlpha: Double = 0.25 // EMA alpha (0.1..0.8)
    @Published public var currentCommandedPercentage: Double = 0.0
    @Published public var runAsMenuBarOnly: Bool = true
    @Published public var startAtLogin: Bool = false
    @Published public var startMinimized: Bool = true
    @Published public var isInstalledInApplications: Bool = false
    @Published public var autoSwitchPowerProfile: Bool = false
    @Published public var batteryPreset: ProfilePreset = .silent
    @Published public var acPreset: ProfilePreset = .balanced
    @Published public var isOnBattery: Bool = false
    @Published public var enableOverheatNotifications: Bool = true
    @Published public var enableNotificationSound: Bool = true
    @Published public var enablePowerSwitchNotifications: Bool = false

    private var commandedRPMs: [Int: Double] = [:]
    private var lastTickTime: Date? = nil
    private var didRestoreAutoHardware: Bool = false
    private var tickCounter: Int = 0
    private var lastKnownBatteryState: Bool? = nil

    // Telemetry Filtering & Deadband State
    private var smoothedFanRPM: [Int: Double] = [:]
    private var lastDisplayRPM: [Int: Int] = [:]
    private var smoothedCpuAvg: Double? = nil
    private var smoothedCpuPeak: Double? = nil
    private var smoothedGpu: Double? = nil
    private var lastDisplayIntTemp: Int? = nil
    private var overheatTriggerTicks: Int = 0
    private var overheatClearTicks: Int = 0

    @Published public var isDirectRoot: Bool = false
    @Published public var isHelperConnected: Bool = false
    @Published public var isOverheating: Bool = false
    @Published public var isSystemSleeping: Bool = false
    @Published public var statusMessage: String = "Ready"
    private var isDisplaySleeping: Bool = false
    private var isSuspendedForSleepOrLid: Bool = false

    private static func hasAwakeExternalDisplay() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return false
        }
        for i in 0..<Int(displayCount) {
            let d = displays[i]
            if CGDisplayIsBuiltin(d) == 0 && CGDisplayIsAsleep(d) == 0 {
                return true
            }
        }
        return false
    }

    public var shouldSuspendForSleepOrClamshell: Bool {
        if isSystemSleeping {
            return true
        }
        if smc_is_lid_closed() {
            if isDisplaySleeping || smc_clamshell_causes_sleep() || !Self.hasAwakeExternalDisplay() {
                return true
            }
        }
        return false
    }

    // Telemetry history for charts (last 30 data points)
    @Published public var tempHistory: [Double] = []
    @Published public var fanHistory: [Double] = []

    public var curveDrivingTemp: Double {
        switch curveTempSource {
        case .cpuAverage: return thermals.cpuAvg
        case .cpuAndGpuMax: return max(thermals.cpuAvg, thermals.gpu)
        case .cpuPeak: return thermals.cpuPeak
        case .gpuDie: return thermals.gpu
        }
    }

    public var currentDisplayTemp: Double {
        switch menuBarTempSource {
        case .cpuAverage: return thermals.cpuAvg
        case .cpuPeak: return thermals.cpuPeak
        case .gpuDie: return thermals.gpu
        }
    }

    public func formatTemp(_ celsius: Double, decimals: Int = 1) -> String {
        return temperatureUnit.format(celsius, decimals: decimals)
    }

    public func displayTempValue(_ celsius: Double) -> Double {
        return temperatureUnit.convert(celsius)
    }

    public var tempUnitSymbol: String {
        return temperatureUnit.symbol
    }

    public var currentDisplayIntTemp: Int {
        let t = temperatureUnit.convert(currentDisplayTemp)
        if let last = lastDisplayIntTemp {
            // 0.6 degree deadband around integer transition to prevent flip-flopping
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
    private let gpuCurveEngine = CurveEngine()
    private let helperClient = HelperClient.shared
    private var isSMCInitialized = false

    public init() {
        self.isDirectRoot = smc_is_root()
        loadSettings()
        LaunchAtLoginManager.shared.cleanupDuplicateRegistrations()
        setupHardware()
        setupSleepWakeHandlers()
        setupNotifications()
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
        pollPowerSource()
        pollHardware()
    }

    private var lastOverheatNotificationTime: Date? = nil

    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if enableOverheatNotifications || enablePowerSwitchNotifications {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    public func requestNotificationPermissionIfNeeded() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public func sendTestNotification() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                let content = UNMutableNotificationContent()
                content.title = "Fan Control Notification Test"
                content.body = String(format: "Notifications are active. Current SoC Avg: %@.", self.formatTemp(self.thermals.cpuAvg, decimals: 1))
                if self.enableNotificationSound {
                    content.sound = .default
                }
                let req = UNNotificationRequest(identifier: "com.macfancontrol.test.\(UUID().uuidString)", content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(req)
                self.statusMessage = granted ? "Test notification sent" : "Enable FanControl in macOS System Settings > Notifications"
            }
        }
    }

    private func sendOverheatNotification(peakTemp: Double) {
        guard enableOverheatNotifications else { return }
        let now = Date()
        if let lastTime = lastOverheatNotificationTime, now.timeIntervalSince(lastTime) < 180.0 {
            return
        }
        lastOverheatNotificationTime = now
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Thermal Emergency Failsafe Active"
        content.body = String(format: "Sustained SoC temperature reached %@ — fans ramped to 100%% maximum cooling.", formatTemp(peakTemp, decimals: 0))
        if enableNotificationSound {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: "com.macfancontrol.overheat", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func sendPowerSwitchNotification(onBattery: Bool, preset: ProfilePreset) {
        guard enablePowerSwitchNotifications, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = onBattery ? "Switched to Battery Profile" : "Switched to Power Adapter Profile"
        content.body = "Active fan curve preset automatically changed to \(preset.rawValue)."
        if enableNotificationSound {
            content.sound = .default
        }
        let req = UNNotificationRequest(identifier: "com.macfancontrol.powerswitch", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    public func checkControlPermissions() {
        self.isDirectRoot = smc_is_root()
        if !self.isDirectRoot {
            self.isHelperConnected = helperClient.isConnected
        } else {
            self.isHelperConnected = true
        }
    }

    private func suspendFanControlForSleepOrLid() {
        isSuspendedForSleepOrLid = true
        commandedRPMs.removeAll()
        curveEngine.resetSmoothing()
        gpuCurveEngine.resetSmoothing()
        lastTickTime = nil
        if hasHardwareControl {
            writeAuto()
            usleep(15000)
            writeAuto()
            didRestoreAutoHardware = true
        }
        statusMessage = "System Sleeping (macOS Auto)"
    }

    private func resumeFromSleepIfAwake() {
        if timer == nil {
            startPolling()
        }
        if shouldSuspendForSleepOrClamshell {
            suspendFanControlForSleepOrLid()
            return
        }
        isSuspendedForSleepOrLid = false
        didRestoreAutoHardware = false
        checkControlPermissions()
        pollPowerSource()
        pollHardware()
        applyFanControl()
    }

    private func setupSleepWakeHandlers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.isSystemSleeping = true
                self.suspendFanControlForSleepOrLid()
            }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.isSystemSleeping = true
                self.suspendFanControlForSleepOrLid()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.isDisplaySleeping = true
                if self.shouldSuspendForSleepOrClamshell {
                    self.suspendFanControlForSleepOrLid()
                }
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.isSystemSleeping = false
                self.resumeFromSleepIfAwake()
            }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.isDisplaySleeping = false
                self.isSystemSleeping = false
                self.resumeFromSleepIfAwake()
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
        if shouldSuspendForSleepOrClamshell {
            if !isSuspendedForSleepOrLid || !didRestoreAutoHardware {
                suspendFanControlForSleepOrLid()
            }
            return
        }
        if isSuspendedForSleepOrLid {
            isSuspendedForSleepOrLid = false
            didRestoreAutoHardware = false
            curveEngine.resetSmoothing()
            gpuCurveEngine.resetSmoothing()
            lastTickTime = nil
            checkControlPermissions()
            pollPowerSource()
        }
        tickCounter += 1
        // Verify helper connectivity & power source every 4 ticks (2.0s) instead of every 0.5s
        // (Active fan writes also update isHelperConnected directly)
        if tickCounter % 4 == 0 {
            if !isDirectRoot && (activeMode == .auto || !isHelperConnected) {
                self.isHelperConnected = helperClient.isConnected
            }
            pollPowerSource()
        }
        pollHardware()
        applyFanControl()
    }

    private static func checkIsOnBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let typeCF = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return false
        }
        let typeStr = typeCF as String
        return typeStr == (kIOPSBatteryPowerValue as String)
    }

    private func pollPowerSource() {
        let onBatt = Self.checkIsOnBattery()
        let previousState = lastKnownBatteryState
        self.isOnBattery = onBatt
        if autoSwitchPowerProfile {
            if previousState != onBatt {
                lastKnownBatteryState = onBatt
                let targetPreset = onBatt ? batteryPreset : acPreset
                if activePreset != targetPreset {
                    selectPreset(targetPreset)
                    if previousState != nil {
                        sendPowerSwitchNotification(onBattery: onBatt, preset: targetPreset)
                    }
                }
            }
        } else {
            lastKnownBatteryState = onBatt
        }
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

        var coreAvg: Float = 0
        var corePeak: Float = 0
        smc_get_cpu_core_temps(&coreAvg, &corePeak)
        let rawAvg = Double(coreAvg)
        let rawPeak = Double(corePeak)
        let rawGpu = Double(smc_get_gpu_temp())
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

        let smoothGpu: Double
        if let prev = smoothedGpu {
            smoothGpu = (alpha * rawGpu) + ((1.0 - alpha) * prev)
        } else {
            smoothGpu = rawGpu
        }
        smoothedGpu = smoothGpu

        self.thermals = ThermalData(
            cpuAvg: smoothAvg,
            cpuPeak: smoothPeak,
            gpu: smoothGpu,
            rawCpuAvg: rawAvg,
            rawCpuPeak: rawPeak,
            rawGpu: rawGpu,
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
        // Requires sustained high bulk SoC temperature (prevents false alerts from brief single-core Turbo Boost spikes)
        let isBulkHot = (smoothAvg >= 95.0 || smoothGpu >= 98.0) ||
            (rawPeak >= criticalThreshold && smoothPeak >= criticalThreshold && smoothAvg >= (criticalThreshold - 10.0))

        let isEmergencyCandidate: Bool
        if isBulkHot && thermalState != .nominal {
            overheatTriggerTicks += 1
            isEmergencyCandidate = (overheatTriggerTicks >= 8) // Sustained for >= 4.0s (8 ticks at 0.5s)
        } else if smoothAvg >= criticalThreshold {
            overheatTriggerTicks += 1
            isEmergencyCandidate = (overheatTriggerTicks >= 6) // Sustained bulk average >= criticalThreshold for 3.0s
        } else {
            overheatTriggerTicks = max(0, overheatTriggerTicks - 2)
            isEmergencyCandidate = false
        }

        if !isOverheating {
            if isEmergencyCandidate {
                isOverheating = true
                overheatClearTicks = 0
                if activeMode != .auto {
                    statusMessage = "⚠️ CRITICAL TEMP: Overheat Failsafe Engaged"
                    sendOverheatNotification(peakTemp: max(smoothAvg, smoothGpu))
                }
            }
        } else {
            let safeAvg = smoothAvg < 86.0 && smoothGpu < 86.0
            let safePeak = smoothPeak < (criticalThreshold - 6.0)
            if (safeAvg && safePeak) || thermalState == .nominal {
                overheatClearTicks += 1
                if overheatClearTicks >= 3 { // Sustained cool for >= 1.5s
                    isOverheating = false
                    overheatClearTicks = 0
                    overheatTriggerTicks = 0
                    commandedRPMs.removeAll()
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
        if shouldSuspendForSleepOrClamshell {
            if !isSuspendedForSleepOrLid || !didRestoreAutoHardware {
                suspendFanControlForSleepOrLid()
            }
            return
        }
        guard !fans.isEmpty else { return }

        // STRICT GUARANTEE: In macOS Auto mode, the app must NEVER influence fan speed.
        // Firmware has exclusive, unhindered control.
        if activeMode == .auto {
            let avg = fans.isEmpty ? 0.0 : fans.map(\.percentage).reduce(0, +) / Double(fans.count)
            currentCommandedPercentage = avg
            statusMessage = "macOS Firmware Controlling Fans"
            commandedRPMs.removeAll()
            curveEngine.resetSmoothing()
            gpuCurveEngine.resetSmoothing()
            lastTickTime = nil
            if hasHardwareControl && !didRestoreAutoHardware {
                writeAuto()
                didRestoreAutoHardware = true
            }
            return
        }

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
                var batchRPMs: [Double] = []
                for fan in fans {
                    let current = commandedRPMs[fan.index] ?? fan.currentRPM
                    let nextRPM = CurveEngine.slewLimit(
                        current: current,
                        target: fan.maxRPM,
                        maxIncrease: rampUpRate * dt * 2.5,
                        maxDecrease: maxDec
                    )
                    commandedRPMs[fan.index] = nextRPM
                    batchRPMs.append(nextRPM)
                }
                writeAllFanSpeeds(rpms: batchRPMs)
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
                var batchRPMs: [Double] = []
                for fan in fans {
                    commandedRPMs[fan.index] = fan.maxRPM
                    batchRPMs.append(fan.maxRPM)
                }
                writeAllFanSpeeds(rpms: batchRPMs)
            }

        case .manual:
            let pct = fans.first.map { f in
                f.maxRPM > f.minRPM ? ((manualRPM - f.minRPM) / (f.maxRPM - f.minRPM)) * 100.0 : 50.0
            } ?? 50.0
            currentCommandedPercentage = max(0.0, min(100.0, pct))
            if linkFans || fans.count < 2 {
                statusMessage = "Manual Target: \(Int(manualRPM)) RPM"
            } else {
                statusMessage = "Manual L: \(Int(manualRPM)) • R: \(Int(manualRPMRight)) RPM"
            }
            if hasHardwareControl {
                var batchRPMs: [Double] = []
                for fan in fans {
                    let requestedRPM = (!linkFans && fan.index == 1) ? manualRPMRight : manualRPM
                    let clamped = max(fan.minRPM, min(fan.maxRPM, requestedRPM))
                    let current = commandedRPMs[fan.index] ?? fan.currentRPM
                    let gap = current - clamped
                    let effectiveDec = (gap > 600.0) ? max(maxDec, gap * 0.25) : maxDec
                    let nextRPM = CurveEngine.slewLimit(
                        current: current,
                        target: clamped,
                        maxIncrease: maxInc,
                        maxDecrease: effectiveDec
                    )
                    commandedRPMs[fan.index] = nextRPM
                    batchRPMs.append(nextRPM)
                }
                writeAllFanSpeeds(rpms: batchRPMs)
            }

        case .curve:
            curveEngine.hysteresisBand = hysteresisBand
            curveEngine.criticalThreshold = criticalThreshold
            curveEngine.emaAlpha = tempSmoothingAlpha

            gpuCurveEngine.hysteresisBand = hysteresisBand
            gpuCurveEngine.criticalThreshold = criticalThreshold
            gpuCurveEngine.emaAlpha = tempSmoothingAlpha

            // pollHardware() already applies EMA smoothing to thermals.cpuAvg / cpuPeak / gpu.
            let drivingTemp = curveDrivingTemp
            let primaryTargetPercent = curveEngine.evaluate(temp: drivingTemp, points: activePoints, useHysteresis: true)

            let gpuDrivingTemp = max(thermals.gpu, thermals.cpuAvg * 0.85)
            let secondaryTargetPercent = gpuCurveEngine.evaluate(temp: gpuDrivingTemp, points: activePoints, useHysteresis: true)

            var batchRPMs: [Double] = []
            var primaryCurveTargetRPM: Double = 0.0
            for fan in fans {
                let fanPercent = (!linkFans && fan.index == 1) ? secondaryTargetPercent : primaryTargetPercent
                let targetRPM = curveEngine.percentToRPM(percent: fanPercent, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
                if fan.index == 0 { primaryCurveTargetRPM = targetRPM }
                let current = commandedRPMs[fan.index] ?? fan.currentRPM
                let gap = current - targetRPM
                let effectiveDec = (gap > 600.0) ? max(maxDec, gap * 0.22) : maxDec
                let nextRPM = CurveEngine.slewLimit(
                    current: current,
                    target: targetRPM,
                    maxIncrease: maxInc,
                    maxDecrease: effectiveDec
                )
                commandedRPMs[fan.index] = nextRPM
                batchRPMs.append(nextRPM)
            }

            if hasHardwareControl {
                writeAllFanSpeeds(rpms: batchRPMs)
            }

            currentCommandedPercentage = max(0.0, min(100.0, primaryTargetPercent))

            let firstCommanded = primaryCurveTargetRPM > 0 ? primaryCurveTargetRPM : (commandedRPMs[0] ?? (fans.first?.currentRPM ?? 0))
            if hasHardwareControl {
                if !linkFans && fans.count >= 2, let secondCommanded = commandedRPMs[1] {
                    statusMessage = String(format: "Split Curve: %@ • L: %.0f / R: %.0f RPM", formatTemp(drivingTemp, decimals: 1), firstCommanded, secondCommanded)
                } else {
                    statusMessage = String(format: "Curve Active: %@ (%.0f%%) • Target: %.0f RPM", formatTemp(drivingTemp, decimals: 1), primaryTargetPercent, firstCommanded)
                }
            } else {
                statusMessage = "Curve Simulation (Install Helper for Control)"
            }
        }
    }

    private func writeAllFanSpeeds(rpms: [Double]) {
        guard activeMode != .auto, !rpms.isEmpty else { return }
        if isDirectRoot {
            for (idx, rpm) in rpms.enumerated() {
                _ = smc_set_fan_target(Int32(idx), Float(rpm))
            }
        } else if isHelperConnected {
            let ok = helperClient.setAllFans(rpms: rpms)
            self.isHelperConnected = ok
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

    // MARK: - Custom Curve Import / Export
    public func exportCustomCurve(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(activePoints)
        try data.write(to: url, options: .atomic)
    }

    public func importCustomCurve(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([CurvePoint].self, from: data)
        guard decoded.count >= 2 else {
            throw NSError(domain: "FanControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Curve profile must contain at least 2 control points."])
        }
        self.customPoints = decoded.sorted { $0.temp < $1.temp }
        self.activePreset = .custom
        saveSettings()
        applyFanControl()
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
        let bundleScript = Bundle.main.bundlePath + "/Contents/Resources/install-helper.sh"
        let cwdScript = FileManager.default.currentDirectoryPath + "/Scripts/install-helper.sh"
        let appScript = "/Applications/FanControl.app/Contents/Resources/install-helper.sh"

        let targetScript: String
        if FileManager.default.fileExists(atPath: bundleScript) {
            targetScript = bundleScript
        } else if FileManager.default.fileExists(atPath: cwdScript) {
            targetScript = cwdScript
        } else {
            targetScript = appScript
        }

        let shellCmd = "bash \(ShellEscaping.posixSingleQuote(targetScript))"
        let appleScriptSource = ShellEscaping.appleScriptDoShellScript(shellCmd, administratorPrivileges: true)
        var error: NSDictionary?
        if let script = NSAppleScript(source: appleScriptSource) {
            script.executeAndReturnError(&error)
            if let err = error {
                let msg = err[NSAppleScript.errorMessage] as? String ?? "Authorization failed"
                self.statusMessage = "Helper Install: \(msg)"
                print("Helper installation failed: \(msg)")
            } else {
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

    public func updateInstallationStatus() {
        self.isInstalledInApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        self.startAtLogin = LaunchAtLoginManager.shared.isEnabled
    }

    public func setRunAsMenuBarOnly(_ enabled: Bool) {
        self.runAsMenuBarOnly = enabled
        UserDefaults.standard.set(enabled, forKey: "RunAsMenuBarOnly")
        if enabled {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    public func setStartAtLogin(_ enabled: Bool) {
        self.startAtLogin = enabled
        LaunchAtLoginManager.shared.setEnabled(enabled)
    }

    public func setStartMinimized(_ enabled: Bool) {
        self.startMinimized = enabled
        UserDefaults.standard.set(enabled, forKey: "StartMinimized")
    }

    @discardableResult
    public func installToApplications() -> Bool {
        let currentPath = Bundle.main.bundlePath
        let targetPath = "/Applications/FanControl.app"

        if currentPath == targetPath {
            self.isInstalledInApplications = true
            return true
        }

        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: targetPath) {
                try fileManager.removeItem(atPath: targetPath)
            }
            try fileManager.copyItem(atPath: currentPath, toPath: targetPath)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [targetPath]
            try process.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.terminate(nil)
            }
            return true
        } catch {
            let quotedTarget = ShellEscaping.posixSingleQuote(targetPath)
            let quotedCurrent = ShellEscaping.posixSingleQuote(currentPath)
            let shellCmd = "rm -rf \(quotedTarget) && cp -R \(quotedCurrent) \(quotedTarget) && open \(quotedTarget)"
            let scriptSource = ShellEscaping.appleScriptDoShellScript(shellCmd, administratorPrivileges: true)
            var scriptError: NSDictionary?
            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(&scriptError)
                if scriptError == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Persistence
    public func saveSettings() {
        UserDefaults.standard.set(activeMode.rawValue, forKey: "ActiveMode")
        UserDefaults.standard.set(activePreset.rawValue, forKey: "ActivePreset")
        UserDefaults.standard.set(manualRPM, forKey: "ManualRPM")
        UserDefaults.standard.set(manualRPMRight, forKey: "ManualRPMRight")
        UserDefaults.standard.set(linkFans, forKey: "LinkFans")
        UserDefaults.standard.set(hysteresisBand, forKey: "HysteresisBand")
        UserDefaults.standard.set(criticalThreshold, forKey: "CriticalThreshold")
        UserDefaults.standard.set(curveTempSource.rawValue, forKey: "CurveTempSource")
        UserDefaults.standard.set(menuBarTempSource.rawValue, forKey: "MenuBarTempSource")
        UserDefaults.standard.set(menuBarLayoutStyle.rawValue, forKey: "MenuBarLayoutStyle")
        UserDefaults.standard.set(temperatureUnit.rawValue, forKey: "TemperatureUnit")
        UserDefaults.standard.set(rampUpRate, forKey: "RampUpRate")
        UserDefaults.standard.set(rampDownRate, forKey: "RampDownRate")
        UserDefaults.standard.set(tempSmoothingAlpha, forKey: "TempSmoothingAlpha")
        UserDefaults.standard.set(runAsMenuBarOnly, forKey: "RunAsMenuBarOnly")
        UserDefaults.standard.set(startMinimized, forKey: "StartMinimized")
        UserDefaults.standard.set(autoSwitchPowerProfile, forKey: "AutoSwitchPowerProfile")
        UserDefaults.standard.set(batteryPreset.rawValue, forKey: "BatteryPreset")
        UserDefaults.standard.set(acPreset.rawValue, forKey: "ACPreset")
        UserDefaults.standard.set(enableOverheatNotifications, forKey: "EnableOverheatNotifications")
        UserDefaults.standard.set(enableNotificationSound, forKey: "EnableNotificationSound")
        UserDefaults.standard.set(enablePowerSwitchNotifications, forKey: "EnablePowerSwitchNotifications")

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

        if let unitStr = UserDefaults.standard.string(forKey: "TemperatureUnit"),
           let unit = TemperatureUnit(rawValue: unitStr) {
            self.temperatureUnit = unit
        }

        if UserDefaults.standard.object(forKey: "LinkFans") != nil {
            self.linkFans = UserDefaults.standard.bool(forKey: "LinkFans")
        } else {
            self.linkFans = true
        }

        if UserDefaults.standard.object(forKey: "AutoSwitchPowerProfile") != nil {
            self.autoSwitchPowerProfile = UserDefaults.standard.bool(forKey: "AutoSwitchPowerProfile")
        }

        if UserDefaults.standard.object(forKey: "EnableOverheatNotifications") != nil {
            self.enableOverheatNotifications = UserDefaults.standard.bool(forKey: "EnableOverheatNotifications")
        } else {
            self.enableOverheatNotifications = true
        }

        if UserDefaults.standard.object(forKey: "EnableNotificationSound") != nil {
            self.enableNotificationSound = UserDefaults.standard.bool(forKey: "EnableNotificationSound")
        } else {
            self.enableNotificationSound = true
        }

        if UserDefaults.standard.object(forKey: "EnablePowerSwitchNotifications") != nil {
            self.enablePowerSwitchNotifications = UserDefaults.standard.bool(forKey: "EnablePowerSwitchNotifications")
        } else {
            self.enablePowerSwitchNotifications = false
        }

        if let battStr = UserDefaults.standard.string(forKey: "BatteryPreset"),
           let battP = ProfilePreset(rawValue: battStr) {
            self.batteryPreset = battP
        }

        if let acStr = UserDefaults.standard.string(forKey: "ACPreset"),
           let acP = ProfilePreset(rawValue: acStr) {
            self.acPreset = acP
        }

        let savedUp = UserDefaults.standard.double(forKey: "RampUpRate")
        if savedUp >= 20.0 { self.rampUpRate = savedUp }

        let savedDown = UserDefaults.standard.double(forKey: "RampDownRate")
        if savedDown >= 10.0 { self.rampDownRate = savedDown }

        let savedAlpha = UserDefaults.standard.double(forKey: "TempSmoothingAlpha")
        if savedAlpha > 0.05 && savedAlpha <= 1.0 { self.tempSmoothingAlpha = savedAlpha }

        let savedRPM = UserDefaults.standard.double(forKey: "ManualRPM")
        if savedRPM > 1000 { self.manualRPM = savedRPM }

        let savedRPMRight = UserDefaults.standard.double(forKey: "ManualRPMRight")
        if savedRPMRight > 1000 {
            self.manualRPMRight = savedRPMRight
        } else {
            self.manualRPMRight = self.manualRPM
        }

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
            self.criticalThreshold = (savedCrit == 95.0) ? 100.0 : savedCrit
        } else {
            self.criticalThreshold = 100.0
        }

        if UserDefaults.standard.object(forKey: "RunAsMenuBarOnly") != nil {
            self.runAsMenuBarOnly = UserDefaults.standard.bool(forKey: "RunAsMenuBarOnly")
        } else {
            self.runAsMenuBarOnly = true
        }
        if UserDefaults.standard.object(forKey: "StartMinimized") != nil {
            self.startMinimized = UserDefaults.standard.bool(forKey: "StartMinimized")
        } else {
            self.startMinimized = true
        }
        updateInstallationStatus()
    }
}
