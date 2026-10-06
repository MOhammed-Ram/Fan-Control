import AppKit
import SwiftUI

@MainActor
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let manager: FanManager
    private var updateTimer: Timer?

    // High-Fidelity ProMotion Rotating Fan Animation (120 frames, hardware-synced CADisplayLink)
    private var fanFrames: [NSImage] = []
    private var currentDisplayedFrameIndex: Int = -1
    private var displayLink: AnyObject?
    private var lastTimestamp: CFTimeInterval = 0.0
    private var currentAngle: Double = 0.0
    private var angularVelocity: Double = 200.0
    private var targetAngularVelocity: Double = 200.0

    public var onOpenWindow: (() -> Void)?

    public init(manager: FanManager) {
        self.manager = manager
        super.init()
        setupStatusItem()
        setupPopover()
        startUpdating()
    }

    private static func generateFanFrames(count: Int = 120) -> [NSImage] {
        let size = NSSize(width: 16, height: 16)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        guard let base = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "Fan")?.withSymbolConfiguration(config) else {
            return []
        }

        var frames: [NSImage] = []
        for i in 0..<count {
            let angleDegrees = CGFloat(i) * (360.0 / CGFloat(count))
            let frame = NSImage(size: size, flipped: false) { rect in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                ctx.saveGState()
                ctx.translateBy(x: rect.midX, y: rect.midY)
                ctx.rotate(by: -angleDegrees * .pi / 180.0) // clockwise rotation
                let baseW = base.size.width
                let baseH = base.size.height
                let drawRect = CGRect(x: -baseW / 2.0, y: -baseH / 2.0, width: baseW, height: baseH)
                base.draw(in: drawRect, from: NSRect(origin: .zero, size: base.size), operation: .sourceOver, fraction: 1.0)
                ctx.restoreGState()
                return true
            }
            frame.isTemplate = true
            frames.append(frame)
        }
        return frames
    }

    private func setupStatusItem() {
        fanFrames = MenuBarController.generateFanFrames(count: 120)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            if let initial = fanFrames.first {
                button.image = initial
                currentDisplayedFrameIndex = 0
            }
        }
        updateStatusTitle()
        updateAnimationSpeed()
        startDisplayLink()
    }

    private func setupPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 310, height: 400)

        let popoverView = MenuBarPopoverView(
            manager: manager,
            onOpenMainWindow: { [weak self] in
                self?.popover?.performClose(nil)
                self?.onOpenWindow?()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            }
        )

        pop.contentViewController = NSHostingController(rootView: popoverView)
        self.popover = pop
    }

    private func startUpdating() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusTitle()
            }
        }
    }

    private func startDisplayLink() {
        guard let button = statusItem?.button else { return }
        if #available(macOS 14.0, *) {
            let dl = button.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            dl.add(to: .main, forMode: .common)
            self.displayLink = dl
        } else {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fallbackTimerTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.displayLink = timer
        }
    }

    @objc private func displayLinkDidFire(_ link: CADisplayLink) {
        guard let button = statusItem?.button else { return }
        guard !fanFrames.isEmpty else { return }

        if manager.isOverheating {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Overheat")?.withSymbolConfiguration(config)
            return
        }

        let timestamp = link.targetTimestamp
        if lastTimestamp == 0.0 {
            lastTimestamp = timestamp
            return
        }

        let dt = min(0.05, max(0.001, timestamp - lastTimestamp))
        lastTimestamp = timestamp

        // Smoothly blend angular velocity towards target to prevent acoustic/visual snapping
        angularVelocity += (targetAngularVelocity - angularVelocity) * min(1.0, dt * 8.0)

        if angularVelocity <= 5.0 {
            if currentDisplayedFrameIndex != 0 {
                currentDisplayedFrameIndex = 0
                button.image = fanFrames.first
            }
            return
        }

        currentAngle = (currentAngle + angularVelocity * dt).truncatingRemainder(dividingBy: 360.0)
        let frameIndex = Int((currentAngle / 360.0) * Double(fanFrames.count)) % fanFrames.count

        if frameIndex != currentDisplayedFrameIndex {
            currentDisplayedFrameIndex = frameIndex
            button.image = fanFrames[frameIndex]
        }
    }

    private func fallbackTimerTick() {
        guard let button = statusItem?.button else { return }
        guard !fanFrames.isEmpty else { return }

        if manager.isOverheating {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            button.image = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "Overheat")?.withSymbolConfiguration(config)
            return
        }

        let now = CACurrentMediaTime()
        if lastTimestamp == 0.0 {
            lastTimestamp = now
            return
        }

        let dt = min(0.05, max(0.001, now - lastTimestamp))
        lastTimestamp = now

        angularVelocity += (targetAngularVelocity - angularVelocity) * min(1.0, dt * 8.0)

        if angularVelocity <= 5.0 {
            if currentDisplayedFrameIndex != 0 {
                currentDisplayedFrameIndex = 0
                button.image = fanFrames.first
            }
            return
        }

        currentAngle = (currentAngle + angularVelocity * dt).truncatingRemainder(dividingBy: 360.0)
        let frameIndex = Int((currentAngle / 360.0) * Double(fanFrames.count)) % fanFrames.count

        if frameIndex != currentDisplayedFrameIndex {
            currentDisplayedFrameIndex = frameIndex
            button.image = fanFrames[frameIndex]
        }
    }

    private func updateAnimationSpeed() {
        if manager.isOverheating {
            targetAngularVelocity = 0.0
            return
        }

        let avgRpm = manager.fans.isEmpty ? 0 : (manager.fans.map(\.currentRPM).reduce(0, +) / Double(manager.fans.count))
        let avgPct = manager.fans.isEmpty ? 0 : (manager.fans.map(\.percentage).reduce(0, +) / Double(manager.fans.count))

        if avgRpm < 100 {
            targetAngularVelocity = 0.0
            return
        }

        // Continuous angular velocity in degrees per second:
        // Idle (~2300 RPM / 0% load)  -> 200 deg/s (~1.8s per 360° turn)
        // 50% load (~4500 RPM)        -> 480 deg/s (~0.75s per 360° turn)
        // 100% Turbo (~7800 RPM)      -> 900 deg/s (~0.4s per 360° turn)
        let normalized = max(0.0, min(1.0, avgPct / 100.0))
        targetAngularVelocity = 200.0 + (normalized * 700.0)
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }

        let temp = Int(manager.currentDisplayTemp)
        let fans = manager.fans

        switch manager.menuBarLayoutStyle {
        case .stackedDual:
            if fans.count >= 2 {
                let leftRpm = Int(fans[0].currentRPM)
                let rightRpm = Int(fans[1].currentRPM)

                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineSpacing = -2.5
                paragraphStyle.alignment = .left

                let attr = NSMutableAttributedString()
                // Top line: Left fan RPM
                let line1 = String(format: " %4d rpm\n", leftRpm)
                attr.append(NSAttributedString(string: line1, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .paragraphStyle: paragraphStyle
                ]))
                // Bottom line: Right fan RPM + Temp
                let line2 = String(format: " %4d rpm   %d°C", rightRpm, temp)
                attr.append(NSAttributedString(string: line2, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .paragraphStyle: paragraphStyle
                ]))

                button.attributedTitle = attr
            } else {
                let rpm = fans.first.map { Int($0.currentRPM) } ?? 0
                button.attributedTitle = NSAttributedString(string: String(format: " %d rpm • %d°C", rpm, temp), attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                ])
            }

        case .singleLineAvg:
            let avgRpm = fans.isEmpty ? 0 : Int(fans.map(\.currentRPM).reduce(0, +) / Double(fans.count))
            button.attributedTitle = NSAttributedString(string: String(format: " %d°C • %d RPM", temp, avgRpm), attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ])

        case .singleLineDual:
            if fans.count >= 2 {
                let leftRpm = Int(fans[0].currentRPM)
                let rightRpm = Int(fans[1].currentRPM)
                button.attributedTitle = NSAttributedString(string: String(format: " %d / %d RPM • %d°C", leftRpm, rightRpm, temp), attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                ])
            } else {
                let rpm = fans.first.map { Int($0.currentRPM) } ?? 0
                button.attributedTitle = NSAttributedString(string: String(format: " %d°C • %d RPM", temp, rpm), attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                ])
            }
        }

        updateAnimationSpeed()
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click: quick context menu
            showContextMenu(sender)
        } else {
            // Left-click: toggle rich interactive popover
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        guard let pop = popover else { return }
        if pop.isShown {
            pop.performClose(sender)
        } else {
            pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()

        let avgTemp = String(format: "%.1f°C", manager.thermals.cpuAvg)
        let peakTemp = String(format: "%.1f°C", manager.thermals.cpuPeak)
        let fanDesc = manager.fans.map { "\($0.name): \(Int($0.currentRPM)) RPM" }.joined(separator: " | ")
        let header = NSMenuItem(title: "SoC Peak: \(peakTemp) (Avg: \(avgTemp)) • \(fanDesc)", action: nil, keyEquivalent: "")
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

        let openItem = NSMenuItem(title: "Open Curve Editor...", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // Clear menu so subsequent left-clicks toggle popover
    }

    @objc private func didSelectLayoutStyle(_ sender: NSMenuItem) {
        if let layout = sender.representedObject as? MenuBarLayoutStyle {
            manager.menuBarLayoutStyle = layout
            UserDefaults.standard.set(layout.rawValue, forKey: "MenuBarLayoutStyle")
            updateStatusTitle()
        }
    }

    @objc private func didSelectTempSource(_ sender: NSMenuItem) {
        if let source = sender.representedObject as? MenuBarTempSource {
            manager.menuBarTempSource = source
            UserDefaults.standard.set(source.rawValue, forKey: "MenuBarTempSource")
            updateStatusTitle()
        }
    }

    @objc private func didSelectMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? FanMode {
            manager.setMode(mode)
        }
    }

    @objc private func openMainWindow() {
        popover?.performClose(nil)
        onOpenWindow?()
    }

    @objc private func quitApp() {
        if #available(macOS 14.0, *), let dl = displayLink as? CADisplayLink {
            dl.invalidate()
        } else if let timer = displayLink as? Timer {
            timer.invalidate()
        }
        displayLink = nil
        NSApplication.shared.terminate(nil)
    }
}
