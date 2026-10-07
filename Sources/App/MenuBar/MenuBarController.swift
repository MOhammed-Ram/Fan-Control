import AppKit
import SwiftUI
import Combine

@MainActor
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let manager: FanManager
    private var cancellables = Set<AnyCancellable>()

    // High-Fidelity ProMotion Rotating Fan Animation (120 frames, hardware-synced CADisplayLink)
    private var fanFrames: [NSImage] = []
    private var currentDisplayedFrameIndex: Int = -1
    private var displayLink: AnyObject?
    private var lastTimestamp: CFTimeInterval = 0.0
    private var currentAngle: Double = 0.0
    private var angularVelocity: Double = 200.0
    private var targetAngularVelocity: Double = 200.0
    private var statusTextView: MenuBarStatusTextView?

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
        var frames: [NSImage] = []

        for i in 0..<count {
            let angle = CGFloat(i) * (2.0 * .pi / CGFloat(count))
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
            button.title = ""
            button.attributedTitle = NSAttributedString()

            let tv = MenuBarStatusTextView(frame: .zero)
            button.addSubview(tv)
            self.statusTextView = tv
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
        // Synchronize directly with FanManager hardware polls in real-time
        manager.$thermals
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusTitle()
            }
            .store(in: &cancellables)
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
            targetAngularVelocity = 900.0 // Turbo spin on overheat
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
        guard let tv = statusTextView else { return }

        let temp = manager.currentDisplayIntTemp
        let fans = manager.fans

        tv.temp = temp
        tv.fanCount = fans.count
        tv.layoutStyle = manager.menuBarLayoutStyle
        if fans.count >= 2 {
            tv.leftRpm = fans[0].displayRPM
            tv.rightRpm = fans[1].displayRPM
        } else if let first = fans.first {
            tv.leftRpm = first.displayRPM
            tv.rightRpm = first.displayRPM
        } else {
            tv.leftRpm = 0
            tv.rightRpm = 0
        }

        let textWidth = tv.calculateWidth()
        // Icon takes 16pt + 5pt padding = 21pt leading margin
        let leadingIconWidth: CGFloat = 21.0
        let totalWidth = leadingIconWidth + textWidth + 3.0
        statusItem?.length = totalWidth
        tv.frame = NSRect(x: leadingIconWidth, y: 0.0, width: textWidth + 3.0, height: 22.0)
        tv.needsDisplay = true

        updateAnimationSpeed()
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        statusTextView?.needsDisplay = true

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
            statusTextView?.needsDisplay = true
        } else {
            statusTextView?.needsDisplay = true
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

// MARK: - Pixel-Perfect Menu Bar Status Text View (Macs Fan Control Layout)
final class MenuBarStatusTextView: NSView {
    var leftRpm: Int = 0
    var rightRpm: Int = 0
    var fanCount: Int = 2
    var temp: Int = 0
    var layoutStyle: MenuBarLayoutStyle = .stackedDual

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil // Mouse events pass through directly to NSStatusBarButton
    }

    func calculateWidth() -> CGFloat {
        let rpmFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        let tempFont = NSFont.systemFont(ofSize: 13.0, weight: .regular)

        switch layoutStyle {
        case .stackedDual:
            if fanCount >= 2 {
                let leftStr = "\(leftRpm) rpm" as NSString
                let rightStr = "\(rightRpm) rpm" as NSString
                let wLeft = leftStr.size(withAttributes: [.font: rpmFont]).width
                let wRight = rightStr.size(withAttributes: [.font: rpmFont]).width
                let maxRpmW = max(wLeft, wRight)

                let tempStr = "\(temp)°C" as NSString
                let wTemp = tempStr.size(withAttributes: [.font: tempFont]).width

                return maxRpmW + 8.0 + wTemp + 4.0
            } else {
                let str = "\(leftRpm) rpm   \(temp)°C" as NSString
                return str.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.0, weight: .medium)]).width + 6.0
            }

        case .singleLineAvg:
            let avg = (leftRpm + rightRpm) / max(1, fanCount)
            let str = "\(temp)°C • \(avg) RPM" as NSString
            return str.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.0, weight: .medium)]).width + 6.0

        case .singleLineDual:
            let str = "\(leftRpm) / \(rightRpm) RPM • \(temp)°C" as NSString
            return str.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.0, weight: .medium)]).width + 6.0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let isParentHighlighted = (self.superview as? NSStatusBarButton)?.isHighlighted ?? false
        let textColor: NSColor = isParentHighlighted ? .white : .labelColor

        switch layoutStyle {
        case .stackedDual:
            if fanCount >= 2 {
                let rpmFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
                let tempFont = NSFont.systemFont(ofSize: 13.0, weight: .regular)

                let rpmAttrs: [NSAttributedString.Key: Any] = [
                    .font: rpmFont,
                    .foregroundColor: textColor
                ]
                let tempAttrs: [NSAttributedString.Key: Any] = [
                    .font: tempFont,
                    .foregroundColor: textColor
                ]

                let leftStr = "\(leftRpm) rpm" as NSString
                let rightStr = "\(rightRpm) rpm" as NSString
                let wLeft = leftStr.size(withAttributes: rpmAttrs).width
                let wRight = rightStr.size(withAttributes: rpmAttrs).width
                let maxRpmW = max(wLeft, wRight)

                // Top Line (Left Fan)
                leftStr.draw(at: CGPoint(x: 0, y: 11), withAttributes: rpmAttrs)
                // Bottom Line (Right Fan)
                rightStr.draw(at: CGPoint(x: 0, y: 1), withAttributes: rpmAttrs)

                // Vertically Centered Temperature
                let tempStr = "\(temp)°C" as NSString
                let tSize = tempStr.size(withAttributes: tempAttrs)
                let tempX = maxRpmW + 8.0
                let tempY = (bounds.height - tSize.height) / 2.0
                tempStr.draw(at: CGPoint(x: tempX, y: tempY), withAttributes: tempAttrs)
            } else {
                let font = NSFont.systemFont(ofSize: 12.0, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
                let str = "\(leftRpm) rpm   \(temp)°C" as NSString
                let size = str.size(withAttributes: attrs)
                let y = (bounds.height - size.height) / 2.0
                str.draw(at: CGPoint(x: 0, y: y), withAttributes: attrs)
            }

        case .singleLineAvg:
            let font = NSFont.systemFont(ofSize: 12.0, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let avg = (leftRpm + rightRpm) / max(1, fanCount)
            let str = "\(temp)°C • \(avg) RPM" as NSString
            let size = str.size(withAttributes: attrs)
            let y = (bounds.height - size.height) / 2.0
            str.draw(at: CGPoint(x: 0, y: y), withAttributes: attrs)

        case .singleLineDual:
            let font = NSFont.systemFont(ofSize: 12.0, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let str = "\(leftRpm) / \(rightRpm) RPM • \(temp)°C" as NSString
            let size = str.size(withAttributes: attrs)
            let y = (bounds.height - size.height) / 2.0
            str.draw(at: CGPoint(x: 0, y: y), withAttributes: attrs)
        }
    }
}
