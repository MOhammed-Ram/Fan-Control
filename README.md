# Mac Fan Speed Curve Controller (v1.7.0)

A native macOS fan speed curve controller and thermal monitoring suite designed specifically for Apple Silicon (M1, M2, M3, M4, M5+) and Intel Macs.

Includes a **modern native SwiftUI GUI application with upper OS status bar (menu bar) companion** and a lightweight **CLI utility (`fan-curve-ctl`)** supported by a safe **Privileged Helper Daemon**.

---

## 🌟 Upper OS Bar (Menu Bar) Controls & Status

The app adds a live status indicator and interactive control panel directly in the macOS upper menu bar:

- **120Hz ProMotion Menu Bar Animation**: Hardware-calibrated rotating fan icon that smoothly adapts between 120Hz ProMotion and 60Hz displays (with automatic 60Hz throttling in Low Power Mode) and scales spin speed to real-time fan RPM.
- **Live Status in Menu Bar**: Displays real-time CPU or GPU Die temperature and active fan RPM directly in the top menu bar with customizable layouts (stacked dual-fan, single-line, temperature-only, RPM-only, or icon-only).
- **Interactive Menu Bar Popover**: Clicking the menu bar item opens an interactive quick-control panel:
  - **Live Thermals & Gauges**: Readout of CPU average/peak die temperature, GPU Die temperature, thermal pressure state (`Nominal`, `Fair`, `Serious`, `Critical`), and per-fan RPMs.
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
- **GPU Die Thermal Sensor & GPU Curve Support**:
  - Dedicated real-time **GPU Die** temperature telemetry alongside CPU core average, CPU peak, battery, and SSD sensors.
  - Drive curves from `CPU Average`, `CPU Peak`, `GPU Die`, or `Max(CPU, GPU)`, with optional unlinked dual-fan curves (Left CPU / Right GPU) on dual-fan MacBook Pro systems.
- **Thermal Profiles & Presets**:
  - **Silent**: Minimizes noise; keeps fans near idle until 55°C.
  - **Balanced**: Progressive everyday cooling curve.
  - **Performance**: Aggressive early cooling ramp to eliminate thermal throttling under compile/render loads.
  - **Custom**: Fully editable user curve with JSON import/export.
- **Safety Watchdogs & Failsafes**:
  - **Emergency Overheat Cutoff**: If sustained SoC temperature exceeds the threshold (default `100°C`, configurable in Preferences), fans automatically ramp to 100% maximum cooling.
  - **Hysteresis Deadband**: Configurable buffer (`0.5°C`–`5.0°C`) prevents fan hunting/fluttering during rapid temperature changes.
  - **4-Second Monotonic Helper Watchdog**: If the GUI app ever crashes, hangs, or disconnects for > 4 seconds while actively overriding fan speeds, the privileged helper uses a monotonic clock watchdog to automatically revert fans to macOS auto firmware control.
  - **Automatic Clamshell & Sleep Fan Handoff**: Safely hands fan control back to macOS firmware when the system sleeps, displays sleep, or the lid closes without an awake external display, and seamlessly re-engages upon wake.

---

## ⚙️ Architecture & Privilege Handling

1. **Unprivileged Monitoring**:
   - SoC CPU and GPU die temperatures are gathered via `IOHIDEventSystemClient` (Apple vendor page `0xFF00`, usage `0x05`, temperature event `0x0F`), querying on-die PMU sensors (`tdie` CPU cores, GPU die sensors, battery gas gauge, NAND SSD) with **no root privileges required**.
2. **Privileged Hardware Control**:
   - Modern macOS enforces root privileges for writing to SMC hardware registers.
   - We implement a privileged helper daemon (`fan-control-helper`) that communicates over a secure local UNIX domain socket (`/var/run/fancontrol_helper.sock`).
   - The user can click **"Enable Control"** in the app once (which prompts standard macOS Touch ID / password), and the app will control fans seamlessly without ever needing terminal commands.
3. **Apple Silicon & Intel SMC Fan Writes**:
   - Writes direct forced-manual mode (`F0md = 1`, `F1md = 1` on dual-fan systems) and target RPM values (`F0Tg`, `F1Tg`) to the Apple SMC with automatic fallback handling across Apple Silicon and Intel hardware, cleanly restoring `F0md = 0` (`auto`) on exit, sleep, or watchdog timeout.

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

### Run Unit Tests
```bash
make test-unit
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
│   │   └── CSMCBridge.m              # 80-byte SMC struct & Apple Silicon/Intel SMC client
│   ├── Common/
│   │   ├── Models.swift              # CurvePoint, FanProfile, UIState
│   │   ├── CurveEngine.swift         # Spline math, Catmull-Rom interpolation, hysteresis
│   │   ├── HelperClient.swift        # UNIX domain socket client for helper
│   │   ├── ShellEscaping.swift       # POSIX & AppleScript escaping utilities
│   │   └── FanManager.swift          # Hardware coordinator, polling, watchdog
│   ├── Helper/
│   │   └── main.swift                # Privileged helper daemon with 4s monotonic watchdog
│   ├── App/
│   │   ├── MainApp.swift             # Application delegate and lifecycle
│   │   ├── MenuBar/
│   │   │   ├── MenuBarPopoverView.swift # Upper OS bar interactive controls UI
│   │   │   └── MenuBarController.swift  # 120Hz ProMotion status item and popover controller
│   │   └── Views/
│   │       ├── ContentView.swift     # Main window container
│   │       ├── CurveEditorView.swift # Interactive Canvas curve editor
│   │       ├── TelemetryDashboard.swift # Gauges, sparklines, thermals
│   │       ├── ProfileSelectorView.swift # Presets and mode selectors
│   │       └── SettingsSheetView.swift  # Preferences and safety limits
│   └── CLI/
│       └── main.swift                # CLI utility entry point
├── Tests/                            # Unit test suite (`make test-unit`)
└── build/
    ├── FanControl.app                # Complete signed macOS app bundle (v1.7.0)
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
