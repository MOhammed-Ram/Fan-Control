import SwiftUI

public struct SettingsSheetView: View {
    @ObservedObject var manager: FanManager
    public var onDismiss: () -> Void

    public init(manager: FanManager, onDismiss: @escaping () -> Void) {
        self.manager = manager
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Text("Preferences & Safety Guards")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Safety Section
                    GroupBox(label: Label("Thermal Safety Failsafes", systemImage: "shield.lefthalf.filled")) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Emergency Overheat Threshold:")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(manager.criticalThreshold))°C")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.red)
                                }
                                Text("If any SoC die exceeds this temperature, fans will immediately ramp to 100% full blast regardless of the active curve.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.criticalThreshold },
                                        set: { manager.criticalThreshold = $0 }
                                    ),
                                    in: 80...100,
                                    step: 1
                                )
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Hysteresis Deadband:")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.1f°C", manager.hysteresisBand))
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                }
                                Text("Prevents fan RPM flutter and oscillation by delaying fan spin-down until temperatures drop by at least this amount.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.hysteresisBand },
                                        set: { manager.hysteresisBand = $0 }
                                    ),
                                    in: 0.5...5.0,
                                    step: 0.5
                                )
                            }
                        }
                        .padding(8)
                    }

                    // Hardware & Fan Synchronization
                    GroupBox(label: Label("Fan Behavior", systemImage: "fanblades")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Synchronize Left & Right Fans", isOn: Binding(
                                get: { manager.linkFans },
                                set: { manager.linkFans = $0 }
                            ))
                            .font(.subheadline)

                            Text("When enabled, both fans maintain synchronized speed based on the higher SoC temperature reading.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                    }

                    // Menu Bar Temperature Configuration
                    GroupBox(label: Label("Menu Bar Display", systemImage: "menubar.dock.rectangle")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Primary Status Bar Temperature Metric:")
                                .font(.subheadline)

                            Picker("", selection: Binding(
                                get: { manager.menuBarTempSource },
                                set: {
                                    manager.menuBarTempSource = $0
                                    UserDefaults.standard.set($0.rawValue, forKey: "MenuBarTempSource")
                                }
                            )) {
                                ForEach(MenuBarTempSource.allCases) { source in
                                    Text(source.rawValue).tag(source)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text("• CPU Core Average: Computed across all Performance & Efficiency CPU core die sensors.\n• Peak CPU Core: The single hottest core die reading at any moment.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Status Bar Fan Speed Layout:")
                                .font(.subheadline)

                            Picker("", selection: Binding(
                                get: { manager.menuBarLayoutStyle },
                                set: {
                                    manager.menuBarLayoutStyle = $0
                                    UserDefaults.standard.set($0.rawValue, forKey: "MenuBarLayoutStyle")
                                }
                            )) {
                                ForEach(MenuBarLayoutStyle.allCases) { layout in
                                    Text(layout.rawValue).tag(layout)
                                }
                            }
                            .pickerStyle(.radioGroup)
                        }
                        .padding(8)
                    }

                    // Privileged Helper Section
                    GroupBox(label: Label("Privileged Hardware Control", systemImage: "lock.shield")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Status:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                if manager.hasHardwareControl {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.green).frame(width: 8, height: 8)
                                        Text(manager.isDirectRoot ? "Direct Root" : "Privileged Helper Connected")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.green)
                                    }
                                } else {
                                    HStack(spacing: 4) {
                                        Circle().fill(Color.orange).frame(width: 8, height: 8)
                                        Text("Helper Inactive (Monitor Mode)")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }

                            if !manager.hasHardwareControl {
                                Button(action: { manager.installPrivilegedHelper() }) {
                                    Label("Install / Activate Helper Tool", systemImage: "arrow.down.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                        .padding(8)
                    }

                    // Hardware Architecture Info
                    GroupBox(label: Label("Hardware & Substrate Diagnostics", systemImage: "info.circle")) {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(title: "Architecture", value: "Apple Silicon (arm64)")
                            InfoRow(title: "SMC Substrate", value: "AppleSMC (IOKit direct, 80-byte param struct)")
                            InfoRow(title: "Control Handshake", value: "Ftst diagnostic force mode + F0md manual lock")
                            InfoRow(title: "Thermal Sensors", value: "\(sensors_get_count()) active IOHID sensors")
                            InfoRow(title: "Fan Count", value: "\(manager.fans.count) controllable hardware fans")
                        }
                        .padding(8)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 500)
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}
