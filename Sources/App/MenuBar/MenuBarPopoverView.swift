import SwiftUI

public struct MenuBarPopoverView: View {
    @ObservedObject var manager: FanManager
    public var onOpenMainWindow: () -> Void
    public var onOpenAbout: () -> Void
    public var onQuit: () -> Void

    public init(
        manager: FanManager,
        onOpenMainWindow: @escaping () -> Void,
        onOpenAbout: @escaping () -> Void = {},
        onQuit: @escaping () -> Void
    ) {
        self.manager = manager
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenAbout = onOpenAbout
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
            VStack(alignment: .leading, spacing: 6) {
                // Row 1: Sensor Title + Thermal Pressure Pill
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "cpu")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text(manager.menuBarTempSource.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(tempColor)
                            .frame(width: 6, height: 6)
                        Text(manager.thermals.pressureDescription)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(tempColor)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(tempColor.opacity(0.14)))
                    .fixedSize(horizontal: true, vertical: false)
                }

                // Row 2: Big Temperature Readout + Source Switcher Pills
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.1f", manager.displayTempValue(manager.currentDisplayTemp)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(tempColor)
                    Text(manager.tempUnitSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    Spacer()

                    // Menu bar temperature source toggle
                    HStack(spacing: 3) {
                        ForEach(MenuBarTempSource.allCases) { source in
                            let isSelected = (manager.menuBarTempSource == source)
                            Button(action: {
                                manager.menuBarTempSource = source
                                UserDefaults.standard.set(true, forKey: "UserExplicitlySetMenuBarTempSource")
                                manager.saveSettings()
                            }) {
                                Text(source.shortName)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
                                    )
                                    .foregroundColor(isSelected ? .white : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Row 3: Full-width Secondary Sensor Readouts (never truncated)
                HStack(spacing: 6) {
                    Text("Avg: \(manager.formatTemp(manager.thermals.cpuAvg))")
                        .font(.system(size: 10.5, weight: manager.menuBarTempSource == .cpuAverage ? .semibold : .medium, design: .monospaced))
                        .foregroundColor(manager.menuBarTempSource == .cpuAverage ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))

                    Text("Peak: \(manager.formatTemp(manager.thermals.cpuPeak))")
                        .font(.system(size: 10.5, weight: manager.menuBarTempSource == .cpuPeak ? .semibold : .medium, design: .monospaced))
                        .foregroundColor(manager.menuBarTempSource == .cpuPeak ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("•")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))

                    Text("GPU: \(manager.formatTemp(manager.thermals.gpu))")
                        .font(.system(size: 10.5, weight: manager.menuBarTempSource == .gpuDie ? .semibold : .medium, design: .monospaced))
                        .foregroundColor(manager.menuBarTempSource == .gpuDie ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 2)

            // Fan Speed Status Pills
            HStack(spacing: 8) {
                ForEach(manager.fans) { fan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(fan.name)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(fan.percentage))%")
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }

                        Text("\(fan.displayRPM) RPM")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }

            Divider()

            // Control Mode Switcher in Menu Bar
            VStack(alignment: .leading, spacing: 6) {
                Text("Control Mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 5) {
                    ForEach(FanMode.allCases, id: \.self) { mode in
                        let isSelected = (manager.activeMode == mode)
                        Button(action: { manager.setMode(mode) }) {
                            VStack(spacing: 4) {
                                Image(systemName: mode.systemIcon)
                                    .font(.system(size: 11.5, weight: .semibold))
                                Text(mode.rawValue.replacingOccurrences(of: "macOS ", with: "").replacingOccurrences(of: " Control", with: ""))
                                    .font(.system(size: 9.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.05))
                            )
                            .foregroundColor(isSelected ? .white : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // macOS Firmware Note when in Auto Mode
            if manager.activeMode == .auto {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("macOS Firmware retains exclusive fan control.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            }

            // Curve Presets (when in Curve Control)
            if manager.activeMode == .curve {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Curve Preset")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    HStack(spacing: 5) {
                        ForEach(ProfilePreset.allCases) { preset in
                            let isSelected = (manager.activePreset == preset)
                            Button(action: { manager.selectPreset(preset) }) {
                                VStack(spacing: 3) {
                                    Image(systemName: preset.icon)
                                        .font(.system(size: 10.5, weight: .semibold))
                                    Text(preset.rawValue)
                                        .font(.system(size: 9.5, weight: .medium))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7)
                                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.2)
                                        )
                                )
                                .foregroundColor(isSelected ? .accentColor : .primary)
                                .contentShape(Rectangle())
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

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(manager.linkFans || manager.fans.count < 2 ? "Target Speed:" : "Left Fan (CPU):")
                            .font(.system(size: 10.5))
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
                            if manager.linkFans { manager.manualRPMRight = manager.manualRPM }
                            manager.saveSettings()
                            manager.applyFanControl()
                        }
                    )

                    if !manager.linkFans && manager.fans.count >= 2 {
                        let minRight = manager.fans[1].minRPM
                        let maxRight = manager.fans[1].maxRPM
                        HStack {
                            Text("Right Fan (GPU):")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(manager.manualRPMRight)) RPM")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }

                        Slider(
                            value: $manager.manualRPMRight,
                            in: minRight...maxRight,
                            step: 50,
                            onEditingChanged: { _ in
                                manager.saveSettings()
                                manager.applyFanControl()
                            }
                        )
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }

            // Hardware Elevation Warning if unprivileged
            if !manager.hasHardwareControl {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                    Text("Monitor Mode: Enable hardware control")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Enable") {
                        manager.installPrivilegedHelper()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
            }

            Divider()

            // Footer Action Buttons
            HStack(spacing: 10) {
                Button(action: onOpenMainWindow) {
                    Label("Curve Editor...", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onOpenAbout) {
                    Label("About", systemImage: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(action: onQuit) {
                    Text("Quit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
