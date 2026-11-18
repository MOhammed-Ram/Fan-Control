import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct CurveEditorView: View {
    @ObservedObject var manager: FanManager
    @ObservedObject var uiState: UIState

    private let minTemp: Double = 30.0
    private let maxTemp: Double = 100.0
    private let minPercent: Double = 0.0
    private let maxPercent: Double = 100.0

    public init(manager: FanManager, uiState: UIState) {
        self.manager = manager
        self.uiState = uiState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with instructions, status badge, and action buttons
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Interactive Fan Speed Curve")
                            .font(.headline)
                            .foregroundColor(.primary)

                        // Mode status badge clearly showing if curve is active or not
                        modeStatusBadge
                    }

                    Text(manager.activeMode == .curve
                        ? "Click canvas to add point. Drag or use Arrow keys to adjust. Press Delete to remove."
                        : "Curve is currently inactive (\(manager.activeMode.rawValue) in control). Showing live preview of profile & thermal operating point.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: importCurveFile) {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Import custom fan curve from JSON file")

                Button(action: exportCurveFile) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Export current fan curve to JSON file")

                if manager.activePreset == .custom {
                    Button(action: resetToDefaults) {
                        Label("Reset Curve", systemImage: "arrow.counterclockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let selID = uiState.selectedPointID, manager.customPoints.count > 2 {
                    Button(role: .destructive, action: { deleteSelectedPoint(selID) }) {
                        Label("Delete Point", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Curve Preset Selection Bar
            CurvePresetsBar(manager: manager)

            // Main Graph Canvas
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let padding = EdgeInsets(top: 24, leading: 44, bottom: 32, trailing: 24)
                let plotRect = CGRect(
                    x: padding.leading,
                    y: padding.top,
                    width: max(10, width - padding.leading - padding.trailing),
                    height: max(10, height - padding.top - padding.bottom)
                )

                ZStack {
                    // 1. Background grid
                    Canvas { context, size in
                        drawGrid(context: context, rect: plotRect)
                    }

                    // 2. Curve path (gradient fill & stroke)
                    Canvas { context, size in
                        drawCurve(context: context, rect: plotRect)
                    }

                    // Top-right corner status watermark in plot canvas
                    HStack(spacing: 5) {
                        if manager.activeMode == .curve {
                            Circle().fill(Color.blue).frame(width: 6, height: 6)
                            Text("CURVE IN USE")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                            Text("CURVE NOT IN USE (\(manager.activeMode.rawValue.uppercased()))")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    )
                    .position(x: max(plotRect.minX + 110, plotRect.maxX - 110), y: plotRect.minY + 16)

                    // 3. Live Operating Point Marker (Puck - Locked directly to curve line)
                    let drivingTemp = manager.curveDrivingTemp
                    let curvePercent = CurveEngine.evaluateOnCurve(temp: drivingTemp, points: manager.activePoints)
                    let livePos = pointToCoord(temp: drivingTemp, percent: curvePercent, rect: plotRect)

                    if livePos.x >= plotRect.minX && livePos.x <= plotRect.maxX {
                        LiveMarker(
                            pos: livePos,
                            plotRect: plotRect,
                            temp: drivingTemp,
                            percent: curvePercent,
                            rpm: manager.fans.first?.currentRPM ?? 0,
                            activeMode: manager.activeMode,
                            temperatureUnit: manager.temperatureUnit
                        )
                    }

                    // 4. Control Points (Interactive Draggable Nodes)
                    ForEach(manager.activePoints) { pt in
                        let coord = pointToCoord(temp: pt.temp, percent: pt.fanPercent, rect: plotRect)
                        let isSelected = (uiState.selectedPointID == pt.id)
                        let isDragging = (uiState.draggingPointID == pt.id)

                        ControlPointNode(
                            point: pt,
                            coord: coord,
                            isSelected: isSelected,
                            isDragging: isDragging,
                            isCustom: manager.activePreset == .custom,
                            temperatureUnit: manager.temperatureUnit
                        )
                        .position(coord)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    handleDrag(pt: pt, location: value.location, rect: plotRect)
                                }
                                .onEnded { _ in
                                    uiState.draggingPointID = nil
                                    manager.saveSettings()
                                }
                        )
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                uiState.selectedPointID = pt.id
                            }
                        )
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleCanvasTap(location: location, rect: plotRect)
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )

            // X and Y axis legends
            HStack {
                Label("Horizontal: SoC Temperature (\(manager.temperatureUnit.symbol))", systemImage: "thermometer.medium")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Label("Vertical: Fan Speed (% / RPM)", systemImage: "fanblades")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .onAppear {
            setupKeyboardMonitor()
        }
        .onDisappear {
            if let monitor = uiState.keyMonitor {
                NSEvent.removeMonitor(monitor)
                uiState.keyMonitor = nil
            }
        }
    }

    // MARK: - Canvas Drawing
    private func drawGrid(context: GraphicsContext, rect: CGRect) {
        let temps: [Double] = [30, 40, 50, 60, 70, 80, 90, 100]
        for t in temps {
            let x = rect.minX + CGFloat((t - minTemp) / (maxTemp - minTemp)) * rect.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(path, with: .color(Color.primary.opacity(0.06)), lineWidth: 1)

            let displayTemp = Int(manager.temperatureUnit.fromCelsius(t).rounded())
            let text = Text("\(displayTemp)°")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.secondary)
            context.draw(text, at: CGPoint(x: x, y: rect.maxY + 14), anchor: .center)
        }

        let percents: [Double] = [0, 25, 50, 75, 100]
        for p in percents {
            let y = rect.maxY - CGFloat((p - minPercent) / (maxPercent - minPercent)) * rect.height
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(path, with: .color(Color.primary.opacity(0.06)), lineWidth: 1)

            let text = Text("\(Int(p))%")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.secondary)
            context.draw(text, at: CGPoint(x: rect.minX - 22, y: y), anchor: .center)
        }

        context.stroke(Path(rect), with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
    }

    @ViewBuilder
    private var modeStatusBadge: some View {
        switch manager.activeMode {
        case .curve:
            HStack(spacing: 5) {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
                Text("Active (In Control)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.blue.opacity(0.12)))

        case .auto:
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("Not in Use • macOS Auto Active")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)

                Button("Activate Curve") {
                    withAnimation { manager.setMode(.curve) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.12)))

        case .manual:
            HStack(spacing: 6) {
                Circle().fill(Color.orange).frame(width: 7, height: 7)
                Text("Not in Use • Manual Fixed Active")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)

                Button("Activate Curve") {
                    withAnimation { manager.setMode(.curve) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.12)))

        case .turbo:
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("Not in Use • 100% Turbo Active")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)

                Button("Switch to Curve") {
                    withAnimation { manager.setMode(.curve) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.12)))
        }
    }

    private func drawCurve(context: GraphicsContext, rect: CGRect) {
        let samples = CurveEngine.sampleCurve(points: manager.activePoints, minTemp: minTemp, maxTemp: maxTemp, steps: 120)
        guard samples.count > 1 else { return }

        var curvePath = Path()
        var fillPath = Path()

        let firstPt = pointToCoord(temp: samples[0].temp, percent: samples[0].percent, rect: rect)
        curvePath.move(to: firstPt)
        fillPath.move(to: CGPoint(x: firstPt.x, y: rect.maxY))
        fillPath.addLine(to: firstPt)

        for i in 1..<samples.count {
            let pt = pointToCoord(temp: samples[i].temp, percent: samples[i].percent, rect: rect)
            curvePath.addLine(to: pt)
            fillPath.addLine(to: pt)
        }

        let lastPt = pointToCoord(temp: samples.last!.temp, percent: samples.last!.percent, rect: rect)
        fillPath.addLine(to: CGPoint(x: lastPt.x, y: rect.maxY))
        fillPath.closeSubpath()

        let isCurveInUse = (manager.activeMode == .curve)
        let fillMultiplier: Double = isCurveInUse ? 1.0 : 0.40
        let strokeAlpha: Double = isCurveInUse ? 1.0 : 0.55

        let gradient = Gradient(colors: [
            Color.cyan.opacity(0.25 * fillMultiplier),
            Color.blue.opacity(0.20 * fillMultiplier),
            Color.orange.opacity(0.25 * fillMultiplier),
            Color.red.opacity(0.35 * fillMultiplier)
        ])
        context.fill(fillPath, with: .linearGradient(gradient, startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))

        let strokeGradient = Gradient(colors: [
            Color.cyan.opacity(strokeAlpha),
            Color.blue.opacity(strokeAlpha),
            Color.orange.opacity(strokeAlpha),
            Color.red.opacity(strokeAlpha)
        ])
        context.stroke(
            curvePath,
            with: .linearGradient(strokeGradient, startPoint: CGPoint(x: rect.minX, y: rect.maxY), endPoint: CGPoint(x: rect.maxX, y: rect.minY)),
            style: StrokeStyle(lineWidth: isCurveInUse ? 3.0 : 2.0, dash: isCurveInUse ? [] : [6, 4])
        )
    }

    // MARK: - Coordinate Transformations
    private func pointToCoord(temp: Double, percent: Double, rect: CGRect) -> CGPoint {
        let clTemp = max(minTemp, min(maxTemp, temp))
        let clPercent = max(minPercent, min(maxPercent, percent))
        let x = rect.minX + CGFloat((clTemp - minTemp) / (maxTemp - minTemp)) * rect.width
        let y = rect.maxY - CGFloat((clPercent - minPercent) / (maxPercent - minPercent)) * rect.height
        return CGPoint(x: x, y: y)
    }

    private func coordToPoint(coord: CGPoint, rect: CGRect) -> (temp: Double, percent: Double) {
        let normX = max(0.0, min(1.0, Double((coord.x - rect.minX) / rect.width)))
        let normY = max(0.0, min(1.0, Double((rect.maxY - coord.y) / rect.height)))
        let temp = minTemp + normX * (maxTemp - minTemp)
        let percent = minPercent + normY * (maxPercent - minPercent)
        return (temp: round(temp), percent: round(percent))
    }

    // MARK: - Interactions
    private func handleDrag(pt: CurvePoint, location: CGPoint, rect: CGRect) {
        if manager.activePreset != .custom {
            manager.selectPreset(.custom)
        }

        uiState.draggingPointID = pt.id
        uiState.selectedPointID = pt.id

        let (rawTemp, rawPercent) = coordToPoint(coord: location, rect: rect)
        if let idx = manager.customPoints.firstIndex(where: { $0.id == pt.id }) {
            // Enforce minimum 3.0°C spacing between adjacent nodes to prevent inverted or colliding splines
            let minAllowedTemp = (idx > 0) ? (manager.customPoints[idx - 1].temp + 3.0) : minTemp
            let maxAllowedTemp = (idx < manager.customPoints.count - 1) ? (manager.customPoints[idx + 1].temp - 3.0) : maxTemp

            let clampedTemp = max(minAllowedTemp, min(maxAllowedTemp, rawTemp))
            let clampedPercent = max(minPercent, min(maxPercent, rawPercent))

            manager.customPoints[idx].temp = clampedTemp
            manager.customPoints[idx].fanPercent = clampedPercent
            manager.customPoints.sort { $0.temp < $1.temp }
            manager.applyFanControl()
        }
    }

    private func handleCanvasTap(location: CGPoint, rect: CGRect) {
        guard rect.contains(location) else { return }

        if manager.activePreset != .custom {
            manager.selectPreset(.custom)
        }

        let (newTemp, newPercent) = coordToPoint(coord: location, rect: rect)

        for pt in manager.customPoints {
            if abs(pt.temp - newTemp) < 3.0 {
                uiState.selectedPointID = pt.id
                return
            }
        }

        let newPoint = CurvePoint(temp: newTemp, fanPercent: newPercent)
        manager.customPoints.append(newPoint)
        manager.customPoints.sort { $0.temp < $1.temp }
        uiState.selectedPointID = newPoint.id
        manager.saveSettings()
        manager.applyFanControl()
    }

    private func deleteSelectedPoint(_ id: UUID) {
        guard manager.customPoints.count > 2 else { return }
        if manager.activePreset != .custom {
            manager.selectPreset(.custom)
        }
        manager.customPoints.removeAll { $0.id == id }
        uiState.selectedPointID = nil
        manager.saveSettings()
        manager.applyFanControl()
    }

    private func resetToDefaults() {
        manager.customPoints = ProfilePreset.balanced.defaultPoints
        manager.saveSettings()
        manager.applyFanControl()
    }

    // MARK: - Keyboard Shortcuts (Delete, Escape & Arrow Keys)
    private func setupKeyboardMonitor() {
        guard uiState.keyMonitor == nil else { return }
        uiState.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !uiState.showingSettings && !uiState.showingAbout,
                  let selectedID = uiState.selectedPointID else {
                return event
            }

            switch event.keyCode {
            case 53: // Escape (deselect active point)
                uiState.selectedPointID = nil
                return nil
            case 51, 117: // Delete / Forward Delete
                if manager.customPoints.count > 2 {
                    deleteSelectedPoint(selectedID)
                    return nil
                }
            case 123: // Left Arrow (-1°C)
                nudgeSelectedPoint(selectedID, deltaTemp: -1.0, deltaPercent: 0.0)
                return nil
            case 124: // Right Arrow (+1°C)
                nudgeSelectedPoint(selectedID, deltaTemp: 1.0, deltaPercent: 0.0)
                return nil
            case 126: // Up Arrow (+2% fan speed)
                nudgeSelectedPoint(selectedID, deltaTemp: 0.0, deltaPercent: 2.0)
                return nil
            case 125: // Down Arrow (-2% fan speed)
                nudgeSelectedPoint(selectedID, deltaTemp: 0.0, deltaPercent: -2.0)
                return nil
            default:
                break
            }
            return event
        }
    }

    private func nudgeSelectedPoint(_ id: UUID, deltaTemp: Double, deltaPercent: Double) {
        if manager.activePreset != .custom {
            manager.selectPreset(.custom)
        }
        guard let idx = manager.customPoints.firstIndex(where: { $0.id == id }) else { return }
        let minAllowedTemp = (idx > 0) ? (manager.customPoints[idx - 1].temp + 3.0) : minTemp
        let maxAllowedTemp = (idx < manager.customPoints.count - 1) ? (manager.customPoints[idx + 1].temp - 3.0) : maxTemp

        let newTemp = max(minAllowedTemp, min(maxAllowedTemp, manager.customPoints[idx].temp + deltaTemp))
        let newPct = max(minPercent, min(maxPercent, manager.customPoints[idx].fanPercent + deltaPercent))

        manager.customPoints[idx].temp = newTemp
        manager.customPoints[idx].fanPercent = newPct
        manager.customPoints.sort { $0.temp < $1.temp }
        manager.saveSettings()
        manager.applyFanControl()
    }

    // MARK: - Import / Export JSON Curve
    private func exportCurveFile() {
        let savePanel = NSSavePanel()
        savePanel.title = "Export Fan Curve Profile"
        savePanel.nameFieldStringValue = "FanCurve-\(manager.activePreset.rawValue).json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(manager.activePoints)
                try data.write(to: url, options: .atomic)
                manager.statusMessage = "Exported curve to \(url.lastPathComponent)"
            } catch {
                manager.statusMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importCurveFile() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import Fan Curve Profile"
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            do {
                try manager.importCustomCurve(from: url)
                manager.statusMessage = "Imported curve from \(url.lastPathComponent)"
            } catch {
                manager.statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Control Point Node View
private struct ControlPointNode: View {
    let point: CurvePoint
    let coord: CGPoint
    let isSelected: Bool
    let isDragging: Bool
    let isCustom: Bool
    let temperatureUnit: TemperatureUnit

    private var tooltipYOffset: CGFloat {
        point.fanPercent >= 82.0 ? 24.0 : -24.0
    }

    private var tooltipXOffset: CGFloat {
        if point.temp <= 36.0 { return 24.0 }
        if point.temp >= 94.0 { return -24.0 }
        return 0.0
    }

    var body: some View {
        ZStack {
            if isSelected || isDragging {
                Circle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(width: 28, height: 28)
            }

            Circle()
                .fill(isSelected ? Color.accentColor : Color.white)
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.8), lineWidth: 2)
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

            if isDragging || isSelected {
                VStack(spacing: 1) {
                    Text("\(temperatureUnit.format(point.temp, decimals: 0)) • \(Int(point.fanPercent))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.88))
                        )
                }
                .offset(x: tooltipXOffset, y: tooltipYOffset)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan control node at \(temperatureUnit.format(point.temp, decimals: 0)), \(Int(point.fanPercent)) percent speed")
        .accessibilityValue("\(temperatureUnit.format(point.temp, decimals: 0)), \(Int(point.fanPercent))%")
        .accessibilityHint(isCustom ? "Drag or use arrow keys to adjust temperature or fan speed" : "Switch to Custom mode to edit this point")
    }
}

// MARK: - Live Operating Marker View
private struct LiveMarker: View {
    let pos: CGPoint
    let plotRect: CGRect
    let temp: Double
    let percent: Double
    let rpm: Double
    let activeMode: FanMode
    let temperatureUnit: TemperatureUnit

    var body: some View {
        let formattedTemp = temperatureUnit.format(temp, decimals: 1)
        let isCurveInUse = (activeMode == .curve)
        let halfBadgeWidth: CGFloat = isCurveInUse ? 105.0 : 140.0
        let badgeY: CGFloat = (pos.y < plotRect.minY + 38.0) ? (pos.y + 24.0) : (pos.y - 24.0)

        ZStack {
            // Dashed projection lines to axes
            Path { path in
                path.move(to: pos)
                path.addLine(to: CGPoint(x: pos.x, y: plotRect.maxY))
                path.move(to: pos)
                path.addLine(to: CGPoint(x: plotRect.minX, y: pos.y))
            }
            .stroke(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))

            // Outer ring
            Circle()
                .stroke((isCurveInUse ? Color.orange : Color.secondary).opacity(0.6), lineWidth: 2)
                .frame(width: 24, height: 24)
                .position(pos)

            // Core live marker dot
            Circle()
                .fill(isCurveInUse ? Color.orange : Color.gray)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: (isCurveInUse ? Color.orange : Color.black).opacity(0.6), radius: 5)
                .position(pos)

            // Live readout badge
            HStack(spacing: 4) {
                Circle().fill(isCurveInUse ? Color.green : Color.orange).frame(width: 6, height: 6)
                switch activeMode {
                case .auto:
                    Text(String(format: "%@ • %.0f RPM (macOS Auto • Inactive)", formattedTemp, rpm))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                case .manual:
                    Text(String(format: "%@ • %.0f RPM (Manual Fixed • Inactive)", formattedTemp, rpm))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                case .turbo:
                    Text(String(format: "%@ • %.0f RPM (100% Turbo • Inactive)", formattedTemp, rpm))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                case .curve:
                    Text(String(format: "%@ ➔ %.0f RPM (%d%% Target)", formattedTemp, rpm, Int(percent.rounded())))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.88))
                    .overlay(Capsule().stroke((isCurveInUse ? Color.orange : Color.secondary).opacity(0.7), lineWidth: 1))
            )
            .position(
                x: min(max(pos.x, plotRect.minX + halfBadgeWidth), plotRect.maxX - halfBadgeWidth),
                y: min(max(badgeY, plotRect.minY + 18.0), plotRect.maxY - 18.0)
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Live fan operating point: %@, %.0f RPM, %d percent target", formattedTemp, rpm, Int(percent.rounded())))
    }
}
