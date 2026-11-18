import Foundation

public final class CurveEngine {
    public var hysteresisBand: Double = 2.0 // Degrees Celsius before lowering speed
    public var criticalThreshold: Double = 100.0 // Emergency 100% threshold
    public var emaAlpha: Double = 0.25 // Exponential Moving Average smoothing factor

    private var lastCommandedPercent: Double = 0.0
    private var lastEffectiveTemp: Double = 40.0
    private var smoothedTemp: Double? = nil

    public init(hysteresisBand: Double = 2.0, criticalThreshold: Double = 100.0, emaAlpha: Double = 0.25) {
        self.hysteresisBand = hysteresisBand
        self.criticalThreshold = criticalThreshold
        self.emaAlpha = emaAlpha
    }

    /// Smooths raw temperature fluctuations using Exponential Moving Average to prevent sudden jitter
    public func smoothTemperature(_ rawTemp: Double) -> Double {
        guard let current = smoothedTemp else {
            smoothedTemp = rawTemp
            return rawTemp
        }
        let smoothed = (emaAlpha * rawTemp) + ((1.0 - emaAlpha) * current)
        smoothedTemp = smoothed
        return smoothed
    }

    public func resetSmoothing() {
        smoothedTemp = nil
        lastEffectiveTemp = 40.0
    }

    /// Rate-limits the change in RPM to ensure silky, continuous acoustic transitions
    public static func slewLimit(current: Double, target: Double, maxIncrease: Double, maxDecrease: Double) -> Double {
        if target > current {
            return min(target, current + maxIncrease)
        } else if target < current {
            return max(target, current - maxDecrease)
        }
        return target
    }

    /// Evaluates the target fan percentage (0..100) for a given temperature using the provided curve points.
    public func evaluate(temp: Double, points: [CurvePoint], useHysteresis: Bool = true) -> Double {
        // Critical emergency safety override (only when hysteresis/control is active)
        if useHysteresis && temp >= criticalThreshold {
            lastCommandedPercent = 100.0
            lastEffectiveTemp = temp
            return 100.0
        }

        // Apply hysteresis: if temp is dropping within the hysteresis band, don't drop fan speed yet
        var effectiveTemp = temp
        if useHysteresis {
            if temp < lastEffectiveTemp && (lastEffectiveTemp - temp) < hysteresisBand {
                effectiveTemp = lastEffectiveTemp
            } else {
                lastEffectiveTemp = temp
            }
        }

        let sorted = points.sorted { $0.temp < $1.temp }
        guard !sorted.isEmpty else { return 50.0 }

        if effectiveTemp <= sorted.first!.temp {
            let p = sorted.first!.fanPercent
            lastCommandedPercent = p
            return p
        }

        if effectiveTemp >= sorted.last!.temp {
            let p = sorted.last!.fanPercent
            lastCommandedPercent = p
            return p
        }

        // Find enclosing segment for Catmull-Rom or linear interpolation
        var calculatedPercent = sorted.first!.fanPercent
        for i in 0..<(sorted.count - 1) {
            let p0 = sorted[max(0, i - 1)]
            let p1 = sorted[i]
            let p2 = sorted[i + 1]
            let p3 = sorted[min(sorted.count - 1, i + 2)]

            if effectiveTemp >= p1.temp && effectiveTemp <= p2.temp {
                let segmentRange = p2.temp - p1.temp
                if segmentRange <= 0.001 {
                    calculatedPercent = p1.fanPercent
                } else {
                    let t = (effectiveTemp - p1.temp) / segmentRange
                    // Monotonic Catmull-Rom spline interpolation (prevents overshoot/dips between points)
                    let val = catmullRom(p0: p0.fanPercent, p1: p1.fanPercent, p2: p2.fanPercent, p3: p3.fanPercent, t: t)
                    let segMin = max(0.0, min(p1.fanPercent, p2.fanPercent))
                    let segMax = min(100.0, max(p1.fanPercent, p2.fanPercent))
                    calculatedPercent = max(segMin, min(segMax, val))
                }
                break
            }
        }

        lastCommandedPercent = calculatedPercent
        return calculatedPercent
    }

    /// Converts fan percentage (0..100) to actual RPM within the fan's physical bounds
    public func percentToRPM(percent: Double, minRPM: Double, maxRPM: Double) -> Double {
        guard maxRPM > minRPM else { return minRPM }
        let clampedPercent = max(0.0, min(100.0, percent))
        return minRPM + (maxRPM - minRPM) * (clampedPercent / 100.0)
    }

    /// Catmull-Rom spline formulation for smooth curve transitions
    private func catmullRom(p0: Double, p1: Double, p2: Double, p3: Double, t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2.0 * p1) +
            (-p0 + p2) * t +
            (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
            (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
        )
    }

    /// Evaluates the exact mathematical point on the curve line without hysteresis (used for chart rendering)
    public static func evaluateOnCurve(temp: Double, points: [CurvePoint]) -> Double {
        let engine = CurveEngine(hysteresisBand: 0.0, criticalThreshold: 110.0, emaAlpha: 1.0)
        return engine.evaluate(temp: temp, points: points, useHysteresis: false)
    }

    /// Generates sample points for rendering a smooth curve on the canvas
    public static func sampleCurve(points: [CurvePoint], minTemp: Double = 30.0, maxTemp: Double = 100.0, steps: Int = 100) -> [(temp: Double, percent: Double)] {
        var samples: [(temp: Double, percent: Double)] = []
        let stepSize = (maxTemp - minTemp) / Double(steps)

        for i in 0...steps {
            let t = minTemp + Double(i) * stepSize
            let p = evaluateOnCurve(temp: t, points: points)
            samples.append((temp: t, percent: p))
        }
        return samples
    }

    private convenience init(useHysteresis: Bool) {
        self.init()
    }
}
