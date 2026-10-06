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

    public var body: some View {
        VStack(spacing: 16) {
            // Speed Readout
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manual Target Fan Speed")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Fans are commanded to hold this constant speed continuously.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(manager.manualRPM))")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("RPM")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Continuous Slider with Steppers
            HStack(spacing: 14) {
                Button(action: {
                    manager.manualRPM = max(minBound, manager.manualRPM - 50.0)
                    manager.applyFanControl()
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                VStack(spacing: 4) {
                    Slider(
                        value: $manager.manualRPM,
                        in: minBound...maxBound,
                        step: 50,
                        onEditingChanged: { _ in
                            manager.applyFanControl()
                        }
                    )
                    .tint(.orange)

                    HStack {
                        Text("\(Int(minBound)) RPM")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(maxBound)) RPM")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: {
                    manager.manualRPM = min(maxBound, manager.manualRPM + 50.0)
                    manager.applyFanControl()
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
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
                        manager.applyFanControl()
                    }) {
                        Text(p.label)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 3) {
                    Text("macOS Firmware Managing Fan Acoustics")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Operating in strict read-only monitor mode. Apple Silicon firmware has exclusive, unhindered control over fan speed and thermal acoustics.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: {
                    withAnimation {
                        manager.setMode(.curve)
                    }
                }) {
                    Label("Switch to Curve Control", systemImage: "waveform.path.ecg")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            Divider()

            HStack(spacing: 20) {
                Label("Zero app interference", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("Hardware safety guaranteed", systemImage: "shield.checkered")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("Real-time telemetry active", systemImage: "chart.xyaxis.line")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.green.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
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
        HStack(spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 32))
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: 3) {
                Text("Emergency 100% Turbo Cooling Active")
                    .font(.headline)
                    .foregroundColor(.primary)
                Text("Fans are commanded to maximum hardware RPM for emergency heat dissipation.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                withAnimation {
                    manager.setMode(.auto)
                }
            }) {
                Text("Restore macOS Auto")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
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
