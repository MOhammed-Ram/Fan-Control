import SwiftUI

public struct TelemetryDashboard: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Top Row: Thermal Metrics + Fan Gauges
            HStack(alignment: .top, spacing: 16) {
                // Left: SoC Thermal Overview
                ThermalsCard(thermals: manager.thermals, isOverheating: manager.isOverheating, tempHistory: manager.tempHistory)

                // Right: Fan Gauges
                if manager.fans.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "fanblades.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Fans Detected or Passively Cooled")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
                } else {
                    HStack(spacing: 12) {
                        ForEach(manager.fans) { fan in
                            FanGaugeCard(fan: fan, activeMode: manager.activeMode)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Thermals Card
private struct ThermalsCard: View {
    let thermals: ThermalData
    let isOverheating: Bool
    let tempHistory: [Double]

    private var tempColor: Color {
        if isOverheating || thermals.cpuAvg >= 90.0 { return .red }
        if thermals.cpuAvg >= 75.0 { return .orange }
        if thermals.cpuAvg >= 60.0 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card Title & Pressure Badge
            HStack {
                Label("SoC Thermals", systemImage: "cpu")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(tempColor)
                        .frame(width: 8, height: 8)
                    Text(thermals.pressureDescription)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundColor(tempColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(tempColor.opacity(0.12))
                )
            }

            // Big Temperature Display
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", thermals.cpuAvg))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundColor(tempColor)

                Text("°C")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                Spacer()

                // Mini Sparkline Graph
                SparklineView(data: tempHistory, color: tempColor)
                    .frame(width: 80, height: 36)
            }

            Divider()

            // Sub-sensors row: Peak, Battery, SSD
            HStack(spacing: 16) {
                SensorMiniPill(title: "Peak Die", value: String(format: "%.1f°C", thermals.cpuPeak), icon: "flame.fill", color: .orange)
                SensorMiniPill(title: "Battery", value: String(format: "%.1f°C", thermals.battery), icon: "battery.100.bolt", color: .blue)
                SensorMiniPill(title: "Storage", value: String(format: "%.1f°C", thermals.storage), icon: "internaldrive", color: .purple)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Sensor Mini Pill
private struct SensorMiniPill: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(color)
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Fan Gauge Card
private struct FanGaugeCard: View {
    let fan: FanData
    let activeMode: FanMode

    private var fanSpeedColor: Color {
        let pct = fan.percentage
        if pct >= 80 { return .red }
        if pct >= 50 { return .orange }
        if pct >= 25 { return .cyan }
        return .blue
    }

    var body: some View {
        VStack(spacing: 10) {
            // Fan Header
            HStack {
                Text(fan.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(Int(fan.percentage))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(fanSpeedColor)
            }

            // Radial Gauge
            ZStack {
                // Background Track
                Circle()
                    .trim(from: 0.15, to: 0.85)
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(90))

                // Active Progress Track
                Circle()
                    .trim(from: 0.15, to: 0.15 + (0.70 * (fan.percentage / 100.0)))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.cyan, .blue, .orange, .red]),
                            center: .center,
                            startAngle: .degrees(90),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
                    .animation(.easeInOut(duration: 0.5), value: fan.percentage)

                // Center RPM Readout
                VStack(spacing: 2) {
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 16))
                        .foregroundColor(fanSpeedColor)

                    Text("\(fan.displayRPM)")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)

                    Text("RPM")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 104, height: 104)

            // Target & Range Footer
            VStack(spacing: 2) {
                if fan.targetRPM > 0 {
                    Text("Target: \(Int(fan.targetRPM)) RPM")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("Range: \(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Sparkline View
private struct SparklineView: View {
    let data: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            if data.count > 1 {
                let minVal = (data.min() ?? 30.0) - 2.0
                let maxVal = (data.max() ?? 80.0) + 2.0
                let range = max(1.0, maxVal - minVal)

                Path { path in
                    for (i, val) in data.enumerated() {
                        let x = CGFloat(i) / CGFloat(data.count - 1) * geo.size.width
                        let y = geo.size.height - CGFloat((val - minVal) / range) * geo.size.height
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 2)
            }
        }
    }
}
