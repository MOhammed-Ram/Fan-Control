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
                                    Text(manager.formatTemp(manager.criticalThreshold, decimals: 0))
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.red)
                                }
                                Text("When Curve or Manual mode is active, if any SoC die exceeds this temperature, fans immediately ramp to 100% full blast and send a macOS alert notification.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.criticalThreshold },
                                        set: {
                                            manager.criticalThreshold = $0
                                            manager.saveSettings()
                                        }
                                    ),
                                    in: 90...105,
                                    step: 1
                                )
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Fan Curve Driving Metric:")
                                    .font(.subheadline)

                                Picker("", selection: Binding(
                                    get: { manager.curveTempSource },
                                    set: {
                                        manager.curveTempSource = $0
                                        manager.saveSettings()
                                    }
                                )) {
                                    ForEach(CurveTempSource.allCases) { source in
                                        Text(source.shortName).tag(source)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text("• CPU Avg: Smooth, progressive ramp based on bulk CPU thermal mass.\n• CPU+GPU: Driven by whichever processor subsystem is hotter.\n• CPU Peak: Reacts immediately to single-core bursts.\n• GPU: Driven exclusively by Apple Silicon GPU die temperature.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
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
                                        set: {
                                            manager.hysteresisBand = $0
                                            manager.saveSettings()
                                        }
                                    ),
                                    in: 0.5...5.0,
                                    step: 0.5
                                )
                            }
                        }
                        .padding(8)
                    }

                    // Notifications & Alerts Section
                    GroupBox(label: Label("Notifications & Alerts", systemImage: "bell.badge.fill")) {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Enable Thermal Emergency Notifications", isOn: Binding(
                                    get: { manager.enableOverheatNotifications },
                                    set: {
                                        manager.enableOverheatNotifications = $0
                                        manager.saveSettings()
                                        if $0 { manager.requestNotificationPermissionIfNeeded() }
                                    }
                                ))
                                .font(.subheadline)
                                Text("Sends a macOS notification banner if sustained SoC temperatures exceed the emergency overheat threshold.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Notify on Battery / Power Adapter Profile Switch", isOn: Binding(
                                    get: { manager.enablePowerSwitchNotifications },
                                    set: {
                                        manager.enablePowerSwitchNotifications = $0
                                        manager.saveSettings()
                                        if $0 { manager.requestNotificationPermissionIfNeeded() }
                                    }
                                ))
                                .font(.subheadline)
                                Text("Sends a notification when the fan curve preset automatically changes between Battery and AC Power Adapter.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            Toggle("Play Alert Sound with Notifications", isOn: Binding(
                                get: { manager.enableNotificationSound },
                                set: {
                                    manager.enableNotificationSound = $0
                                    manager.saveSettings()
                                }
                            ))
                            .font(.subheadline)

                            HStack(spacing: 10) {
                                Button(action: { manager.sendTestNotification() }) {
                                    Label("Send Test Notification", systemImage: "paperplane.fill")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(action: { manager.openSystemNotificationSettings() }) {
                                    Label("macOS Notification Settings...", systemImage: "gear")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Spacer()
                            }
                        }
                        .padding(8)
                    }

                    // Acoustic Smoothing & Fan Ramping
                    GroupBox(label: Label("Acoustic Smoothing & Fan Ramping", systemImage: "waveform.path")) {
                        VStack(alignment: .leading, spacing: 14) {
                            // Acceleration Slew Rate
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Acceleration Slew Limit (Ramp Up):")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(manager.rampUpRate)) RPM/s")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                }
                                Text("Caps maximum fan acceleration rate. Prevents abrupt, audible spin-up revs during quick CPU spikes.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.rampUpRate },
                                        set: {
                                            manager.rampUpRate = $0
                                            manager.saveSettings()
                                        }
                                    ),
                                    in: 30...400,
                                    step: 10
                                )
                            }

                            Divider()

                            // Deceleration Slew Rate
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Deceleration Slew Limit (Ramp Down):")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(manager.rampDownRate)) RPM/s")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                }
                                Text("Caps maximum fan deceleration rate. Ensures fans spin down smoothly and quietly when workload drops.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.rampDownRate },
                                        set: {
                                            manager.rampDownRate = $0
                                            manager.saveSettings()
                                        }
                                    ),
                                    in: 20...200,
                                    step: 10
                                )
                            }

                            Divider()

                            // Thermal Spike EMA Factor
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Thermal Filter Smoothing (EMA Alpha):")
                                        .font(.subheadline)
                                    Spacer()
                                    Text(String(format: "%.2f", manager.tempSmoothingAlpha))
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(.accentColor)
                                }
                                Text("Exponential Moving Average filter applied to temperatures. Lower values filter noisy spikes; higher values react faster.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Slider(
                                    value: Binding(
                                        get: { manager.tempSmoothingAlpha },
                                        set: {
                                            manager.tempSmoothingAlpha = $0
                                            manager.saveSettings()
                                        }
                                    ),
                                    in: 0.10...0.80,
                                    step: 0.05
                                )
                            }
                        }
                        .padding(8)
                    }

                    // Hardware, Fan Synchronization & Power Adapter Automation
                    GroupBox(label: Label("Fan Behavior & Power Automation", systemImage: "fanblades")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Synchronize Left & Right Fans", isOn: Binding(
                                get: { manager.linkFans },
                                set: {
                                    manager.linkFans = $0
                                    if $0 { manager.manualRPMRight = manager.manualRPM }
                                    manager.saveSettings()
                                    manager.applyFanControl()
                                }
                            ))
                            .font(.subheadline)

                            Text("When enabled, both fans run at synchronized speeds. When disabled, Left Fan tracks CPU thermals while Right Fan tracks GPU thermals in Curve mode, and independent Left/Right sliders are unlocked in Manual mode.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Toggle("Automatically Switch Curve Preset on Battery vs. Power Adapter", isOn: Binding(
                                get: { manager.autoSwitchPowerProfile },
                                set: {
                                    manager.autoSwitchPowerProfile = $0
                                    manager.saveSettings()
                                }
                            ))
                            .font(.subheadline)

                            if manager.autoSwitchPowerProfile {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("On Battery Power:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Picker("", selection: Binding(
                                            get: { manager.batteryPreset },
                                            set: {
                                                manager.batteryPreset = $0
                                                manager.saveSettings()
                                                if manager.isOnBattery { manager.selectPreset($0) }
                                            }
                                        )) {
                                            ForEach(ProfilePreset.allCases) { preset in
                                                Text(preset.rawValue).tag(preset)
                                            }
                                        }
                                        .labelsHidden()
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("On AC Power Adapter:")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Picker("", selection: Binding(
                                            get: { manager.acPreset },
                                            set: {
                                                manager.acPreset = $0
                                                manager.saveSettings()
                                                if !manager.isOnBattery { manager.selectPreset($0) }
                                            }
                                        )) {
                                            ForEach(ProfilePreset.allCases) { preset in
                                                Text(preset.rawValue).tag(preset)
                                            }
                                        }
                                        .labelsHidden()
                                    }
                                }
                            }
                        }
                        .padding(8)
                    }

                    // Menu Bar & Units Configuration
                    GroupBox(label: Label("Menu Bar & Display Units", systemImage: "menubar.dock.rectangle")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Temperature Display Unit:")
                                    .font(.subheadline)
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { manager.temperatureUnit },
                                    set: {
                                        manager.temperatureUnit = $0
                                        manager.saveSettings()
                                    }
                                )) {
                                    ForEach(TemperatureUnit.allCases) { unit in
                                        Text(unit.rawValue).tag(unit)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 230)
                            }

                            Divider()

                            Text("Primary Status Bar Temperature Metric:")
                                .font(.subheadline)

                            Picker("", selection: Binding(
                                get: { manager.menuBarTempSource },
                                set: {
                                    manager.menuBarTempSource = $0
                                    UserDefaults.standard.set(true, forKey: "UserExplicitlySetMenuBarTempSource")
                                    manager.saveSettings()
                                }
                            )) {
                                Text("CPU Core Average").tag(MenuBarTempSource.cpuAverage)
                                Text("Peak CPU Core").tag(MenuBarTempSource.cpuPeak)
                                Text("GPU Die").tag(MenuBarTempSource.gpuDie)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()

                            Text("• CPU Core Average: Computed across all CPU core die sensors.\n• Peak CPU Core: The single hottest CPU core die reading.\n• GPU Die: Apple Silicon GPU die temperature.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Divider()

                            Text("Status Bar Fan Speed Layout:")
                                .font(.subheadline)

                            Picker("", selection: Binding(
                                get: { manager.menuBarLayoutStyle },
                                set: {
                                    manager.menuBarLayoutStyle = $0
                                    manager.saveSettings()
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

                    // Background & System Integration Section
                    GroupBox(label: Label("Background Execution & Installation", systemImage: "macwindow.and.cursorarrow")) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Launch at Login
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Launch at Login (Start with macOS)", isOn: Binding(
                                    get: { manager.startAtLogin },
                                    set: { manager.setStartAtLogin($0) }
                                ))
                                .font(.subheadline)
                                Text("Automatically launches Fan Control in the background on system boot and user login.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            // Run as Menu Bar Only (Hide Dock Icon)
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Run in Background (Hide Dock Icon)", isOn: Binding(
                                    get: { manager.runAsMenuBarOnly },
                                    set: { manager.setRunAsMenuBarOnly($0) }
                                ))
                                .font(.subheadline)
                                Text("Hides the Dock icon so the app runs purely in the Menu Bar. The Curve Editor can still be opened anytime from the Menu Bar.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            // Start Minimized
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle("Start Minimized / Silent Launch", isOn: Binding(
                                    get: { manager.startMinimized },
                                    set: { manager.setStartMinimized($0) }
                                ))
                                .font(.subheadline)
                                Text("When launching on login or startup, only the Menu Bar monitor appears without showing the large editor window.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Divider()

                            // Installation Status & Move to /Applications
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Application Location:")
                                        .font(.subheadline)
                                    Text(manager.isInstalledInApplications ? "Installed in /Applications" : "Running from \(Bundle.main.bundleURL.lastPathComponent)")
                                        .font(.caption)
                                        .foregroundColor(manager.isInstalledInApplications ? .green : .secondary)
                                }
                                Spacer()
                                if !manager.isInstalledInApplications {
                                    Button("Install to /Applications") {
                                        manager.installToApplications()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                } else {
                                    Label("Installed", systemImage: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                }
                            }
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
                            InfoRow(title: "App Version", value: AppVersionInfo.formattedVersion)
                            InfoRow(title: "Architecture", value: "Apple Silicon (arm64)")
                            InfoRow(title: "SMC Substrate", value: "AppleSMC (IOKit direct, 80-byte param struct)")
                            InfoRow(title: "Control Handshake", value: "Apple Silicon SMC (F0md manual mode + F0Tg target)")
                            InfoRow(title: "Thermal Sensors", value: "\(sensors_get_count()) active IOHID sensors")
                            InfoRow(title: "Fan Count", value: "\(manager.fans.count) controllable hardware fans")
                        }
                        .padding(8)
                    }

                    // About Section
                    GroupBox(label: Label("About Fan Control", systemImage: "fanblades.fill")) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(
                                            LinearGradient(
                                                colors: [.cyan.opacity(0.25), .blue.opacity(0.35)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 46, height: 46)
                                    Image(systemName: "fanblades.fill")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundColor(.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Text("Mac Fan Speed Curve Controller")
                                            .font(.subheadline)
                                            .fontWeight(.bold)
                                            .foregroundColor(.primary)

                                        Text(AppVersionInfo.formattedVersion)
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.accentColor)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                    }

                                    Text("Native Apple Silicon Thermal & Acoustic Fan Curve Engine for macOS")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Text("• Direct AppleSMC & IOHID telemetry for CPU Cores, GPU Die, Battery, and NAND Storage.")
                                Text("• Monotone Catmull-Rom spline fan curves with hysteresis deadband and acoustic slew-rate limiting.")
                                Text("• 120Hz ProMotion Menu Bar status item, independent Left/Right fan control, and Clamshell sleep safety.")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)

                            Divider()

                            HStack {
                                Text("Built natively with Swift, SwiftUI, AppKit & IOKit")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("© 2026 Fan Control for macOS")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
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

public enum AppVersionInfo {
    public static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5.0"
    }

    public static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "6"
    }

    public static var formattedVersion: String {
        "v\(shortVersion) (Build \(buildNumber))"
    }
}

public struct AboutSheetView: View {
    @ObservedObject var manager: FanManager
    public var onDismiss: () -> Void

    public init(manager: FanManager, onDismiss: @escaping () -> Void) {
        self.manager = manager
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            // App Emblem & Title
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.25), .blue.opacity(0.35)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                        )

                    Image(systemName: "fanblades.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 4) {
                    Text("Mac Fan Speed Curve Controller")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("Version \(AppVersionInfo.shortVersion) (Build \(AppVersionInfo.buildNumber))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }

                Text("Precision thermal telemetry and custom acoustic fan curve controller engineered specifically for Apple Silicon Macs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            Divider()

            // Capabilities & Hardware Summary
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(title: "Architecture", value: "Apple Silicon (arm64)")
                InfoRow(title: "SMC Interface", value: "AppleSMC Direct (F0md + F0Tg)")
                InfoRow(title: "Menu Bar Rendering", value: "120Hz ProMotion Adaptive (0.75° step)")
                InfoRow(title: "Active Sensors", value: "\(sensors_get_count()) IOHID + SMC Die Sensors")
                InfoRow(title: "Hardware Fans", value: "\(manager.fans.count) Controllable Fans")
                InfoRow(title: "Control Privilege", value: manager.hasHardwareControl ? "Active (Helper Connected)" : "Monitor Mode")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
            )

            Spacer(minLength: 0)

            HStack {
                Text("© 2026 Fan Control for macOS")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(22)
        .frame(width: 380, height: 390)
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
