import AppKit
import SwiftUI
import MantenimientoCore

extension Notification.Name {
    static let fanManualControlDidSucceed = Notification.Name("fanManualControlDidSucceed")
    static let cleanModeStartRequested = Notification.Name("cleanModeStartRequested")
    static let diagnosticsSectionRequested = Notification.Name("diagnosticsSectionRequested")
    static let fanAutomaticControlDidSucceed = Notification.Name("fanAutomaticControlDidSucceed")
    static let preferencesRequested = Notification.Name("preferencesRequested")
}

struct OverviewVerdict {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    static func make(snapshot: DashboardSnapshot, cpuUsage: Double?) -> OverviewVerdict {
        let hottest = snapshot.sensors?.hottestTemperature.map { Double($0.value) }
        let pressure = snapshot.telemetry.memory.pressureLevel
        let thermal = ProcessInfo.processInfo.thermalState

        if thermal == .critical || (hottest ?? 0) >= AppPreferences.temperatureCriticalThreshold {
            let temperature = hottest.map { "\(Int($0.rounded())) °C" } ?? snapshot.system.thermalState
            return OverviewVerdict(
                title: "Temperatura crítica",
                detail: "El Mac está en \(temperature). Baja la carga o activa Turbo si los ventiladores no responden.",
                symbol: "thermometer",
                tint: .red
            )
        }

        if thermal == .serious || (hottest ?? 0) >= AppPreferences.temperatureWarningThreshold {
            let temperature = hottest.map { "\(Int($0.rounded())) °C" } ?? snapshot.system.thermalState
            return OverviewVerdict(
                title: "Va caliente",
                detail: "Temperatura máxima \(temperature). El sistema está pidiendo más refrigeración.",
                symbol: "flame.fill",
                tint: .orange
            )
        }

        if pressure >= 3 {
            return OverviewVerdict(
                title: "Memoria justa",
                detail: "La presión de RAM es alta (\(formatPercent(snapshot.telemetry.memory.usedRatio)) usada). Cierra apps pesadas si va lento.",
                symbol: "memorychip",
                tint: .orange
            )
        }

        if pressure >= 2 {
            return OverviewVerdict(
                title: "Presión de memoria moderada",
                detail: "Hay \(formatPercent(snapshot.telemetry.memory.usedRatio)) de RAM en uso. Vigila si empiezan a comprimirse procesos.",
                symbol: "memorychip",
                tint: .yellow
            )
        }

        if let cpuUsage, cpuUsage >= 0.85 {
            return OverviewVerdict(
                title: "CPU muy ocupada",
                detail: "Uso de CPU al \(formatPercent(cpuUsage)). Mira qué proceso está cargando más abajo.",
                symbol: "cpu",
                tint: .orange
            )
        }

        if !snapshot.sensorStatus.isCurrent || !snapshot.fanStatus.isCurrent || !snapshot.telemetry.memory.isAvailable || pressure < 0 {
            return OverviewVerdict(
                title: "Lecturas incompletas",
                detail: "Hay métricas del sistema sin lectura actual fiable.",
                symbol: "exclamationmark.triangle",
                tint: .orange
            )
        }

        return OverviewVerdict(
            title: "Todo bien",
            detail: "Sin alertas térmicas ni de memoria. Estado térmico \(snapshot.system.thermalState).",
            symbol: "checkmark.seal.fill",
            tint: .green
        )
    }
}

struct SystemSnapshot {
    let model: String
    let processor: String
    let thermalState: String
    let lowPowerMode: String
    let uptime: String
    let thermalTint: Color

    static func current() -> SystemSnapshot {
        let thermal = ProcessInfo.processInfo.thermalState
        return SystemSnapshot(
            model: sysctlString("hw.model") ?? "desconocido",
            processor: sysctlString("machdep.cpu.brand_string") ?? "desconocido",
            thermalState: thermalStateDescription(thermal),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled ? "activado" : "desactivado",
            uptime: formattedUptime(ProcessInfo.processInfo.systemUptime),
            thermalTint: thermalTint(thermal)
        )
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "moderado"
        case .serious:
            return "alto"
        case .critical:
            return "crítico"
        @unknown default:
            return "desconocido"
        }
    }

    private static func thermalTint(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal:
            return .green
        case .fair:
            return .yellow
        case .serious:
            return .orange
        case .critical:
            return .red
        @unknown default:
            return .secondary
        }
    }

    private static func formattedUptime(_ uptime: TimeInterval) -> String {
        let totalMinutes = Int(uptime / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }

        return "\(hours)h \(minutes)m"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }
}

extension FanReading {
    var defaultTargetRPM: Float {
        if targetRPM >= safeMinimumManualRPM {
            return min(targetRPM, maxRPM)
        }
        return safeMinimumManualRPM
    }
}

extension Result {
    var failureDescription: String? {
        if case .failure(let error) = self {
            return error.localizedDescription
        }
        return nil
    }
}

extension Array where Element == SensorReading {
    func sortedBySensorNumber() -> [SensorReading] {
        sorted { lhs, rhs in
            let left = lhs.sensor.naturalSortParts
            let right = rhs.sensor.naturalSortParts

            if left.prefix == right.prefix {
                if left.number == right.number {
                    return lhs.sensor.key.localizedStandardCompare(rhs.sensor.key) == .orderedAscending
                }
                return left.number < right.number
            }

            return left.prefix.localizedStandardCompare(right.prefix) == .orderedAscending
        }
    }
}

extension SensorKey {
    var naturalSortParts: (prefix: String, number: Int) {
        let source = name.isEmpty ? key : name
        let digits = source
            .reversed()
            .prefix { $0.isNumber }
            .reversed()
        let number = Int(String(digits)) ?? Int.max
        let prefix = source.replacingOccurrences(of: #"[\s-]*\d+$"#, with: "", options: .regularExpression)
        return (prefix, number)
    }
}

extension NumberFormatter {
    static var rpm: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 0
        return formatter
    }
}

func formatRPM(_ value: Float) -> String {
    "\(Int(value.rounded())) RPM"
}

func formatTemperature(_ value: Float) -> String {
    String(format: "%.1f C", value)
}

func formatTemperature(_ value: Double) -> String {
    String(format: "%.1f C", value)
}

func formatTemperatureValue(_ value: Double) -> String {
    String(format: "%.1f", value)
}

func temperatureTint(_ value: Double?) -> Color {
    guard let value else {
        return .secondary
    }
    if value >= 90 {
        return .red
    }
    if value >= 75 {
        return .orange
    }
    return .green
}

func memoryPressureTint(_ level: Int) -> Color {
    if level < 0 { return .secondary }
    switch level {
    case 0...1:
        return .green
    case 2:
        return .orange
    default:
        return .red
    }
}

func formatPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.storage.string(fromByteCount: Int64(bytes))
}

func formatRate(_ bytesPerSecond: Double) -> String {
    "\(formatRateValue(bytesPerSecond)) \(rateUnit(bytesPerSecond))"
}

func formatRateValue(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded()))"
}

func rateUnit(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return "MB/s"
    }
    if bytesPerSecond >= 1_000 {
        return "KB/s"
    }
    return "B/s"
}

func batterySummary(_ battery: BatterySnapshot) -> String {
    var parts = ["\(battery.percent)%"]

    if battery.isCharged {
        parts.append("cargada")
    } else if battery.isCharging {
        parts.append("cargando")
    } else if battery.externalConnected {
        parts.append("corriente")
    }

    if let cycles = battery.cycleCount {
        parts.append("\(cycles) ciclos")
    }

    if let health = battery.healthPercent {
        parts.append("salud \(health)%")
    }

    if let temperature = battery.temperatureCelsius {
        parts.append(String(format: "%.1f C", temperature))
    }

    return parts.joined(separator: " | ")
}

func appResourceSummary(_ resources: AppResourceSnapshot) -> String {
    let cpu = resources.cpuRatio.map(formatPercent) ?? "calculando"
    return "CPU \(cpu) | RAM \(formatBytes(resources.residentMemoryBytes))"
}

func networkSummary(_ network: NetworkSnapshot) -> String {
    guard !network.interfaces.isEmpty else {
        return "sin interfaces activas"
    }

    return network.interfaces
        .prefix(3)
        .map { $0.displayName }
        .joined(separator: ", ")
}

extension ByteCountFormatter {
    static var storage: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }
}
