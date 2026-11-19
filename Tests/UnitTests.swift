import Foundation

// MARK: - Minimal Test Harness

private var passedTests = 0
private var failedTests = 0

private func check(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passedTests += 1
    } else {
        failedTests += 1
        let filename = (file as NSString).lastPathComponent
        fputs("  ❌ FAIL [\(filename):\(line)] \(message)\n", stderr)
    }
}

private func checkApprox(_ actual: Double, _ expected: Double, tolerance: Double = 1e-4, _ message: String, file: String = #file, line: Int = #line) {
    let diff = abs(actual - expected)
    check(diff <= tolerance, "\(message) (actual=\(actual), expected=\(expected), tol=\(tolerance))", file: file, line: line)
}

private func suite(_ name: String, _ block: () -> Void) {
    let beforeFail = failedTests
    print("🧪 \(name)")
    block()
    if failedTests == beforeFail {
        print("  ✅ OK")
    }
}

// MARK: - Test Suites

@main
enum UnitTestRunner {
static func main() {

suite("CurveEngine — Boundary Clamping & Empty Points") {
    let engine = CurveEngine(hysteresisBand: 0.0, criticalThreshold: 100.0, emaAlpha: 1.0)
    let points = [
        CurvePoint(temp: 40.0, fanPercent: 20.0),
        CurvePoint(temp: 70.0, fanPercent: 60.0),
        CurvePoint(temp: 90.0, fanPercent: 100.0)
    ]

    checkApprox(engine.evaluate(temp: 25.0, points: points, useHysteresis: false), 20.0, "Below min temp clamps to first point")
    checkApprox(engine.evaluate(temp: 40.0, points: points, useHysteresis: false), 20.0, "At min temp returns first point")
    checkApprox(engine.evaluate(temp: 90.0, points: points, useHysteresis: false), 100.0, "At max temp returns last point")
    checkApprox(engine.evaluate(temp: 99.0, points: points, useHysteresis: false), 100.0, "Above max temp clamps to last point")
    checkApprox(engine.evaluate(temp: 60.0, points: [], useHysteresis: false), 50.0, "Empty points returns safe 50% fallback")
}

suite("CurveEngine — Monotone Catmull-Rom Spline (No Overshoot/Undershoot)") {
    // Sharp step transition that would overshoot with unclamped Catmull-Rom
    let sharpStep = [
        CurvePoint(temp: 35.0, fanPercent: 0.0),
        CurvePoint(temp: 55.0, fanPercent: 0.0),
        CurvePoint(temp: 60.0, fanPercent: 80.0),
        CurvePoint(temp: 90.0, fanPercent: 80.0)
    ]

    for temp in stride(from: 35.0, through: 55.0, by: 1.0) {
        let val = CurveEngine.evaluateOnCurve(temp: temp, points: sharpStep)
        check(val >= 0.0 && val <= 0.0001, "Flat 0% segment must not undershoot or overshoot at \(temp)°C (got \(val))")
    }

    for temp in stride(from: 60.0, through: 90.0, by: 1.0) {
        let val = CurveEngine.evaluateOnCurve(temp: temp, points: sharpStep)
        check(val >= 79.999 && val <= 80.001, "Flat 80% segment must not overshoot at \(temp)°C (got \(val))")
    }

    // All presets must stay within [0, 100] and remain non-decreasing across the domain
    for preset in ProfilePreset.allCases {
        let samples = CurveEngine.sampleCurve(points: preset.defaultPoints, minTemp: 30.0, maxTemp: 100.0, steps: 140)
        var prev = -1.0
        var monotonic = true
        for s in samples {
            if s.percent < 0.0 || s.percent > 100.0 || s.percent + 1e-6 < prev {
                monotonic = false
                break
            }
            prev = s.percent
        }
        check(monotonic, "Preset '\(preset.rawValue)' curve must be bounded [0,100] and monotonically non-decreasing")
    }
}

suite("CurveEngine — Hysteresis Deadband & Emergency Overheat") {
    let points = [
        CurvePoint(temp: 40.0, fanPercent: 0.0),
        CurvePoint(temp: 80.0, fanPercent: 80.0)
    ]
    let engine = CurveEngine(hysteresisBand: 3.0, criticalThreshold: 100.0, emaAlpha: 1.0)

    let pAt70 = engine.evaluate(temp: 70.0, points: points, useHysteresis: true)
    check(pAt70 > 50.0, "Spin-up at 70°C responds immediately (got \(pAt70))")

    // Dropping by 2°C (< 3°C hysteresis band) must hold the speed from 70°C
    let pAt68 = engine.evaluate(temp: 68.0, points: points, useHysteresis: true)
    checkApprox(pAt68, pAt70, "Drop of 2°C inside 3°C band holds previous fan percentage")

    // Rising to 75°C spins up immediately
    let pAt75 = engine.evaluate(temp: 75.0, points: points, useHysteresis: true)
    check(pAt75 > pAt70, "Rise to 75°C increases speed immediately")

    // Dropping by 4°C (>= 3°C band) from 75°C to 71°C allows spin-down
    let pAt71 = engine.evaluate(temp: 71.0, points: points, useHysteresis: true)
    check(pAt71 < pAt75, "Drop of 4°C outside 3°C band allows spin-down")

    // Critical overheat threshold forces 100% even if curve max is 80%
    let pCritical = engine.evaluate(temp: 100.0, points: points, useHysteresis: true)
    checkApprox(pCritical, 100.0, "Critical threshold >= 100°C forces 100% emergency fan speed")

    // Chart evaluation (useHysteresis: false) should NOT spike to 100%
    let pChart = engine.evaluate(temp: 100.0, points: points, useHysteresis: false)
    checkApprox(pChart, 80.0, "Chart evaluation without hysteresis reflects curve top (80%)")

    // Reset smoothing clears hysteresis memory
    engine.resetSmoothing()
    let pAfterReset = engine.evaluate(temp: 50.0, points: points, useHysteresis: true)
    check(pAfterReset < pAt70, "resetSmoothing clears hysteresis state")
}

suite("CurveEngine — Slew Limit, Percent-to-RPM & EMA Smoothing") {
    checkApprox(CurveEngine.slewLimit(current: 2000, target: 4000, maxIncrease: 300, maxDecrease: 150), 2300, "Slew up clamps to maxIncrease")
    checkApprox(CurveEngine.slewLimit(current: 4000, target: 2000, maxIncrease: 300, maxDecrease: 150), 3850, "Slew down clamps to maxDecrease")
    checkApprox(CurveEngine.slewLimit(current: 2000, target: 2100, maxIncrease: 300, maxDecrease: 150), 2100, "Slew within delta reaches exact target")
    checkApprox(CurveEngine.slewLimit(current: 2000, target: 2000, maxIncrease: 300, maxDecrease: 150), 2000, "Slew at target stays steady")

    let engine = CurveEngine(hysteresisBand: 2.0, criticalThreshold: 100.0, emaAlpha: 0.25)
    checkApprox(engine.percentToRPM(percent: 0, minRPM: 1200, maxRPM: 6000), 1200, "0% maps to minRPM")
    checkApprox(engine.percentToRPM(percent: 50, minRPM: 1200, maxRPM: 6000), 3600, "50% maps to midpoint RPM")
    checkApprox(engine.percentToRPM(percent: 100, minRPM: 1200, maxRPM: 6000), 6000, "100% maps to maxRPM")
    checkApprox(engine.percentToRPM(percent: -25, minRPM: 1200, maxRPM: 6000), 1200, "Negative % clamps to minRPM")
    checkApprox(engine.percentToRPM(percent: 150, minRPM: 1200, maxRPM: 6000), 6000, ">100% clamps to maxRPM")
    checkApprox(engine.percentToRPM(percent: 50, minRPM: 1500, maxRPM: 1500), 1500, "Degenerate min==max returns minRPM")

    checkApprox(engine.smoothTemperature(50.0), 50.0, "First EMA sample returns raw value")
    checkApprox(engine.smoothTemperature(70.0), 55.0, "Second EMA sample applies alpha=0.25")
}

suite("TemperatureUnit — Conversion & Formatting") {
    checkApprox(TemperatureUnit.celsius.convert(0.0), 0.0, "Celsius identity at 0°C")
    checkApprox(TemperatureUnit.celsius.convert(65.5), 65.5, "Celsius identity at 65.5°C")
    checkApprox(TemperatureUnit.fahrenheit.convert(0.0), 32.0, "0°C == 32°F")
    checkApprox(TemperatureUnit.fahrenheit.convert(100.0), 212.0, "100°C == 212°F")
    checkApprox(TemperatureUnit.fahrenheit.fromCelsius(37.0), 98.6, "37°C == 98.6°F")
    check(TemperatureUnit.celsius.format(42.34, decimals: 1) == "42.3°C", "Celsius formatting")
    check(TemperatureUnit.fahrenheit.format(100.0, decimals: 0) == "212°F", "Fahrenheit formatting")
}

suite("Models — CurvePoint Clamping, Codable & FanData") {
    let low = CurvePoint(temp: -10.0, fanPercent: -50.0)
    checkApprox(low.temp, 20.0, "CurvePoint clamps low temp to 20°C")
    checkApprox(low.fanPercent, 0.0, "CurvePoint clamps low percent to 0%")

    let high = CurvePoint(temp: 150.0, fanPercent: 250.0)
    checkApprox(high.temp, 105.0, "CurvePoint clamps high temp to 105°C")
    checkApprox(high.fanPercent, 100.0, "CurvePoint clamps high percent to 100%")

    let original = [
        CurvePoint(temp: 40.0, fanPercent: 15.0),
        CurvePoint(temp: 75.0, fanPercent: 72.5)
    ]
    do {
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([CurvePoint].self, from: encoded)
        check(decoded == original, "CurvePoint JSON encode/decode round-trip preserves values")
    } catch {
        check(false, "CurvePoint JSON round-trip threw error: \(error)")
    }

    let fan = FanData(index: 0, currentRPM: 3604, minRPM: 1200, maxRPM: 6000, targetRPM: 4800)
    check(fan.name == "Fan #1", "Default fan name is 1-indexed")
    check(fan.displayRPM == 3600, "displayRPM rounds to nearest 10")
    checkApprox(fan.percentage, 50.0833, tolerance: 0.01, "FanData percentage calculation")
    checkApprox(fan.targetPercentage, 75.0, "FanData targetPercentage calculation")
}

suite("ShellEscaping — Injection Resistance (POSIX & AppleScript)") {
    let maliciousPaths = [
        "/Users/o'neil/Applications/FanControl.app",
        "/tmp/a\"b\\c/Fan Control.app",
        "/tmp/$(touch /tmp/pwned_test_file)/FanControl.app",
        "/tmp/`id`; echo pwned | cat/FanControl.app",
        "/tmp/line1\nline2\rline3/FanControl.app",
        "/tmp/simple/FanControl.app"
    ]

    for path in maliciousPaths {
        let quoted = ShellEscaping.posixSingleQuote(path)
        check(quoted.hasPrefix("'") && quoted.hasSuffix("'"), "posixSingleQuote wraps path in single quotes")

        // Prove /bin/sh evaluates the quoted argument back to the EXACT literal byte sequence with zero execution
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)
            check(process.terminationStatus == 0 && output == path, "POSIX shell receives exact literal path without injection: \(path.debugDescription)")
        } catch {
            check(false, "Failed running /bin/sh verification: \(error)")
        }

        // Verify AppleScript escaping handles backslashes, double quotes, and newlines
        let script = ShellEscaping.appleScriptDoShellScript("echo \(quoted)", administratorPrivileges: true)
        check(script.hasPrefix("do shell script \"") && script.hasSuffix("\" with administrator privileges"), "AppleScript wrapper format intact")
        check(!script.contains("\n") && !script.contains("\r"), "AppleScript literal contains no raw newlines")
    }

    // Ensure no injection side-effect file was ever created
    check(!FileManager.default.fileExists(atPath: "/tmp/pwned_test_file"), "No injected command executed")

    // Exact escaping check for quotes & backslashes in AppleScript string
    let escaped = ShellEscaping.escapeForAppleScriptString("a\\b\"c")
    check(escaped == "a\\\\b\\\"c", "AppleScript escapes backslashes before double quotes")
}

// MARK: - Summary

print("────────────────────────────────────────────────────────────")
print("Unit Test Summary: \(passedTests) passed, \(failedTests) failed")
print("────────────────────────────────────────────────────────────")

exit(failedTests == 0 ? 0 : 1)
}
}
