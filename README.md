# Mac Fan Speed Curve Controller

A native macOS fan speed curve controller and thermal monitoring suite designed specifically for Apple Silicon (M1, M2, M3, M4, M5+) and Intel Macs.

Includes a **modern native SwiftUI GUI application with upper OS status bar (menu bar) companion** and a lightweight **CLI utility (`fan-curve-ctl`)** supported by a safe **Privileged Helper Daemon**.

---

## 🌟 Upper OS Bar (Menu Bar) Controls & Status

The app adds a live status indicator and interactive control panel directly in the macOS upper menu bar:

- **Live Status in Menu Bar**: Displays real-time SoC temperature and active fan RPM directly in the top menu bar (e.g., `💨 52°C • 2317 RPM`).
- **Interactive Menu Bar Popover**: Clicking the menu bar item opens an interactive quick-control panel:
  - **Live Thermals & Gauges**: Readout of SoC average die temperature, thermal pressure state (`Nominal`, `Fair`, `Serious`, `Critical`), and per-fan RPMs.
  - **Quick Mode Toggles**: Switch between `Auto`, `Curve Control`, `Manual Fixed`, and `100% Turbo` with one click.
  - **Preset Selector**: Instantly switch between `Silent`, `Balanced`, `Performance`, and `Custom` curves.
  - **Quick Speed Slider**: Adjust manual target RPM directly from the upper bar.
  - **One-Click Elevation**: Detects whether the privileged helper is active and allows 1-click activation.
  - **Open Curve Editor**: Opens the main high-DPI draggable spline curve window.
- **Persistent Operation**: Closing the main window keeps the upper menu bar icon and background thermal loop actively running.

---

## 🛠 Features Overview

- **Interactive Fan Speed Curve Canvas**:
  - Catmull-Rom spline and linear interpolation across the 30°C–100°C SoC temperature range.
  - Draggable control nodes with real-time coordinate badges (`Temp °C • Fan %`).
  - Click anywhere on the canvas to add points; select and delete points.
  - **Live Operating Puck**: A real-time pulsating indicator that tracks your Mac's current operating point on the curve, showing commanded RPM and percentage.
- **Thermal Profiles & Presets**:
  - **Silent**: Minimizes noise; keeps fans near idle until 55°C.
  - **Balanced**: Progressive everyday cooling curve.
  - **Performance**: Aggressive early cooling ramp to eliminate thermal throttling under compile/render loads.
  - **Custom**: Fully editable user curve.
- **Safety Watchdogs & Failsafes**:
  - **Emergency Overheat Cutoff**: If any SoC die exceeds the threshold (default 95°C), fans instantly ramp to 100% full blast.
  - **Hysteresis Deadband**: Configurable buffer (0.5°C–5.0°C) prevents fan hunting/fluttering during rapid temperature changes.
  - **Helper Watchdog**: If the GUI app ever crashes or disconnects for > 12 seconds while in manual mode, the helper automatically reverts fans to macOS auto firmware mode.
  - **Sleep / Wake Handling**: Safely yields manual control before system sleep and re-engages after wake.

---

## ⚙️ Architecture & Privilege Handling

1. **Unprivileged Monitoring**:
   - SoC die temperatures are gathered via `IOHIDEventSystemClient` (Apple vendor page `0xFF00`, usage `0x05`, temperature event `0x0F`), querying on-die PMU sensors (`tdie1`–`tdie14`, battery gas gauge, NAND SSD) with **no root privileges required**.
2. **Privileged Hardware Control**:
   - Modern macOS enforces root privileges for writing to SMC hardware registers.
   - We implement a privileged helper daemon (`fan-control-helper`) that communicates over a secure local UNIX domain socket (`/var/run/fancontrol_helper.sock`).
   - The user can click **"Enable Control"** in the app once (which prompts standard macOS Touch ID / password), and the app will control fans seamlessly without ever needing terminal commands.
3. **Apple Silicon SMC Unlock Handshake**:
   - Bypasses macOS `thermalmonitord` by executing the `Ftst = 1` diagnostic force handshake, followed by setting manual mode `F0md = 1` and streaming float targets into `F0Tg` and `F1Tg`.

---

## 📦 Pre-Built Installers (`build/dist/`)

Ready-to-install packages are included directly in the repository under [`build/dist/`](build/dist/):

1. **One-Click macOS Installer (`build/dist/FanControl-Installer.pkg`)** *(Recommended)*:
   - Installs `FanControl.app` into `/Applications`, installs and registers the privileged SMC helper daemon (`/Library/PrivilegedHelperTools/com.fancontrol.helper`), and launches the app in the Menu Bar.
2. **Disk Image (`build/dist/FanControl.dmg`)**:
   - Mountable disk image containing `FanControl.app`, the `Applications` drop link, and `FanControl-Installer.pkg`.
3. **Portable Archive (`build/dist/FanControl.zip`)**:
   - Standalone `.zip` archive of `FanControl.app`.

---

## 🚀 Quick Start (Build from Source)

### Build Everything
```bash
make build
# or build all distribution installers (.pkg, .dmg, .zip):
./Scripts/package.sh
```

### Launch the App
```bash
open build/FanControl.app
```

The app will appear in your **upper OS bar (menu bar)** and launch the main window!

### (Optional) Install the Privileged Helper Daemon
You can click **"Enable Control"** directly inside the app, or run from terminal:
```bash
sudo ./Scripts/install-helper.sh
```
To uninstall the helper and restore system defaults:
```bash
sudo ./Scripts/uninstall-helper.sh
```

---

## 💻 Command Line Interface (`fan-curve-ctl`)

```bash
# Check current temperatures, fan RPM, and privilege level:
./build/bin/fan-curve-ctl status

# Live terminal monitor with ASCII meters:
./build/bin/fan-curve-ctl monitor

# Run the curve engine in foreground (uses helper or sudo):
./build/bin/fan-curve-ctl curve balanced

# Set fixed fan RPM:
./build/bin/fan-curve-ctl set 4200

# Reset all fans to macOS automatic mode:
./build/bin/fan-curve-ctl auto

# Emergency 100% full blast:
./build/bin/fan-curve-ctl turbo
```

---

## 📂 Project Structure

```
Fan-Control/
├── Makefile                          # Build and convenience shortcuts
├── README.md                         # Documentation
├── Scripts/
│   ├── build.sh                      # Compiles CSMCBridge, Helper, CLI, and App
│   ├── install-helper.sh             # Privileged helper launchd installer
│   └── uninstall-helper.sh           # Helper uninstaller
├── Sources/
│   ├── Bridge/
│   │   ├── CSMCBridge.h              # C header for SMC and IOHID interfaces
│   │   └── CSMCBridge.m              # 80-byte SMC struct & Apple Silicon Ftst client
│   ├── Common/
│   │   ├── Models.swift              # CurvePoint, FanProfile, UIState
│   │   ├── CurveEngine.swift         # Spline math, Catmull-Rom interpolation, hysteresis
│   │   ├── HelperClient.swift        # UNIX domain socket client for helper
│   │   └── FanManager.swift          # Hardware coordinator, polling, watchdog
│   ├── Helper/
│   │   └── main.swift                # Privileged helper daemon with safety watchdog
│   ├── App/
│   │   ├── MainApp.swift             # Application delegate and lifecycle
│   │   ├── MenuBar/
│   │   │   ├── MenuBarPopoverView.swift # Upper OS bar interactive controls UI
│   │   │   └── MenuBarController.swift  # Upper OS status item and popover controller
│   │   └── Views/
│   │       ├── ContentView.swift     # Main window container
│   │       ├── CurveEditorView.swift # Interactive Canvas curve editor
│   │       ├── TelemetryDashboard.swift # Gauges, sparklines, thermals
│   │       ├── ProfileSelectorView.swift # Presets and mode selectors
│   │       └── SettingsSheetView.swift  # Preferences and safety limits
│   └── CLI/
│       └── main.swift                # CLI utility entry point
└── build/
    ├── FanControl.app                # Complete signed macOS app bundle (v1.6.0)
    ├── bin/
    │   ├── fan-control-helper        # Privileged helper daemon binary
    │   └── fan-curve-ctl             # Standalone CLI binary
    └── dist/
        ├── FanControl-Installer.pkg  # One-click macOS PKG installer
        ├── FanControl.dmg            # Distributable DMG disk image
        └── FanControl.zip            # Portable ZIP archive
```

---

## 📄 License

This project is open-source software licensed under the [MIT License](LICENSE).
