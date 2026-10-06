import SwiftUI

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
            // Header with instructions and action buttons
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Interactive Fan Speed Curve")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Click canvas to add control point. Drag points to adjust curve. Select and click Delete to remove.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if manager.activeMode == .auto {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("macOS Auto (Read-Only Preview)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }

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

                    // 3. Live Operating Point Marker (Puck)
                    let liveTemp = manager.currentDisplayTemp
                    let livePercent = manager.currentCommandedPercentage
                    let livePos = pointToCoord(temp: liveTemp, percent: livePercent, rect: plotRect)

                    if livePos.x >= plotRect.minX && livePos.x <= plotRect.maxX {
                        LiveMarker(
                            pos: livePos,
                            plotRect: plotRect,
                            temp: liveTemp,
                            percent: livePercent,
                            rpm: manager.fans.first?.currentRPM ?? 0
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
                            isCustom: manager.activePreset == .custom
                        )
                        .position(coord)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    handleDrag(pt: pt, location: value.location, rect: plotRect)
                                }
                                .onEnded { _ in
                                    uiState.draggingPointID = nil
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
            .frame(minHeight: 280, idealHeight: 330, maxHeight: 420)
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
                Label("Horizontal: SoC Temperature (°C)", systemImage: "thermometer.medium")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Label("Vertical: Fan Speed (% / RPM)", systemImage: "fanblades")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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

            let text = Text("\(Int(t))°")
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

        let gradient = Gradient(colors: [
            Color.cyan.opacity(0.25),
            Color.blue.opacity(0.20),
            Color.orange.opacity(0.25),
            Color.red.opacity(0.35)
        ])
        context.fill(fillPath, with: .linearGradient(gradient, startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))

        let strokeGradient = Gradient(colors: [
            Color.cyan,
            Color.blue,
            Color.orange,
            Color.red
        ])
        context.stroke(curvePath, with: .linearGradient(strokeGradient, startPoint: CGPoint(x: rect.minX, y: rect.maxY), endPoint: CGPoint(x: rect.maxX, y: rect.minY)), lineWidth: 3.0)
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
        manager.applyFanControl()
    }

    private func deleteSelectedPoint(_ id: UUID) {
        guard manager.customPoints.count > 2 else { return }
        manager.customPoints.removeAll { $0.id == id }
        uiState.selectedPointID = nil
        manager.applyFanControl()
    }

    private func resetToDefaults() {
        manager.customPoints = ProfilePreset.balanced.defaultPoints
        manager.applyFanControl()
    }
}

// MARK: - Control Point Node View
private struct ControlPointNode: View {
    let point: CurvePoint
    let coord: CGPoint
    let isSelected: Bool
    let isDragging: Bool
    let isCustom: Bool

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

            if isDragging || isSelected {
                VStack(spacing: 1) {
                    Text("\(Int(point.temp))°C • \(Int(point.fanPercent))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.85))
                        )
                }
                .offset(y: -24)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan control node at \(Int(point.temp)) degrees Celsius, \(Int(point.fanPercent)) percent speed")
        .accessibilityValue("\(Int(point.temp))°C, \(Int(point.fanPercent))%")
        .accessibilityHint(isCustom ? "Drag to adjust temperature or fan speed" : "Switch to Custom mode to edit this point")
    }
}

// MARK: - Live Operating Marker View
private struct LiveMarker: View {
    let pos: CGPoint
    let plotRect: CGRect
    let temp: Double
    let percent: Double
    let rpm: Double

    var body: some View {
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
                .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                .frame(width: 24, height: 24)
                .position(pos)

            // Core live marker dot
            Circle()
                .fill(Color.orange)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .shadow(color: .orange.opacity(0.8), radius: 6)
                .position(pos)

            // Live readout badge
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(String(format: "%.1f°C ➔ %.0f RPM (%d%%)", temp, rpm, Int(percent)))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.88))
                    .overlay(Capsule().stroke(Color.orange.opacity(0.7), lineWidth: 1))
            )
            .position(x: min(max(pos.x, plotRect.minX + 90), plotRect.maxX - 90), y: max(plotRect.minY + 20, pos.y - 24))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Live fan operating point: %.1f degrees Celsius, %.0f RPM, %d percent target", temp, rpm, Int(percent)))
    }
}
