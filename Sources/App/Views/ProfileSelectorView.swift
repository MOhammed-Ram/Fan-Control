import SwiftUI

// MARK: - Control Mode Selector Bar (Prominent Top-Level Mode Navigation)
public struct ControlModeSelector: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Fan Operating Mode", systemImage: "slider.horizontal.2.square")
                    .font(.headline)
                    .foregroundColor(.primary)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 7, height: 7)
                    Text(manager.statusMessage)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(manager.isOverheating ? .red : .secondary)
                }
            }

            // Mode Selector Buttons
            HStack(spacing: 8) {
                ForEach(FanMode.allCases, id: \.self) { mode in
                    let isSelected = (manager.activeMode == mode)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            manager.setMode(mode)
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: mode.systemIcon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(mode.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? modeColor(mode) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .white : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var statusIndicatorColor: Color {
        if manager.isOverheating { return .red }
        switch manager.activeMode {
        case .auto: return .green
        case .curve: return .blue
        case .manual: return .orange
        case .turbo: return .red
        }
    }

    private func modeColor(_ mode: FanMode) -> Color {
        switch mode {
        case .auto: return .accentColor
        case .curve: return .blue
        case .manual: return .orange
        case .turbo: return .red
        }
    }
}

// MARK: - Curve Presets Selector Bar
public struct CurvePresetsBar: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("Presets:")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(ProfilePreset.allCases, id: \.self) { preset in
                let isSelected = (manager.activePreset == preset)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        manager.selectPreset(preset)
                    }
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: preset.icon)
                            .font(.system(size: 11))
                        Text(preset.rawValue)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .foregroundColor(isSelected ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
    }
}

// MARK: - Manual Fixed Control Panel
public struct ManualControlPanel: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    private var minBound: Double { manager.fans.first?.minRPM ?? 1200.0 }
    private var maxBound: Double { manager.fans.first?.maxRPM ?? 7000.0 }
    private var minBoundRight: Double { (manager.fans.count > 1 ? manager.fans[1].minRPM : nil) ?? minBound }
    private var maxBoundRight: Double { (manager.fans.count > 1 ? manager.fans[1].maxRPM : nil) ?? maxBound }

    public var body: some View {
        VStack(spacing: 10) {
            // Speed Readout & Quick Jumps Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.linkFans || manager.fans.count < 2 ? "Manual Target Fan Speed" : "Independent Left & Right Fan Speeds")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(manager.linkFans || manager.fans.count < 2
                         ? "Fans are commanded to hold this constant speed continuously."
                         : "Left and Right fans are controlled independently.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if manager.linkFans || manager.fans.count < 2 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(manager.manualRPM))")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("RPM")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("L:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(manager.manualRPM))")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                            Text("RPM")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("R:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(Int(manager.manualRPMRight))")
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange)
                            Text("RPM")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if manager.linkFans || manager.fans.count < 2 {
                // Synchronized Continuous Slider with Steppers
                HStack(spacing: 12) {
                    Button(action: {
                        manager.manualRPM = max(minBound, manager.manualRPM - 50.0)
                        manager.manualRPMRight = manager.manualRPM
                        manager.saveSettings()
                        manager.applyFanControl()
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 3) {
                        Slider(
                            value: $manager.manualRPM,
                            in: minBound...maxBound,
                            step: 50,
                            onEditingChanged: { editing in
                                manager.manualRPMRight = manager.manualRPM
                                if !editing { manager.saveSettings() }
                                manager.applyFanControl()
                            }
                        )
                        .tint(.orange)

                        HStack {
                            Text("\(Int(minBound)) RPM")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(maxBound)) RPM")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Button(action: {
                        manager.manualRPM = min(maxBound, manager.manualRPM + 50.0)
                        manager.manualRPMRight = manager.manualRPM
                        manager.saveSettings()
                        manager.applyFanControl()
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Side-by-side Left & Right Sliders (preserves fixed window height)
                HStack(spacing: 18) {
                    VStack(spacing: 3) {
                        Slider(
                            value: $manager.manualRPM,
                            in: minBound...maxBound,
                            step: 50,
                            onEditingChanged: { editing in
                                if !editing { manager.saveSettings() }
                                manager.applyFanControl()
                            }
                        )
                        .tint(.orange)
                        HStack {
                            Text("Left (\(Int(minBound))–\(Int(maxBound)))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }

                    VStack(spacing: 3) {
                        Slider(
                            value: $manager.manualRPMRight,
                            in: minBoundRight...maxBoundRight,
                            step: 50,
                            onEditingChanged: { editing in
                                if !editing { manager.saveSettings() }
                                manager.applyFanControl()
                            }
                        )
                        .tint(.orange)
                        HStack {
                            Text("Right (\(Int(minBoundRight))–\(Int(maxBoundRight)))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
            }

            // Quick Jump Preset Pills
            HStack(spacing: 8) {
                Text("Quick Jumps:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                let presets: [(label: String, rpm: Double)] = [
                    ("Min (Quiet)", minBound),
                    ("3,500 RPM", 3500.0),
                    ("5,000 RPM", 5000.0),
                    ("Max (100%)", maxBound)
                ]

                ForEach(presets, id: \.label) { p in
                    Button(action: {
                        manager.manualRPM = max(minBound, min(maxBound, p.rpm))
                        manager.manualRPMRight = max(minBoundRight, min(maxBoundRight, p.rpm))
                        manager.saveSettings()
                        manager.applyFanControl()
                    }) {
                        Text(p.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - macOS Auto Firmware Status Panel
public struct AutoStatusPanel: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS Firmware Managing Fan Acoustics")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text("Operating in strict read-only monitor mode. Apple Silicon firmware has exclusive control.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    withAnimation {
                        manager.setMode(.curve)
                    }
                }) {
                    Label("Switch to Curve Control", systemImage: "waveform.path.ecg")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 16) {
                Label("Zero app interference", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label("Hardware safety guaranteed", systemImage: "shield.checkered")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label("Real-time telemetry active", systemImage: "chart.xyaxis.line")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Turbo Mode Status Panel
public struct TurboStatusPanel: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 22))
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("Emergency 100% Turbo Cooling Active")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text("Fans commanded to maximum hardware RPM for maximum heat dissipation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                withAnimation {
                    manager.setMode(.auto)
                }
            }) {
                Text("Restore macOS Auto")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.red.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

// MARK: - Privileged Helper Status Banner
public struct PrivilegedHelperBanner: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.slash.fill")
                .font(.title2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Simulation & Monitoring Mode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text("Hardware fan speed adjustment requires installing the privileged helper tool.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { manager.installPrivilegedHelper() }) {
                Label("Enable Control", systemImage: "lock.open.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
        )
    }
}

// MARK: - Legacy Wrapper for Backwards Compatibility
public struct ProfileSelectorView: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        ControlModeSelector(manager: manager)
    }
}
