import Foundation
import MantenimientoCore

@main
struct MantenimientoFanTool {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        if command == "status-json" {
            let data = try JSONEncoder.pretty.encode(StatusSummary.capture())
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        let service = try FanService.make()

        switch command {
        case "list-json":
            let snapshot = try service.snapshot()
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))

        case "sensors-json":
            let snapshot = try SensorService.make().snapshot()
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))

        case "system-json":
            let snapshot = SystemTelemetryService.snapshot()
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))

        case "set":
            guard args.count == 3, let fan = Int(args[1]), let rpm = Float(args[2]) else {
                throw ToolError.invalidArguments
            }
            let strategy = try service.setFanRPM(index: fan, rpm: rpm)
            print("fan \(fan) set to \(Int(rpm)) rpm (\(strategy.rawValue))")

        case "auto":
            guard args.count == 2, let fan = Int(args[1]) else {
                throw ToolError.invalidArguments
            }
            try service.setFanAuto(index: fan)
            print("fan \(fan) returned to auto")

        case "auto-all":
            try service.setAllFansAuto()
            print("all fans returned to auto")

        case "turbo":
            try service.setAllFansToMaximum()
            print("all fans set to maximum")

        default:
            printUsage()
        }
    }

    private static func printUsage() {
        print("""
        uso:
          mantenimiento-fanctl status-json
          mantenimiento-fanctl list-json
          mantenimiento-fanctl sensors-json
          mantenimiento-fanctl system-json
          mantenimiento-fanctl set <fan> <rpm>
          mantenimiento-fanctl auto <fan>
          mantenimiento-fanctl auto-all
          mantenimiento-fanctl turbo
        """)
    }
}

/// Resumen compacto pensado para scripts; las lecturas SMC que fallen quedan a `null`.
struct StatusSummary: Codable {
    struct Fan: Codable {
        let index: Int
        let rpm: Int
        let mode: String
    }

    struct Battery: Codable {
        let percent: Int
        let charging: Bool
        let pluggedIn: Bool
        let healthPercent: Int?
        let cycleCount: Int?
        let powerWatts: Double?
    }

    let date: Date
    let uptimeSeconds: Int
    let thermalState: String
    let cpuUsagePercent: Double?
    let loadAverage: [Double]
    let memoryUsedPercent: Double?
    let memoryPressureLevel: Int
    let swapUsedBytes: UInt64
    let diskAvailableBytes: UInt64
    let diskTotalBytes: UInt64
    let hottestTemperatureCelsius: Double?
    let fans: [Fan]?
    let battery: Battery?

    static func capture() -> StatusSummary {
        let first = SystemTelemetryService.snapshot()
        Thread.sleep(forTimeInterval: 0.5)
        let current = SystemTelemetryService.snapshot()

        let totalDelta = current.cpu.totalTicks &- first.cpu.totalTicks
        let activeDelta = current.cpu.totalActiveTicks &- first.cpu.totalActiveTicks
        let cpuUsage = current.cpu.totalTicks > first.cpu.totalTicks && activeDelta <= totalDelta
            ? (Double(activeDelta) / Double(totalDelta) * 1000).rounded() / 10
            : nil

        let memory = current.memory
        let hottest = (try? SensorService.make().snapshot())?.hottestTemperature.map { (Double($0.value) * 10).rounded() / 10 }
        let fans = (try? FanService.make().snapshot())?.fans.map {
            Fan(index: $0.index, rpm: Int($0.actualRPM.rounded()), mode: $0.mode.rawValue)
        }
        let battery = current.battery.map {
            Battery(
                percent: $0.percent,
                charging: $0.isCharging,
                pluggedIn: $0.externalConnected,
                healthPercent: $0.healthPercent,
                cycleCount: $0.cycleCount,
                powerWatts: $0.batteryPowerWatts.map { ($0 * 10).rounded() / 10 }
            )
        }

        return StatusSummary(
            date: Date(),
            uptimeSeconds: Int(ProcessInfo.processInfo.systemUptime),
            thermalState: thermalStateName(ProcessInfo.processInfo.thermalState),
            cpuUsagePercent: cpuUsage,
            loadAverage: current.cpu.loadAverage.map { ($0 * 100).rounded() / 100 },
            memoryUsedPercent: memory.isAvailable ? (Double(memory.usedBytes) / Double(memory.totalBytes) * 1000).rounded() / 10 : nil,
            memoryPressureLevel: memory.pressureLevel,
            swapUsedBytes: current.swap.usedBytes,
            diskAvailableBytes: current.disk.availableBytes,
            diskTotalBytes: current.disk.totalBytes,
            hottestTemperatureCelsius: hottest,
            fans: fans,
            battery: battery
        )
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

private enum ToolError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        "Argumentos invalidos."
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
