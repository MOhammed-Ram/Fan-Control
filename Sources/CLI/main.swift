import Foundation

private var gCliShouldExit: sig_atomic_t = 0

func installExitSignalHandlers() {
    gCliShouldExit = 0
    signal(SIGINT) { _ in gCliShouldExit = 1 }
    signal(SIGTERM) { _ in gCliShouldExit = 1 }
}

func interruptibleSleep(seconds: Double) {
    let chunkUs: useconds_t = 50_000 // 50ms chunks
    let totalChunks = max(1, Int((seconds * 1_000_000.0) / Double(chunkUs)))
    for _ in 0..<totalChunks {
        if gCliShouldExit != 0 { break }
        usleep(chunkUs)
    }
}

let args = CommandLine.arguments

func printUsage() {
    print("""
    Fan Curve Controller CLI (fan-curve-ctl)
    Usage:
      fan-curve-ctl status                           Show live fan speeds and SoC thermals
      fan-curve-ctl auto                             Reset all fans to macOS automatic mode
      fan-curve-ctl turbo [--hold]                   Engage 100% emergency cooling
      fan-curve-ctl set <rpm> [--fan <idx>] [--hold] Set fixed fan RPM (all fans or specific fan)
      fan-curve-ctl curve [preset]                   Run fan curve controller in daemon loop
                                                     Presets: silent, balanced (default), performance
      fan-curve-ctl monitor                          Interactive real-time terminal monitor

    Options:
      --hold       Keepalive loop (re-sends target every 1.5s to satisfy helper watchdog; Ctrl+C restores auto)
      --fan <idx>  Target a specific fan index (0-based) for 'set'

    Examples:
      fan-curve-ctl status
      fan-curve-ctl curve balanced
      fan-curve-ctl set 4500 --hold
      fan-curve-ctl set 3500 --fan 0 --hold
      fan-curve-ctl turbo --hold
      fan-curve-ctl auto
    """)
}

_ = smc_open()
_ = sensors_init()

defer {
    smc_close()
    sensors_close()
}

if args.count < 2 {
    printUsage()
    exit(0)
}

let command = args[1].lowercased()
let isRoot = smc_is_root()
let isHelper = HelperClient.shared.isConnected
let hasControl = isRoot || isHelper

func requireControl() {
    if !hasControl {
        print("❌ Error: Writing fan speeds requires root privileges or the running helper.")
        print("   Options:")
        print("     1. Run with sudo: sudo fan-curve-ctl \(command)")
        print("     2. Install helper daemon: sudo ./Scripts/install-helper.sh")
        exit(1)
    }
}

func restoreAutoControl() {
    if isRoot {
        _ = smc_set_all_auto()
    } else if isHelper {
        _ = HelperClient.shared.setAuto()
    }
}

func applyFanTargets(_ targets: [(index: Int32, rpm: Float)]) {
    if isRoot {
        for target in targets {
            _ = smc_set_fan_target(target.index, target.rpm)
        }
    } else if isHelper {
        for target in targets {
            _ = HelperClient.shared.setFan(index: Int(target.index), rpm: Double(target.rpm))
        }
    }
}

func runHoldLoop(targets: [(index: Int32, rpm: Float)]) {
    installExitSignalHandlers()
    while gCliShouldExit == 0 {
        interruptibleSleep(seconds: 1.5)
        if gCliShouldExit != 0 { break }
        applyFanTargets(targets)
    }
    print("\n🛑 Restoring macOS automatic fan control...")
    restoreAutoControl()
}

switch command {
case "status":
    printStatus()

case "auto":
    requireControl()
    restoreAutoControl()
    print("✅ All fans returned to macOS automatic mode.")

case "turbo":
    var holdMode = false
    var argIdx = 2
    while argIdx < args.count {
        if args[argIdx] == "--hold" {
            holdMode = true
        } else {
            print("❌ Error: Unknown option '\(args[argIdx])'")
            print("Usage: fan-curve-ctl turbo [--hold]")
            exit(1)
        }
        argIdx += 1
    }

    requireControl()
    let count = smc_get_fan_count()
    var targets: [(index: Int32, rpm: Float)] = []
    for i in 0..<count {
        let maxRpm = smc_get_fan_max_rpm(i)
        targets.append((index: i, rpm: maxRpm))
    }
    applyFanTargets(targets)

    if holdMode {
        print("⚡️ Emergency Turbo engaged (holding at 100% max speed). Press Ctrl+C to restore macOS automatic mode.")
        runHoldLoop(targets: targets)
    } else {
        print("⚡️ Emergency Turbo engaged: All fans commanded to 100% max speed.")
        if !isRoot && isHelper {
            print("ℹ️ Note: The helper daemon's 4-second safety watchdog will return fans to automatic mode unless --hold is passed (or 'fan-curve-ctl curve' is used).")
        }
    }

case "set":
    guard args.count >= 3, let rpm = Float(args[2]), rpm.isFinite, rpm >= 0 else {
        print("❌ Error: Invalid RPM value. Expected a finite non-negative number.")
        print("Usage: fan-curve-ctl set <rpm> [--fan <idx>] [--hold]")
        exit(1)
    }

    var targetFanIdx: Int32? = nil
    var holdMode = false
    var argIdx = 3
    while argIdx < args.count {
        let flag = args[argIdx]
        if flag == "--hold" {
            holdMode = true
            argIdx += 1
        } else if flag == "--fan" {
            guard argIdx + 1 < args.count, let parsedIdx = Int32(args[argIdx + 1]) else {
                print("❌ Error: --fan requires a valid integer fan index.")
                print("Usage: fan-curve-ctl set <rpm> [--fan <idx>] [--hold]")
                exit(1)
            }
            targetFanIdx = parsedIdx
            argIdx += 2
        } else {
            print("❌ Error: Unknown option '\(flag)'")
            print("Usage: fan-curve-ctl set <rpm> [--fan <idx>] [--hold]")
            exit(1)
        }
    }

    requireControl()
    let count = smc_get_fan_count()
    let fanIndices: [Int32]
    if let explicitIdx = targetFanIdx {
        guard explicitIdx >= 0 && explicitIdx < count else {
            print("❌ Error: Fan index \(explicitIdx) out of range (detected fans: \(count)).")
            exit(1)
        }
        fanIndices = [explicitIdx]
    } else {
        fanIndices = Array(0..<count)
    }

    var targets: [(index: Int32, rpm: Float)] = []
    var ranges: [(minR: Float, maxR: Float)] = []
    for i in fanIndices {
        let minR = smc_get_fan_min_rpm(i)
        let maxR = smc_get_fan_max_rpm(i)
        let clamped = max(minR, min(maxR, rpm))
        targets.append((index: i, rpm: clamped))
        ranges.append((minR: minR, maxR: maxR))
    }
    applyFanTargets(targets)

    for (target, range) in zip(targets, ranges) {
        print("Set Fan #\(target.index) to \(Int(target.rpm)) RPM (range: \(Int(range.minR))-\(Int(range.maxR)))")
    }

    if holdMode {
        print("🔒 Holding target fan speed(s). Press Ctrl+C to restore macOS automatic mode.")
        runHoldLoop(targets: targets)
    } else if !isRoot && isHelper {
        print("ℹ️ Note: The helper daemon's 4-second safety watchdog will return fans to automatic mode unless --hold is passed (or 'fan-curve-ctl curve' is used).")
    }

case "curve":
    let presetName = (args.count >= 3 ? args[2].lowercased() : "balanced")
    let preset: ProfilePreset
    switch presetName {
    case "silent": preset = .silent
    case "performance": preset = .performance
    default: preset = .balanced
    }
    runCurveLoop(preset: preset)

case "monitor":
    runMonitorLoop()

default:
    printUsage()
    exit(1)
}

func printStatus() {
    let fanCount = smc_get_fan_count()
    var cpuAvg: Float = 0.0
    var cpuMax: Float = 0.0
    smc_get_cpu_core_temps(&cpuAvg, &cpuMax)
    let gpuTemp = smc_get_gpu_temp()
    let battery = sensors_get_battery_temp()
    let storage = sensors_get_storage_temp()

    var privString = "Unprivileged (Monitor Only)"
    if isRoot {
        privString = "Root (Direct SMC Write)"
    } else if isHelper {
        privString = "Helper Connected (Hardware Control Active)"
    }

    print("════════════════════════════════════════════════════════════")
    print("           Mac Fan Curve Controller Status                  ")
    print("════════════════════════════════════════════════════════════")
    print(String(format: "  SoC CPU Average:    %5.1f °C", cpuAvg))
    print(String(format: "  SoC CPU Peak Die:   %5.1f °C", cpuMax))
    print(String(format: "  SoC GPU Die:        %5.1f °C", gpuTemp))
    print(String(format: "  Battery:            %5.1f °C", battery))
    print(String(format: "  Storage (NAND):     %5.1f °C", storage))
    print("  Privilege Level:    \(privString)")
    print("────────────────────────────────────────────────────────────")
    print("  Hardware Fans (\(fanCount) detected):")

    for i in 0..<fanCount {
        let rpm = smc_get_fan_rpm(i)
        let minR = smc_get_fan_min_rpm(i)
        let maxR = smc_get_fan_max_rpm(i)
        let target = smc_get_fan_target_rpm(i)
        let mode = smc_get_fan_mode(i)
        let pct = (maxR > minR) ? ((rpm - minR) / (maxR - minR)) * 100.0 : 0.0

        let modeDesc = (mode == 0) ? "Auto" : (mode == 1 ? "Manual" : "System (\(mode))")
        print(String(format: "    Fan #%d: %4.0f RPM (%3.0f%%)  Target: %4.0f RPM  [Range: %4.0f - %4.0f]  Mode: %@",
                     i, rpm, pct, target, minR, maxR, modeDesc))
    }
    print("════════════════════════════════════════════════════════════")
}

func runCurveLoop(preset: ProfilePreset) {
    if !hasControl {
        print("⚠️ Warning: Running without hardware control privileges. Operating in simulation mode.")
        print("   To actively control hardware fans, run with sudo or install helper.")
    }

    print("🚀 Starting Fan Curve Engine with preset: \(preset.rawValue)")
    print("   Press Ctrl+C to terminate and restore macOS automatic mode.")

    installExitSignalHandlers()

    let engine = CurveEngine(hysteresisBand: 2.0, criticalThreshold: 100.0, emaAlpha: 0.25)
    let points = preset.defaultPoints
    let fanCount = smc_get_fan_count()
    var commandedRPMs: [Int: Double] = [:]

    while gCliShouldExit == 0 {
        var rawAvgF: Float = 0.0
        var peakTempF: Float = 0.0
        smc_get_cpu_core_temps(&rawAvgF, &peakTempF)
        let rawAvg = Double(rawAvgF)
        let smoothedTemp = engine.smoothTemperature(rawAvg)
        let peakTemp = Double(peakTempF)
        let targetPercent = engine.evaluate(temp: smoothedTemp, points: points, useHysteresis: true)

        var statusParts: [String] = []
        for i in 0..<fanCount {
            let minR = Double(smc_get_fan_min_rpm(i))
            let maxR = Double(smc_get_fan_max_rpm(i))
            let currentR = Double(smc_get_fan_rpm(i))
            let targetR = engine.percentToRPM(percent: targetPercent, minRPM: minR, maxRPM: maxR)
            let prevCommand = commandedRPMs[Int(i)] ?? currentR
            let nextR = CurveEngine.slewLimit(current: prevCommand, target: targetR, maxIncrease: 120.0, maxDecrease: 60.0)
            commandedRPMs[Int(i)] = nextR

            if isRoot {
                _ = smc_set_fan_target(i, Float(nextR))
            } else if isHelper {
                _ = HelperClient.shared.setFan(index: Int(i), rpm: nextR)
            }
            statusParts.append(String(format: "Fan #%d: %.0f -> %.0f RPM", i, currentR, nextR))
        }

        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print(String(format: "[%@] SoC Avg: %.1f°C (Smooth: %.1f°C, Peak: %.1f°C) -> Target: %3.0f%% | %@",
                     timeStr, rawAvg, smoothedTemp, peakTemp, targetPercent, statusParts.joined(separator: " | ")))

        interruptibleSleep(seconds: 1.0)
    }

    print("\n🛑 Restoring macOS automatic fan control...")
    restoreAutoControl()
}

func runMonitorLoop() {
    print("\u{001B}[2J") // Clear screen
    let fanCount = smc_get_fan_count()

    installExitSignalHandlers()

    while gCliShouldExit == 0 {
        var tempF: Float = 0.0
        var peakTempF: Float = 0.0
        smc_get_cpu_core_temps(&tempF, &peakTempF)
        let temp = Double(tempF)
        let peakTemp = Double(peakTempF)
        let gpuTemp = Double(smc_get_gpu_temp())
        let battery = Double(sensors_get_battery_temp())
        let storage = Double(sensors_get_storage_temp())

        print("\u{001B}[H") // Move cursor to top
        print("════════════════════════════════════════════════════════════")
        print("           Mac Fan Controller Live Monitor                  ")
        print("════════════════════════════════════════════════════════════")
        print(String(format: "  SoC Average:   %5.1f °C  |  Peak Die:  %5.1f °C", temp, peakTemp))
        print(String(format: "  GPU Die:       %5.1f °C  |  Battery:   %5.1f °C  |  SSD: %4.1f °C", gpuTemp, battery, storage))
        print("────────────────────────────────────────────────────────────")

        for i in 0..<fanCount {
            let rpm = Double(smc_get_fan_rpm(i))
            let minR = Double(smc_get_fan_min_rpm(i))
            let maxR = Double(smc_get_fan_max_rpm(i))
            let pct = (maxR > minR) ? ((rpm - minR) / (maxR - minR)) * 100.0 : 0.0

            let barWidth = 24
            let filled = min(barWidth, max(0, Int((pct / 100.0) * Double(barWidth))))
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)

            print(String(format: "  Fan #%d: [%@] %4.0f RPM (%3.0f%%)", i, bar, rpm, pct))
        }

        print("════════════════════════════════════════════════════════════")
        print("  Press Ctrl+C to exit monitor.")

        interruptibleSleep(seconds: 1.0)
    }

    print("\u{001B}[?25h") // Show cursor
}
