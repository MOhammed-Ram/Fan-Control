import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var manager: FanManager
    public var onOpenMainWindow: () -> Void
    public var onQuit: () -> Void

    public init(manager: FanManager, onOpenMainWindow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.manager = manager
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit
    }

    private var tempColor: Color {
        if manager.isOverheating || manager.thermals.cpuAvg >= 90.0 { return .red }
        if manager.thermals.cpuAvg >= 75.0 { return .orange }
        if manager.thermals.cpuAvg >= 60.0 { return .yellow }
        return .green
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Header: Live Thermals & Fans
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "cpu")
                            .font(.system(size: 13))
                            .foregroundColor(.accentColor)
                        Text(manager.menuBarTempSource == .cpuAverage ? "SoC CPU Die Average" : "SoC Peak CPU Die (Hottest Core)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", manager.currentDisplayTemp))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(tempColor)
                        Text("°C")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)

                        Spacer()

                        // Menu bar temperature source toggle
                        HStack(spacing: 2) {
                            ForEach(MenuBarTempSource.allCases) { source in
                                Button(action: {
                                    manager.menuBarTempSource = source
                                    UserDefaults.standard.set(source.rawValue, forKey: "MenuBarTempSource")
                                }) {
                                    Text(source.shortName)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5)
                                                .fill(manager.menuBarTempSource == source ? Color.accentColor : Color.primary.opacity(0.06))
                                        )
                                        .foregroundColor(manager.menuBarTempSource == source ? .white : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text("Avg: \(String(format: "%.1f", manager.thermals.cpuAvg))°C")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(manager.menuBarTempSource == .cpuAverage ? .primary : .secondary)
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text("Peak: \(String(format: "%.1f", manager.thermals.cpuPeak))°C")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(manager.menuBarTempSource == .cpuPeak ? .primary : .secondary)
                        Spacer()
                        Text(manager.thermals.pressureDescription)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(tempColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tempColor.opacity(0.12)))
                    }
                }
            }
            .padding(.horizontal, 4)

            // Fan Speed Status Pills
            HStack(spacing: 8) {
                ForEach(manager.fans) { fan in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(fan.name)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(fan.percentage))%")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }

                        Text("\(Int(fan.currentRPM)) RPM")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
            }

            Divider()

            // Control Mode Switcher in Menu Bar
            VStack(alignment: .leading, spacing: 6) {
                Text("Control Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    ForEach(FanMode.allCases, id: \.self) { mode in
                        Button(action: { manager.setMode(mode) }) {
                            VStack(spacing: 3) {
                                Image(systemName: mode.systemIcon)
                                    .font(.system(size: 11))
                                Text(mode.rawValue.replacingOccurrences(of: "macOS ", with: "").replacingOccurrences(of: " Control", with: ""))
                                    .font(.system(size: 9, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(manager.activeMode == mode ? Color.accentColor : Color.primary.opacity(0.04))
                            )
                            .foregroundColor(manager.activeMode == mode ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Curve Presets (when in Curve Control)
            if manager.activeMode == .curve {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Curve Preset")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        ForEach(ProfilePreset.allCases, id: \.self) { preset in
                            Button(action: { manager.selectPreset(preset) }) {
                                HStack(spacing: 3) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 9))
                                    Text(preset.rawValue)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(manager.activePreset == preset ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(manager.activePreset == preset ? Color.accentColor : Color.clear, lineWidth: 1)
                                        )
                                )
                                .foregroundColor(manager.activePreset == preset ? .accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Manual Slider (when in Manual Fixed)
            if manager.activeMode == .manual {
                let minBound = manager.fans.first?.minRPM ?? 1200.0
                let maxBound = manager.fans.first?.maxRPM ?? 7000.0

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Target Speed:")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(manager.manualRPM)) RPM")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }

                    Slider(
                        value: $manager.manualRPM,
                        in: minBound...maxBound,
                        step: 50,
                        onEditingChanged: { _ in
                            manager.applyFanControl()
                        }
                    )
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }

            // Hardware Elevation Warning if unprivileged
            if !manager.hasHardwareControl {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("Monitor Mode: Click to enable control")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Enable") {
                        manager.installPrivilegedHelper()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            }

            Divider()

            // Footer Action Buttons
            HStack {
                Button(action: onOpenMainWindow) {
                    Label("Curve Editor...", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
