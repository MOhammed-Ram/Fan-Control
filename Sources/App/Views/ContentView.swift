import SwiftUI

public struct ContentView: View {
    @ObservedObject var manager: FanManager
    @ObservedObject var uiState: UIState

    public init(manager: FanManager, uiState: UIState = UIState()) {
        self.manager = manager
        self.uiState = uiState
    }
    public var body: some View {
        VStack(spacing: 12) {
            // 1. Privileged Helper Elevation Banner (if in simulation mode)
            if !manager.hasHardwareControl {
                PrivilegedHelperBanner(manager: manager)
            }

            // 2. Real-Time Telemetry Dashboard (Gauges + Thermals)
            TelemetryDashboard(manager: manager)

            // 3. Operating Mode Selector Bar (Always prominent, never hidden!)
            ControlModeSelector(manager: manager)

            // 4. Mode-Specific Status / Control Panels
            if manager.activeMode == .auto {
                AutoStatusPanel(manager: manager)
            } else if manager.activeMode == .manual {
                ManualControlPanel(manager: manager)
            } else if manager.activeMode == .turbo {
                TurboStatusPanel(manager: manager)
            }

            // 5. Interactive Fan Speed Curve (Always visible in all modes, fills remaining vertical space!)
            CurveEditorView(manager: manager, uiState: uiState)
                .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(width: 860, height: 860)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    // Quick Turbo Button (Top-Right)
                    Button(action: {
                        if manager.activeMode == .turbo {
                            manager.setMode(.auto)
                        } else {
                            manager.setEmergencyTurbo()
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                            Text(manager.activeMode == .turbo ? "Disable Turbo" : "100% Turbo")
                        }
                        .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(manager.activeMode == .turbo ? .red : .orange.opacity(0.25))
                    .foregroundColor(manager.activeMode == .turbo ? .white : .orange)

                    // About Button
                    Button(action: { uiState.showingAbout = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .help("About Fan Control")

                    // Settings Button
                    Button(action: { uiState.showingSettings = true }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Preferences (⌘,)")

                    // Close window shortcut (⌘W)
                    Button("Close") {
                        NSApp.keyWindow?.performClose(nil)
                    }
                    .keyboardShortcut("w", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { uiState.showingSettings },
            set: { uiState.showingSettings = $0 }
        )) {
            SettingsSheetView(manager: manager) {
                uiState.showingSettings = false
            }
        }
        .sheet(isPresented: Binding(
            get: { uiState.showingAbout },
            set: { uiState.showingAbout = $0 }
        )) {
            AboutSheetView(manager: manager) {
                uiState.showingAbout = false
            }
        }
    }
}
