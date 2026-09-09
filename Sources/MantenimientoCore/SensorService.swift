import Foundation

public enum SensorGroup: String, Codable, CaseIterable {
    case cpu = "CPU"
    case gpu = "GPU"
    case system = "Sistema"
    case memory = "Memoria"
}

public enum SensorType: String, Codable, CaseIterable {
    case temperature = "Temperatura"
    case voltage = "Voltaje"
    case power = "Potencia"
    case current = "Corriente"

    public var unit: String {
        switch self {
        case .temperature:
            return "C"
        case .voltage:
            return "V"
        case .power:
            return "W"
        case .current:
            return "A"
        }
    }
}

public struct SensorKey: Codable {
    public let key: String
    public let name: String
    public let group: SensorGroup
    public let type: SensorType
}

public struct SensorReading: Codable, Identifiable {
    public var id: String { sensor.key }

    public let sensor: SensorKey
    public let value: Float
}

public struct SensorSnapshot: Codable {
    public let readings: [SensorReading]

    public var temperatures: [SensorReading] {
        readings.filter { $0.sensor.type == .temperature }
    }

    public var hottestTemperature: SensorReading? {
        temperatures.max { $0.value < $1.value }
    }

    public func readings(type: SensorType, group: SensorGroup? = nil) -> [SensorReading] {
        readings
            .filter { $0.sensor.type == type && (group == nil || $0.sensor.group == group) }
            .sorted { lhs, rhs in
                if lhs.sensor.group.rawValue == rhs.sensor.group.rawValue {
                    return lhs.sensor.name < rhs.sensor.name
                }
                return lhs.sensor.group.rawValue < rhs.sensor.group.rawValue
            }
    }
}

public final class SensorService {
    private let connection: SMCConnection

    public init(connection: SMCConnection) {
        self.connection = connection
    }

    public static func make() throws -> SensorService {
        SensorService(connection: try SMCConnection())
    }

    public func snapshot() -> SensorSnapshot {
        let readings = SensorCatalog.keysForCurrentHardware().compactMap { sensor -> SensorReading? in
            guard let result = try? connection.readKey(sensor.key) else {
                return nil
            }

            let value = SMCDataFormat.float(from: result.bytes, size: result.size)
            guard isPlausible(value: value, for: sensor.type) else {
                return nil
            }

            return SensorReading(sensor: sensor, value: value)
        }

        return SensorSnapshot(readings: readings)
    }

    private func isPlausible(value: Float, for type: SensorType) -> Bool {
        guard value.isFinite else {
            return false
        }

        switch type {
        case .temperature:
            return value >= 15 && value < 130
        case .voltage:
            return value >= 1 && value < 80
        case .power:
            return value >= 0.05 && value < 500
        case .current:
            return value >= 0.05 && value < 300
        }
    }
}

public enum SensorCatalog {
    private static let crossPlatform: [SensorKey] = [
        SensorKey(key: "TC0D", name: "CPU diode", group: .cpu, type: .temperature),
        SensorKey(key: "TC0E", name: "CPU virtual", group: .cpu, type: .temperature),
        SensorKey(key: "TC0F", name: "CPU filtered", group: .cpu, type: .temperature),
        SensorKey(key: "TC0H", name: "CPU heatsink", group: .cpu, type: .temperature),
        SensorKey(key: "TC0P", name: "CPU proximity", group: .cpu, type: .temperature),
        SensorKey(key: "TCAD", name: "CPU package", group: .cpu, type: .temperature),
        SensorKey(key: "TG0D", name: "GPU diode", group: .gpu, type: .temperature),
        SensorKey(key: "TG0H", name: "GPU heatsink", group: .gpu, type: .temperature),
        SensorKey(key: "TG0P", name: "GPU proximity", group: .gpu, type: .temperature),
        SensorKey(key: "Tm0P", name: "Mainboard", group: .system, type: .temperature),
        SensorKey(key: "TB1T", name: "Battery", group: .system, type: .temperature),
        SensorKey(key: "PCPC", name: "CPU package", group: .cpu, type: .power),
        SensorKey(key: "PCTR", name: "CPU total", group: .cpu, type: .power),
        SensorKey(key: "PG0C", name: "GPU", group: .gpu, type: .power),
        SensorKey(key: "PSTR", name: "System total", group: .system, type: .power),
        SensorKey(key: "PPBR", name: "Battery", group: .system, type: .power),
        SensorKey(key: "PDTR", name: "DC in", group: .system, type: .power),
        SensorKey(key: "VCAC", name: "CPU IA", group: .cpu, type: .voltage),
        SensorKey(key: "VG0C", name: "GPU", group: .gpu, type: .voltage),
        SensorKey(key: "VD0R", name: "DC in", group: .system, type: .voltage),
        SensorKey(key: "IC0R", name: "CPU", group: .cpu, type: .current),
        SensorKey(key: "IG0R", name: "GPU", group: .gpu, type: .current),
        SensorKey(key: "IBAC", name: "Battery", group: .system, type: .current),
    ]

    private static let m4: [SensorKey] = [
        SensorKey(key: "Te05", name: "CPU E-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Te0S", name: "CPU E-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Te09", name: "CPU E-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Te0H", name: "CPU E-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tp01", name: "CPU P-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Tp05", name: "CPU P-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Tp09", name: "CPU P-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0D", name: "CPU P-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0V", name: "CPU P-core 5", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0Y", name: "CPU P-core 6", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0b", name: "CPU P-core 7", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0e", name: "CPU P-core 8", group: .cpu, type: .temperature),
        SensorKey(key: "Tg1U", name: "GPU 1", group: .gpu, type: .temperature),
        SensorKey(key: "Tg1k", name: "GPU 2", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0K", name: "GPU 3", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0L", name: "GPU 4", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0d", name: "GPU 5", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0e", name: "GPU 6", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0j", name: "GPU 7", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0k", name: "GPU 8", group: .gpu, type: .temperature),
        SensorKey(key: "Tm0p", name: "Memory 1", group: .memory, type: .temperature),
        SensorKey(key: "Tm1p", name: "Memory 2", group: .memory, type: .temperature),
        SensorKey(key: "Tm2p", name: "Memory 3", group: .memory, type: .temperature),
    ]

    private static let m3: [SensorKey] = [
        SensorKey(key: "Te05", name: "CPU E-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Te0L", name: "CPU E-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Te0P", name: "CPU E-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Te0S", name: "CPU E-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tf04", name: "CPU P-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Tf09", name: "CPU P-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Tf0A", name: "CPU P-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Tf0B", name: "CPU P-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tf0D", name: "CPU P-core 5", group: .cpu, type: .temperature),
        SensorKey(key: "Tf0E", name: "CPU P-core 6", group: .cpu, type: .temperature),
        SensorKey(key: "Tf14", name: "GPU 1", group: .gpu, type: .temperature),
        SensorKey(key: "Tf18", name: "GPU 2", group: .gpu, type: .temperature),
        SensorKey(key: "Tf19", name: "GPU 3", group: .gpu, type: .temperature),
        SensorKey(key: "Tf1A", name: "GPU 4", group: .gpu, type: .temperature),
    ]

    private static let m2: [SensorKey] = [
        SensorKey(key: "Tp1h", name: "CPU E-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Tp1t", name: "CPU E-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Tp1p", name: "CPU E-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Tp1l", name: "CPU E-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tp01", name: "CPU P-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Tp05", name: "CPU P-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Tp09", name: "CPU P-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0D", name: "CPU P-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tg0f", name: "GPU 1", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0j", name: "GPU 2", group: .gpu, type: .temperature),
    ]

    private static let m1: [SensorKey] = [
        SensorKey(key: "Tp09", name: "CPU E-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0T", name: "CPU E-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Tp01", name: "CPU P-core 1", group: .cpu, type: .temperature),
        SensorKey(key: "Tp05", name: "CPU P-core 2", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0D", name: "CPU P-core 3", group: .cpu, type: .temperature),
        SensorKey(key: "Tp0H", name: "CPU P-core 4", group: .cpu, type: .temperature),
        SensorKey(key: "Tg05", name: "GPU 1", group: .gpu, type: .temperature),
        SensorKey(key: "Tg0D", name: "GPU 2", group: .gpu, type: .temperature),
        SensorKey(key: "Tm02", name: "Memory 1", group: .memory, type: .temperature),
        SensorKey(key: "Tm06", name: "Memory 2", group: .memory, type: .temperature),
    ]

    public static func keysForCurrentHardware() -> [SensorKey] {
        let model = hardwareModel()
        let platformKeys: [SensorKey]

        if model.hasPrefix("Mac16") {
            platformKeys = m4
        } else if model.hasPrefix("Mac15") || model.hasPrefix("Mac14") {
            platformKeys = m3
        } else if model.hasPrefix("Mac13") {
            platformKeys = m2
        } else if model.hasPrefix("Mac12") || model.hasPrefix("MacBookPro18") || model.hasPrefix("MacBookAir10") {
            platformKeys = m1
        } else {
            platformKeys = []
        }

        return platformKeys + crossPlatform
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
    }
}
