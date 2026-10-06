import Foundation

let args = CommandLine.arguments

func printUsage() {
    print("""
    Fan Curve Controller CLI (fan-curve-ctl)
    Usage:
      fan-curve-ctl status                  Show live fan speeds and SoC thermals
      fan-curve-ctl auto                    Reset all fans to macOS automatic mode
      fan-curve-ctl turbo                   Engage 100% emergency cooling
      fan-curve-ctl set <rpm>               Set fixed fan RPM
      fan-curve-ctl curve [preset]          Run fan curve controller in daemon loop
                                            Presets: silent, balanced (default), performance
      fan-curve-ctl monitor                 Interactive real-time terminal monitor

    Examples:
      fan-curve-ctl status
      fan-curve-ctl curve balanced
      fan-curve-ctl set 4500
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

switch command {
case "status":
    printStatus()

case "auto":
    requireControl()
    if isRoot {
        _ = smc_set_all_auto()
    } else {
        _ = HelperClient.shared.setAuto()
    }
    print("✅ All fans returned to macOS automatic mode.")

case "turbo":
    requireControl()
    let count = smc_get_fan_count()
    for i in 0..<count {
        let maxRpm = smc_get_fan_max_rpm(i)
        if isRoot {
            _ = smc_set_fan_target(i, maxRpm)
        } else {
            _ = HelperClient.shared.setFan(index: Int(i), rpm: Double(maxRpm))
        }
    }
    print("⚡️ Emergency Turbo engaged: All fans commanded to 100% max speed.")

case "set":
    guard args.count >= 3, let rpm = Float(args[2]) else {
        print("Usage: fan-curve-ctl set <rpm>")
        exit(1)
    }
    requireControl()
    let count = smc_get_fan_count()
    for i in 0..<count {
        let minR = smc_get_fan_min_rpm(i)
        let maxR = smc_get_fan_max_rpm(i)
        let clamped = max(minR, min(maxR, rpm))
        if isRoot {
            _ = smc_set_fan_target(i, clamped)
        } else {
            _ = HelperClient.shared.setFan(index: Int(i), rpm: Double(clamped))
        }
        print("Set Fan #\(i) to \(Int(clamped)) RPM (range: \(Int(minR))-\(Int(maxR)))")
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
    let cpuAvg = sensors_get_cpu_avg()
    let cpuMax = sensors_get_cpu_max()
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

    signal(SIGINT) { _ in
        print("\n🛑 Restoring macOS automatic fan control...")
        if smc_is_root() {
            _ = smc_set_all_auto()
        } else {
            _ = HelperClient.shared.setAuto()
        }
        smc_close()
        sensors_close()
        exit(0)
    }
    signal(SIGTERM) { _ in
        if smc_is_root() {
            _ = smc_set_all_auto()
        } else {
            _ = HelperClient.shared.setAuto()
        }
        smc_close()
        sensors_close()
        exit(0)
    }

    let engine = CurveEngine(hysteresisBand: 2.0, criticalThreshold: 95.0)
    let points = preset.defaultPoints
    let fanCount = smc_get_fan_count()

    while true {
        let temp = Double(sensors_get_cpu_avg())
        let peakTemp = Double(sensors_get_cpu_max())
        let targetPercent = engine.evaluate(temp: temp, points: points, useHysteresis: true)

        var statusParts: [String] = []
        for i in 0..<fanCount {
            let minR = Double(smc_get_fan_min_rpm(i))
            let maxR = Double(smc_get_fan_max_rpm(i))
            let currentR = Double(smc_get_fan_rpm(i))
            let targetR = engine.percentToRPM(percent: targetPercent, minRPM: minR, maxRPM: maxR)

            if isRoot {
                _ = smc_set_fan_target(i, Float(targetR))
            } else if isHelper {
                _ = HelperClient.shared.setFan(index: Int(i), rpm: targetR)
            }
            statusParts.append(String(format: "Fan #%d: %.0f/%.0f RPM", i, currentR, targetR))
        }

        let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        print(String(format: "[%@] SoC: %.1f°C (Peak: %.1f°C) -> Target: %3.0f%% | %@",
                     timeStr, temp, peakTemp, targetPercent, statusParts.joined(separator: " | ")))

        Thread.sleep(forTimeInterval: 1.5)
    }
}

func runMonitorLoop() {
    print("\u{001B}[2J") // Clear screen
    let fanCount = smc_get_fan_count()

    signal(SIGINT) { _ in
        print("\u{001B}[?25h") // Show cursor
        exit(0)
    }

    while true {
        let temp = Double(sensors_get_cpu_avg())
        let peakTemp = Double(sensors_get_cpu_max())
        let battery = Double(sensors_get_battery_temp())
        let storage = Double(sensors_get_storage_temp())

        print("\u{001B}[H") // Move cursor to top
        print("════════════════════════════════════════════════════════════")
        print("           Mac Fan Controller Live Monitor                  ")
        print("════════════════════════════════════════════════════════════")
        print(String(format: "  SoC Average:   %5.1f °C  |  Peak Die:  %5.1f °C", temp, peakTemp))
        print(String(format: "  Battery:       %5.1f °C  |  Storage:   %5.1f °C", battery, storage))
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

        Thread.sleep(forTimeInterval: 1.0)
    }
}
