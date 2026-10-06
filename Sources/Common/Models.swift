import Foundation
import Combine

// MARK: - Curve Point
public struct CurvePoint: Identifiable, Codable, Equatable, Hashable {
    public var id: UUID
    public var temp: Double       // Temperature in Celsius (typically 30..100)
    public var fanPercent: Double // Fan speed percentage (0..100)

    public init(id: UUID = UUID(), temp: Double, fanPercent: Double) {
        self.id = id
        self.temp = max(20.0, min(105.0, temp))
        self.fanPercent = max(0.0, min(100.0, fanPercent))
    }
}

// MARK: - Fan Mode
public enum FanMode: String, Codable, CaseIterable {
    case auto = "macOS Auto"
    case curve = "Curve Control"
    case manual = "Manual Fixed"
    case turbo = "100% Turbo"

    public var systemIcon: String {
        switch self {
        case .auto: return "apple.logo"
        case .curve: return "waveform.path.ecg"
        case .manual: return "slider.horizontal.3"
        case .turbo: return "bolt.fill"
        }
    }

    public var description: String {
        switch self {
        case .auto: return "System firmware automatically manages fan RPM"
        case .curve: return "Dynamically adjusting fan speed according to active thermal curve"
        case .manual: return "Fixed target RPM commanded directly"
        case .turbo: return "Emergency maximum cooling (100% fan speed)"
        }
    }
}

// MARK: - Fan Profile Preset
public enum ProfilePreset: String, Codable, CaseIterable {
    case silent = "Silent"
    case balanced = "Balanced"
    case performance = "Performance"
    case custom = "Custom"

    public var icon: String {
        switch self {
        case .silent: return "moon.stars.fill"
        case .balanced: return "leaf.fill"
        case .performance: return "flame.fill"
        case .custom: return "slider.vertical.3"
        }
    }

    public var defaultPoints: [CurvePoint] {
        switch self {
        case .silent:
            return [
                CurvePoint(temp: 35.0, fanPercent: 0.0),
                CurvePoint(temp: 55.0, fanPercent: 0.0),
                CurvePoint(temp: 70.0, fanPercent: 35.0),
                CurvePoint(temp: 85.0, fanPercent: 70.0),
                CurvePoint(temp: 95.0, fanPercent: 100.0)
            ]
        case .balanced:
            return [
                CurvePoint(temp: 35.0, fanPercent: 15.0),
                CurvePoint(temp: 50.0, fanPercent: 28.0),
                CurvePoint(temp: 65.0, fanPercent: 50.0),
                CurvePoint(temp: 80.0, fanPercent: 78.0),
                CurvePoint(temp: 95.0, fanPercent: 100.0)
            ]
        case .performance:
            return [
                CurvePoint(temp: 35.0, fanPercent: 30.0),
                CurvePoint(temp: 45.0, fanPercent: 55.0),
                CurvePoint(temp: 60.0, fanPercent: 75.0),
                CurvePoint(temp: 75.0, fanPercent: 92.0),
                CurvePoint(temp: 90.0, fanPercent: 100.0)
            ]
        case .custom:
            return [
                CurvePoint(temp: 40.0, fanPercent: 20.0),
                CurvePoint(temp: 60.0, fanPercent: 45.0),
                CurvePoint(temp: 75.0, fanPercent: 70.0),
                CurvePoint(temp: 90.0, fanPercent: 100.0)
            ]
        }
    }
}

// MARK: - Live Fan Data
public struct FanData: Identifiable, Equatable {
    public var id: Int { index }
    public var index: Int
    public var name: String
    public var currentRPM: Double
    public var rawRPM: Double
    public var displayRPM: Int
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double
    public var modeRaw: Int

    public var percentage: Double {
        guard maxRPM > minRPM else { return 0.0 }
        let clamped = max(minRPM, min(maxRPM, currentRPM))
        return ((clamped - minRPM) / (maxRPM - minRPM)) * 100.0
    }

    public var targetPercentage: Double {
        guard maxRPM > minRPM else { return 0.0 }
        let clamped = max(minRPM, min(maxRPM, targetRPM))
        return ((clamped - minRPM) / (maxRPM - minRPM)) * 100.0
    }

    public init(
        index: Int,
        name: String = "",
        currentRPM: Double = 0,
        rawRPM: Double = 0,
        displayRPM: Int? = nil,
        minRPM: Double = 1200,
        maxRPM: Double = 6000,
        targetRPM: Double = 0,
        modeRaw: Int = 0
    ) {
        self.index = index
        self.name = name.isEmpty ? "Fan #\(index + 1)" : name
        self.currentRPM = currentRPM
        self.rawRPM = rawRPM > 0 ? rawRPM : currentRPM
        self.displayRPM = displayRPM ?? Int((currentRPM / 10.0).rounded() * 10.0)
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.modeRaw = modeRaw
    }
}

// MARK: - Menu Bar Temperature Display Mode
public enum MenuBarTempSource: String, CaseIterable, Identifiable, Codable {
    case cpuAverage = "CPU Core Average"
    case cpuPeak = "Peak CPU Core (Hottest Core)"

    public var id: String { rawValue }
    public var shortName: String {
        switch self {
        case .cpuAverage: return "Avg"
        case .cpuPeak: return "Peak"
        }
    }
}

// MARK: - Menu Bar Layout Style
public enum MenuBarLayoutStyle: String, CaseIterable, Identifiable, Codable {
    case stackedDual = "Stacked Dual (Macs Fan Control style)"
    case singleLineAvg = "Single Line Average"
    case singleLineDual = "Single Line Both Fans"

    public var id: String { rawValue }
}

// MARK: - Thermal Data
public struct ThermalData: Equatable {
    public var cpuAvg: Double
    public var cpuPeak: Double
    public var rawCpuAvg: Double
    public var rawCpuPeak: Double
    public var battery: Double
    public var storage: Double
    public var thermalPressure: ProcessInfo.ThermalState

    public init(
        cpuAvg: Double = 45.0,
        cpuPeak: Double = 50.0,
        rawCpuAvg: Double? = nil,
        rawCpuPeak: Double? = nil,
        battery: Double = 32.0,
        storage: Double = 36.0,
        thermalPressure: ProcessInfo.ThermalState = .nominal
    ) {
        self.cpuAvg = cpuAvg
        self.cpuPeak = cpuPeak
        self.rawCpuAvg = rawCpuAvg ?? cpuAvg
        self.rawCpuPeak = rawCpuPeak ?? cpuPeak
        self.battery = battery
        self.storage = storage
        self.thermalPressure = thermalPressure
    }

    public var pressureDescription: String {
        switch thermalPressure {
        case .nominal: return "Nominal (Cool)"
        case .fair: return "Fair (Warm)"
        case .serious: return "Serious (Throttling)"
        case .critical: return "Critical (Emergency)"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - UI Presentation State
public final class UIState: ObservableObject {
    @Published public var showingSettings: Bool = false
    @Published public var selectedPointID: UUID? = nil
    @Published public var draggingPointID: UUID? = nil
    @Published public var hoveredPointID: UUID? = nil

    public init() {}
}
