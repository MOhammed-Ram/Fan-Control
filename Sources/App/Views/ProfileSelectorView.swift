import SwiftUI

public struct ProfileSelectorView: View {
    @ObservedObject var manager: FanManager

    public init(manager: FanManager) {
        self.manager = manager
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Hardware Control Elevation Status Banner
            if !manager.hasHardwareControl {
                HStack(spacing: 12) {
                    Image(systemName: "shield.slash.fill")
                        .font(.title3)
                        .foregroundColor(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulation & Monitoring Mode")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("Real-time telemetry is active. To enable active fan speed adjustment, install the privileged helper tool.")
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
                        .fill(Color.orange.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                )
            }

            // Control Mode Selector
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Control Mode")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Spacer()

                    Text(manager.statusMessage)
                        .font(.caption)
                        .foregroundColor(manager.isOverheating ? .red : .secondary)
                }

                HStack(spacing: 8) {
                    ForEach(FanMode.allCases, id: \.self) { mode in
                        Button(action: { manager.setMode(mode) }) {
                            HStack(spacing: 6) {
                                Image(systemName: mode.systemIcon)
                                    .font(.caption)
                                Text(mode.rawValue)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(manager.activeMode == mode ? Color.accentColor : Color.primary.opacity(0.05))
                            )
                            .foregroundColor(manager.activeMode == mode ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Auto Mode Firmware Status Banner
            if manager.activeMode == .auto {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title3)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Native macOS Firmware In Control")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Text("App is operating in monitor-only mode. Apple hardware firmware manages all fan speeds, acoustics, and thermal profiles without app interference.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.green.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.green.opacity(0.2), lineWidth: 1)
                        )
                )
            }
            if manager.activeMode == .curve {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Curve Presets")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    HStack(spacing: 8) {
                        ForEach(ProfilePreset.allCases, id: \.self) { preset in
                            Button(action: { manager.selectPreset(preset) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: preset.icon)
                                        .font(.caption)
                                    Text(preset.rawValue)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(manager.activePreset == preset ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(manager.activePreset == preset ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                        )
                                )
                                .foregroundColor(manager.activePreset == preset ? .accentColor : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Manual Slider (when in Manual Fixed mode)
            if manager.activeMode == .manual {
                let minBound = manager.fans.first?.minRPM ?? 1200.0
                let maxBound = manager.fans.first?.maxRPM ?? 7000.0

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Target Manual Speed:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("\(Int(manager.manualRPM)) RPM")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentColor)
                    }

                    HStack(spacing: 12) {
                        Text("\(Int(minBound))")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        Slider(
                            value: $manager.manualRPM,
                            in: minBound...maxBound,
                            step: 50,
                            onEditingChanged: { _ in
                                manager.applyFanControl()
                            }
                        )

                        Text("\(Int(maxBound))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
