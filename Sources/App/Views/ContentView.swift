import SwiftUI

public struct ContentView: View {
    @ObservedObject var manager: FanManager
    @ObservedObject var uiState: UIState

    public init(manager: FanManager, uiState: UIState = UIState()) {
        self.manager = manager
        self.uiState = uiState
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 1. Privileged Helper Elevation Banner (if in simulation mode)
                if !manager.hasHardwareControl {
                    PrivilegedHelperBanner(manager: manager)
                }

                // 2. Real-Time Telemetry Dashboard (Gauges + Thermals)
                TelemetryDashboard(manager: manager)

                // 3. Operating Mode Selector Bar (Always prominent, never hidden!)
                ControlModeSelector(manager: manager)

                // 4. Dynamic Mode Content Panel
                switch manager.activeMode {
                case .auto:
                    AutoStatusPanel(manager: manager)

                case .curve:
                    CurveEditorView(manager: manager, uiState: uiState)

                case .manual:
                    ManualControlPanel(manager: manager)

                case .turbo:
                    TurboStatusPanel(manager: manager)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 800, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "fanblades.fill")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                    Text("Mac Fan Curve Controller")
                        .font(.headline)
                        .fontWeight(.bold)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    // Quick Turbo Button
                    Button(action: {
                        if manager.activeMode == .turbo {
                            manager.setMode(.auto)
                        } else {
                            manager.setEmergencyTurbo()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                            Text(manager.activeMode == .turbo ? "Disable Turbo" : "100% Turbo")
                        }
                        .foregroundColor(manager.activeMode == .turbo ? .white : .orange)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(manager.activeMode == .turbo ? .red : .orange.opacity(0.2))

                    // Settings Button
                    Button(action: { uiState.showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
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
    }
}
