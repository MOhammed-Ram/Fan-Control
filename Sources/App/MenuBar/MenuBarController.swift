import AppKit
import SwiftUI
import Combine

@MainActor
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popupPanel: NSPanel?
    private var hostingController: NSHostingController<MenuBarPopoverView>?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private let manager: FanManager
    private var cancellables = Set<AnyCancellable>()

    // Pre-rendered 4-blade aerodynamic fan frames (120 frames over 90° blade period = 0.75° step / 480 effective frames per 360°)
    private var fanFrames: [NSImage] = []
    private var currentDisplayedFrameIndex: Int = -1

    // Hardware-calibrated ProMotion (120Hz / 60Hz) animation timer via DispatchSourceTimer
    private var animationTimer: DispatchSourceTimer?
    private var currentTargetFPS: Int = 0
    private var animationTickCount: UInt = 0
    private var lastTimestamp: CFTimeInterval = 0.0
    private var currentAngle: Double = 0.0
    private var angularVelocity: Double = 120.0
    private var targetAngularVelocity: Double = 120.0

    public var onOpenWindow: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenAbout: (() -> Void)?

    public init(manager: FanManager) {
        self.manager = manager
        super.init()
        fanFrames = MenuBarController.generateFanFrames(count: 120)
        setupStatusItem()
        setupPanel()
        startUpdating()
    }

    private static func generateFanFrames(count: Int = 120) -> [NSImage] {
        let size = NSSize(width: 16, height: 16)
        var frames: [NSImage] = []
        // Because the 4-blade fan has 90° rotational symmetry, sampling 120 frames over one 90° quarter-turn
        // yields 0.75° angular resolution (480 effective frames per 360° revolution) for 120Hz ProMotion smoothness.
        let step = (0.5 * .pi) / CGFloat(count)

        for i in 0..<count {
            let angle = CGFloat(i) * step
            let frame = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.saveGState()
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -angle) // clockwise rotation

                // Center hub
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: -2.0, y: -2.0, width: 4.0, height: 4.0))

                // 4 rounded aerodynamic blades (exact match to Macs Fan Control style)
                for b in 0..<4 {
                    ctx.saveGState()
                    ctx.rotate(by: CGFloat(b) * (.pi / 2.0))
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: -1.2, y: 1.5))
                    path.addQuadCurve(to: CGPoint(x: -2.2, y: 5.8), control: CGPoint(x: -2.8, y: 3.5))
                    path.addArc(center: CGPoint(x: 0, y: 5.8), radius: 2.2, startAngle: .pi, endAngle: 0, clockwise: true)
                    path.addQuadCurve(to: CGPoint(x: 1.2, y: 1.5), control: CGPoint(x: 2.8, y: 3.5))
                    path.closeSubpath()
                    ctx.addPath(path)
                    ctx.fillPath()
                    ctx.restoreGState()
                }
                ctx.restoreGState()
                return true
            }
            frame.isTemplate = true
            frames.append(frame)
        }
        return frames
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            if !fanFrames.isEmpty {
                button.image = fanFrames[0]
            }
        }
        updateStatusText()
        updateAnimationSpeed()
        startAnimationTimer()
    }

    private func setupPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 340),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 340))
        visualEffect.material = .popover
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 1.0
        visualEffect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.25).cgColor

        let popoverView = MenuBarPopoverView(
            manager: manager,
            onOpenMainWindow: { [weak self] in
                self?.closePopover()
                self?.onOpenWindow?()
            },
            onOpenSettings: { [weak self] in
                self?.closePopover()
                self?.onOpenSettings?()
            },
            onOpenAbout: { [weak self] in
                self?.closePopover()
                self?.onOpenAbout?()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )

        let hosting = NSHostingController(rootView: popoverView)
        hosting.view.frame = visualEffect.bounds
        hosting.view.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hosting.view)
        panel.contentView = visualEffect
        self.hostingController = hosting

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }

        self.popupPanel = panel
    }

    private func startUpdating() {
        // Synchronize directly with FanManager hardware polls in real-time
        manager.$thermals
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.updateAnimationSpeed()
                self.updateStatusText()
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            manager.$menuBarLayoutStyle.map { _ in () },
            manager.$menuBarTempSource.map { _ in () },
            manager.$temperatureUnit.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateStatusText()
        }
        .store(in: &cancellables)

        Publishers.Merge3(
            manager.$activeMode.map { _ in () },
            manager.$isHelperConnected.map { _ in () },
            manager.$linkFans.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.resizeVisiblePopoverIfNeeded()
        }
        .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureAnimationTimerForScreen()
            }
        }

        NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.configureAnimationTimerForScreen()
            }
        }
    }

    private func effectiveDisplayFPS() -> Int {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return 60
        }
        let screenMaxFPS = statusItem?.button?.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        return max(60, min(120, screenMaxFPS))
    }

    private func startAnimationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            self?.animationTick()
        }
        self.animationTimer = timer
        configureAnimationTimerForScreen()
        timer.resume()
    }

    private func configureAnimationTimerForScreen() {
        guard let timer = animationTimer else { return }
        let fps = effectiveDisplayFPS()
        guard fps != currentTargetFPS else { return }
        currentTargetFPS = fps
        // 8,333 µs (8.333ms) on 120Hz ProMotion displays; 16,667 µs (16.667ms) on 60Hz displays
        let intervalMicros = max(4000, Int((1_000_000.0 / Double(fps)).rounded()))
        timer.schedule(deadline: .now(), repeating: .microseconds(intervalMicros), leeway: .microseconds(400))
    }

    private func animationTick() {
        if manager.shouldSuspendForSleepOrClamshell {
            lastTimestamp = 0.0
            return
        }
        guard let button = statusItem?.button else { return }

        // Periodic fallback (~once/sec at 120Hz) in case the status item moved displays without a screen-parameter notification.
        animationTickCount = animationTickCount &+ 1
        if animationTickCount % 120 == 0 {
            configureAnimationTimerForScreen()
        }

        let now = CACurrentMediaTime()
        if lastTimestamp == 0.0 {
            lastTimestamp = now
            return
        }

        let dt = min(0.05, max(0.001, now - lastTimestamp))
        lastTimestamp = now

        // Smoothly blend angular velocity towards target
        angularVelocity += (targetAngularVelocity - angularVelocity) * min(1.0, dt * 6.0)

        if angularVelocity <= 5.0 {
            if currentDisplayedFrameIndex != 0 {
                currentDisplayedFrameIndex = 0
                currentAngle = 0.0
                if !fanFrames.isEmpty {
                    button.image = fanFrames[0]
                }
            }
            return
        }

        // Modulo 90.0° (one 4-blade symmetry period) mapped across 120 high-precision frames (0.75° per step)
        currentAngle = (currentAngle + angularVelocity * dt).truncatingRemainder(dividingBy: 90.0)
        guard !fanFrames.isEmpty else { return }
        let frameIndex = Int((currentAngle / 90.0) * Double(fanFrames.count)) % fanFrames.count

        if frameIndex != currentDisplayedFrameIndex {
            currentDisplayedFrameIndex = frameIndex
            button.image = fanFrames[frameIndex]
        }
    }

    private func updateAnimationSpeed() {
        if manager.isOverheating {
            targetAngularVelocity = 360.0 // Fast spin on overheat (~1.0 rev/s, 6°/frame)
            return
        }

        let avgRpm = manager.fans.isEmpty ? 0 : (manager.fans.map(\.currentRPM).reduce(0, +) / Double(manager.fans.count))
        let avgPct = manager.fans.isEmpty ? 0 : (manager.fans.map(\.percentage).reduce(0, +) / Double(manager.fans.count))

        if avgRpm < 100 {
            targetAngularVelocity = 0.0 // Stationary when fans are stopped / 0 RPM
            return
        }

        // Calibrated smooth rotation speeds (zero stroboscopic jumping, physically continuous):
        // Idle (~2000 RPM / 0% load)  -> 100 deg/s (~0.28 rev/s, ~1.6° per frame at 60 FPS)
        // 50% load (~4500 RPM)        -> 190 deg/s (~0.53 rev/s, ~3.1° per frame at 60 FPS)
        // 100% Turbo (~7800 RPM)      -> 280 deg/s (~0.78 rev/s, ~4.6° per frame at 60 FPS)
        let normalized = max(0.0, min(1.0, avgPct / 100.0))
        targetAngularVelocity = 100.0 + (normalized * 180.0)
    }

    private func updateStatusText() {
        guard let button = statusItem?.button else { return }

        let temp = manager.currentDisplayIntTemp
        let unitSym = manager.tempUnitSymbol
        let fans = manager.fans
        let layoutStyle = manager.menuBarLayoutStyle

        if layoutStyle == .iconOnly {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        button.imagePosition = .imageLeading

        if layoutStyle == .tempOnly {
            let font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            button.attributedTitle = NSAttributedString(
                string: "\(temp)\(unitSym)",
                attributes: [.font: font]
            )
            return
        }

        let leftRpm: Int
        let rightRpm: Int
        if fans.count >= 2 {
            leftRpm = fans[0].displayRPM
            rightRpm = fans[1].displayRPM
        } else if let first = fans.first {
            leftRpm = first.displayRPM
            rightRpm = first.displayRPM
        } else {
            leftRpm = 0
            rightRpm = 0
        }

        let fanCount = fans.count
        let shouldShowRPM: Bool
        if fanCount >= 2 {
            shouldShowRPM = (leftRpm > 0 || rightRpm > 0)
        } else if fanCount == 1 {
            shouldShowRPM = (leftRpm > 0)
        } else {
            shouldShowRPM = false
        }

        if layoutStyle == .rpmOnly {
            let font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
            let avg = (leftRpm + rightRpm) / max(1, fanCount)
            let str = shouldShowRPM ? "\(avg) RPM" : "0 RPM"
            button.attributedTitle = NSAttributedString(string: str, attributes: [.font: font])
            return
        }

        guard shouldShowRPM else {
            // When RPM is 0, hide RPM completely and show only the temperature
            let font = NSFont.systemFont(ofSize: 13.0, weight: .regular)
            button.attributedTitle = NSAttributedString(
                string: "\(temp)\(unitSym)",
                attributes: [.font: font]
            )
            return
        }

        switch layoutStyle {
        case .stackedDual:
            if fanCount >= 2 {
                let pStyle = NSMutableParagraphStyle()
                pStyle.lineSpacing = 0.0
                pStyle.maximumLineHeight = 10.0
                pStyle.minimumLineHeight = 10.0

                let rpmAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
                    .paragraphStyle: pStyle
                ]
                let tempAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12.0, weight: .regular),
                    .paragraphStyle: pStyle,
                    .baselineOffset: 1.0
                ]

                let str = NSMutableAttributedString()
                str.append(NSAttributedString(string: "\(leftRpm) rpm\n", attributes: rpmAttrs))
                str.append(NSAttributedString(string: "\(rightRpm) rpm   ", attributes: rpmAttrs))
                str.append(NSAttributedString(string: "\(temp)\(unitSym)", attributes: tempAttrs))
                button.attributedTitle = str
            } else {
                let font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
                let str = "\(leftRpm) rpm   \(temp)\(unitSym)"
                button.attributedTitle = NSAttributedString(string: str, attributes: [.font: font])
            }

        case .singleLineAvg:
            let font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
            let avg = (leftRpm + rightRpm) / max(1, fanCount)
            let str = "\(temp)\(unitSym) • \(avg) RPM"
            button.attributedTitle = NSAttributedString(string: str, attributes: [.font: font])

        case .singleLineDual:
            let font = NSFont.systemFont(ofSize: 12.0, weight: .regular)
            let str = "\(leftRpm) / \(rightRpm) RPM • \(temp)\(unitSym)"
            button.attributedTitle = NSAttributedString(string: str, attributes: [.font: font])

        case .tempOnly, .rpmOnly, .iconOnly:
            break
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            closePopover()
            showContextMenu(sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let panel = popupPanel, panel.isVisible {
            closePopover()
        } else {
            showPopover(sender)
        }
    }

    private func resizeVisiblePopoverIfNeeded() {
        guard let panel = popupPanel, panel.isVisible,
              let sender = statusItem?.button,
              let win = sender.window, let screen = win.screen else { return }

        let panelW: CGFloat = 340
        let idealSize = hostingController?.sizeThatFits(in: NSSize(width: panelW, height: 1000))
        let fittingH = idealSize?.height ?? hostingController?.view.fittingSize.height ?? 340
        let panelH: CGFloat = max(240, min(540, ceil(fittingH)))

        let buttonRectInWin = sender.convert(sender.bounds, to: nil)
        let buttonRectOnScreen = win.convertToScreen(buttonRectInWin)
        var x = buttonRectOnScreen.midX - panelW / 2
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - panelW - 8))
        let y = buttonRectOnScreen.minY - panelH - 4

        panel.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: true, animate: true)
    }

    private func showPopover(_ sender: NSStatusBarButton) {
        guard let win = sender.window, let screen = win.screen else { return }

        if popupPanel == nil {
            setupPanel()
        }
        guard let panel = popupPanel else { return }

        let buttonRectInWin = sender.convert(sender.bounds, to: nil)
        let buttonRectOnScreen = win.convertToScreen(buttonRectInWin)

        let panelW: CGFloat = 340
        let idealSize = hostingController?.sizeThatFits(in: NSSize(width: panelW, height: 1000))
        let fittingH = idealSize?.height ?? hostingController?.view.fittingSize.height ?? 340
        let panelH: CGFloat = max(240, min(540, ceil(fittingH)))

        var x = buttonRectOnScreen.midX - panelW / 2
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - panelW - 8))
        let y = buttonRectOnScreen.minY - panelH - 4

        panel.setFrame(NSRect(x: x, y: y, width: panelW, height: panelH), display: true)
        panel.orderFront(nil)
        panel.makeKey()

        // Global mouse monitor: dismiss when clicking anywhere outside
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let sender = self.statusItem?.button, let win = sender.window else {
                self?.closePopover()
                return
            }
            let mouseLoc = NSEvent.mouseLocation
            let btnRect = win.convertToScreen(sender.convert(sender.bounds, to: nil))
            if !btnRect.contains(mouseLoc) {
                self.closePopover()
            }
        }

        // Local monitor: dismiss when clicking another window within the app
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let panel = self?.popupPanel, event.window != panel {
                self?.closePopover()
            }
            return event
        }
    }

    private func closePopover() {
        popupPanel?.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        let avgTemp = manager.formatTemp(manager.thermals.cpuAvg)
        let peakTemp = manager.formatTemp(manager.thermals.cpuPeak)
        let gpuTemp = manager.formatTemp(manager.thermals.gpu)
        let fanDesc = manager.fans.map { "\($0.name): \(Int($0.currentRPM)) RPM" }.joined(separator: " | ")
        let header = NSMenuItem(title: "CPU Avg: \(avgTemp) (Peak: \(peakTemp)) • GPU: \(gpuTemp) • \(fanDesc)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())

        // Layout style submenu
        let layoutMenu = NSMenu()
        for layout in MenuBarLayoutStyle.allCases {
            let item = NSMenuItem(title: layout.rawValue, action: #selector(didSelectLayoutStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout
            item.state = (manager.menuBarLayoutStyle == layout) ? .on : .off
            layoutMenu.addItem(item)
        }
        let layoutSubItem = NSMenuItem(title: "Menu Bar Layout", action: nil, keyEquivalent: "")
        layoutSubItem.submenu = layoutMenu
        menu.addItem(layoutSubItem)

        // Temperature source submenu
        let tempMenu = NSMenu()
        for source in MenuBarTempSource.allCases {
            let item = NSMenuItem(title: source.rawValue, action: #selector(didSelectTempSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source
            item.state = (manager.menuBarTempSource == source) ? .on : .off
            tempMenu.addItem(item)
        }
        let tempSubItem = NSMenuItem(title: "Temperature Metric", action: nil, keyEquivalent: "")
        tempSubItem.submenu = tempMenu
        menu.addItem(tempSubItem)

        menu.addItem(NSMenuItem.separator())

        for mode in FanMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(didSelectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (manager.activeMode == mode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Background & Dock options
        let dockItem = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = manager.runAsMenuBarOnly ? .on : .off
        menu.addItem(dockItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = manager.startAtLogin ? .on : .off
        menu.addItem(loginItem)

        let notifyItem = NSMenuItem(title: "Enable Thermal Alerts", action: #selector(toggleOverheatNotifications(_:)), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = manager.enableOverheatNotifications ? .on : .off
        menu.addItem(notifyItem)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Curve Editor...", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openSettingsWindow), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let aboutItem = NSMenuItem(title: "About Fan Control...", action: #selector(openAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // Clear menu so subsequent left-clicks toggle popover
    }

    @objc private func toggleDockIcon(_ sender: NSMenuItem) {
        let newState = !manager.runAsMenuBarOnly
        manager.setRunAsMenuBarOnly(newState)
        sender.state = newState ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !manager.startAtLogin
        manager.setStartAtLogin(newState)
        sender.state = newState ? .on : .off
    }

    @objc private func toggleOverheatNotifications(_ sender: NSMenuItem) {
        let newState = !manager.enableOverheatNotifications
        manager.enableOverheatNotifications = newState
        manager.saveSettings()
        sender.state = newState ? .on : .off
    }

    @objc private func didSelectLayoutStyle(_ sender: NSMenuItem) {
        if let layout = sender.representedObject as? MenuBarLayoutStyle {
            manager.menuBarLayoutStyle = layout
            manager.saveSettings()
            updateStatusText()
        }
    }

    @objc private func didSelectTempSource(_ sender: NSMenuItem) {
        if let source = sender.representedObject as? MenuBarTempSource {
            manager.menuBarTempSource = source
            UserDefaults.standard.set(true, forKey: "UserExplicitlySetMenuBarTempSource")
            manager.saveSettings()
            updateStatusText()
        }
    }

    @objc private func didSelectMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? FanMode {
            manager.setMode(mode)
        }
    }

    @objc private func openMainWindow() {
        closePopover()
        onOpenWindow?()
    }

    @objc private func openSettingsWindow() {
        closePopover()
        onOpenSettings?()
    }

    @objc private func openAboutWindow() {
        closePopover()
        onOpenAbout?()
    }

    @objc private func quitApp() {
        closePopover()
        animationTimer?.cancel()
        animationTimer = nil
        NSApplication.shared.terminate(nil)
    }
}
