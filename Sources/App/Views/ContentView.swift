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
                // 1. Real-Time Telemetry Dashboard (Gauges + Thermals)
                TelemetryDashboard(manager: manager)

                // 2. Interactive Fan Curve Editor Canvas
                CurveEditorView(manager: manager, uiState: uiState)

                // 3. Control Mode & Preset Profile Selector
                ProfileSelectorView(manager: manager)
            }
            .padding(20)
        }
        .frame(minWidth: 780, minHeight: 760)
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
