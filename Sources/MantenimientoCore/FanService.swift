import Foundation

public enum FanMode: String, Codable {
    case automatic = "automatico"
    case manual = "manual"
    case system = "sistema"
    case unknown = "desconocido"
}

public struct FanReading: Codable {
    public let index: Int
    public let actualRPM: Float
    public let targetRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: FanMode
    public let rawMode: UInt8?

    public var safeMinimumManualRPM: Float {
        max(minRPM, 1_200)
    }

    public var displayName: String {
        "Ventilador \(index + 1)"
    }
}

public struct FanSnapshot: Codable {
    public let fans: [FanReading]
    public let modeKeyFormat: String?
    public let forceTestAvailable: Bool
    public let forceTestRawValue: UInt8?

    public var isAutomaticControlConfirmed: Bool {
        !fans.isEmpty && fans.allSatisfy { $0.mode == .automatic || $0.mode == .system }
            && (!forceTestAvailable || forceTestRawValue == 0)
    }
}

public enum FanControlStrategy: String, Codable {
    case direct
    case forceTestUnlock
}

public final class FanService {
    private let connection: SMCTransport
    private let clock: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    public init(connection: SMCTransport,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.connection = connection
        self.clock = clock
        self.sleep = sleep
    }

    public static func make() throws -> FanService {
        FanService(connection: try SMCConnection())
    }

    public func snapshot() throws -> FanSnapshot {
        let count = try fanCount()
        guard count > 0 else {
            throw SMCError.noFans
        }

        let modeKeyFormat = detectModeKeyFormat()
        let forceTestAvailable = keyExists("Ftst")
        let fans = try (0..<count).map { index in
            try readFan(index: index, modeKeyFormat: modeKeyFormat)
        }

        return FanSnapshot(
            fans: fans,
            modeKeyFormat: modeKeyFormat,
            forceTestAvailable: forceTestAvailable,
            forceTestRawValue: forceTestAvailable ? try? readRawMode(key: "Ftst") : nil
        )
    }

    public func setFanRPM(index: Int, rpm: Float) throws -> FanControlStrategy {
        let snapshot = try snapshot()
        guard let fan = snapshot.fans.first(where: { $0.index == index }) else {
            throw SMCError.noFans
        }

        guard rpm.isFinite, rpm > 0, fan.maxRPM.isFinite,
              fan.maxRPM >= fan.safeMinimumManualRPM else { throw FanControlError.invalidLimits }
        let boundedRPM = min(max(rpm, fan.safeMinimumManualRPM), fan.maxRPM)
        do {
            let strategy = try enableManualMode(index: index, snapshot: snapshot)
            try writeRPM(key: fanKey("F%dTg", index), rpm: boundedRPM)
            return strategy
        } catch {
            try recoverAfterFailure(error)
            throw error
        }
    }

    public func setFanAuto(index: Int) throws {
        let count = try fanCount()
        guard (0..<count).contains(index) else {
            throw SMCError.noFans
        }
        let format = detectModeKeyFormat()
        let forceTestAvailable = keyExists("Ftst")
        guard format != nil else { throw FanControlError.autoNotConfirmed }
        var firstError: Error?
        if let modeKey = modeKey(index: index, format: format) {
            do {
                try connection.writeKey(modeKey, bytes: [0])
            } catch {
                firstError = error
            }
        }

        let remainingManual = (0..<count)
            .filter { $0 != index }
            .contains { otherIndex in
                if let modeKey = modeKey(index: otherIndex, format: format),
                   let mode = try? readMode(key: modeKey) {
                    return mode != .automatic && mode != .system
                }
                return true
            }

        if !remainingManual, forceTestAvailable {
            do {
                try connection.writeKey("Ftst", bytes: [0])
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        try confirmAutomaticControl(indices: [index], format: format,
                                    forceTestMustBeOff: !remainingManual && forceTestAvailable,
                                    firstWriteError: firstError)
    }

    public func setAllFansAuto() throws {
        let count = try fanCount()
        let format = detectModeKeyFormat()
        let forceTestAvailable = keyExists("Ftst")
        guard format != nil || forceTestAvailable else { throw FanControlError.autoNotConfirmed }
        var firstError: Error?
        for index in 0..<count {
            if let modeKey = modeKey(index: index, format: format) {
                if let mode = try? readMode(key: modeKey), mode == .automatic || mode == .system { continue }
                do {
                    try connection.writeKey(modeKey, bytes: [0])
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }

        if forceTestAvailable, (try? readRawMode(key: "Ftst")) != 0 {
            do {
                try connection.writeKey("Ftst", bytes: [0])
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        try confirmAutomaticControl(indices: Array(0..<count), format: format,
                                    forceTestMustBeOff: forceTestAvailable,
                                    firstWriteError: firstError)
    }

    private func confirmAutomaticControl(indices: [Int], format: String?,
                                         forceTestMustBeOff: Bool, firstWriteError: Error?) throws {
        // El firmware puede aceptar la escritura antes de reflejar el modo de macOS.
        // Solo repetimos lecturas, nunca la orden de control.
        let deadline = clock() + 5
        while true {
            var confirmed = true
            var readings: [String] = []
            for index in indices {
                if let key = modeKey(index: index, format: format) {
                    if let raw = try? readRawMode(key: key) {
                        let mode = decodeMode(raw)
                        confirmed = confirmed && (mode == .automatic || mode == .system)
                        readings.append("\(key)=\(raw)")
                    } else {
                        confirmed = false
                        readings.append("\(key)=sin lectura")
                    }
                }
            }
            if forceTestMustBeOff {
                if let raw = try? readRawMode(key: "Ftst") {
                    confirmed = confirmed && raw == 0
                    readings.append("Ftst=\(raw)")
                } else {
                    confirmed = false
                    readings.append("Ftst=sin lectura")
                }
            }
            if confirmed { return }
            guard clock() < deadline else {
                let detail = readings.joined(separator: ", ")
                throw FanControlError.autoConfirmationFailed(
                    firstWriteError.map { "\(detail). \($0.localizedDescription)" } ?? detail
                )
            }
            sleep(max(0, min(0.1, deadline - clock())))
        }
    }

    public func setAllFansToMaximum() throws {
        let snapshot = try snapshot()
        let deadline = clock() + 10
        do {
            for fan in snapshot.fans {
                guard fan.maxRPM.isFinite, fan.maxRPM >= fan.safeMinimumManualRPM else {
                    throw FanControlError.invalidLimits
                }
                _ = try enableManualMode(index: fan.index, snapshot: snapshot, deadline: deadline)
                try writeRPM(key: fanKey("F%dTg", fan.index), rpm: fan.maxRPM)
            }
        } catch {
            try recoverAfterFailure(error)
            throw error
        }
    }

    private func recoverAfterFailure(_ originalError: Error) throws {
        do { try setAllFansAuto() }
        catch {
            throw FanControlError.recoveryFailed(originalError.localizedDescription, error.localizedDescription)
        }
    }

    private func fanCount() throws -> Int {
        let result = try connection.readKey("FNum")
        if result.size >= 2 {
            let count = Int(SMCDataFormat.uint16(from: result.bytes))
            guard (1...16).contains(count) else { throw SMCError.noFans }
            return count
        }
        let count = Int(SMCDataFormat.uint8(from: result.bytes))
        guard (1...16).contains(count) else { throw SMCError.noFans }
        return count
    }

    private func readFan(index: Int, modeKeyFormat: String?) throws -> FanReading {
        let actual = try readRPM(key: fanKey("F%dAc", index))
        let target = (try? readRPM(key: fanKey("F%dTg", index))) ?? 0
        let minimum = (try? readRPM(key: fanKey("F%dMn", index))) ?? 0
        let maximum = (try? readRPM(key: fanKey("F%dMx", index))) ?? 0
        guard [actual, target, minimum, maximum].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }) else {
            throw FanControlError.invalidReading
        }
        let modeKey = modeKey(index: index, format: modeKeyFormat)
        let rawMode: UInt8?
        if let modeKey {
            rawMode = try? readRawMode(key: modeKey)
        } else {
            rawMode = nil
        }
        let mode = rawMode.map(decodeMode) ?? .unknown

        return FanReading(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: minimum,
            maxRPM: maximum,
            mode: mode,
            rawMode: rawMode
        )
    }

    private func enableManualMode(index: Int, snapshot: FanSnapshot, deadline suppliedDeadline: TimeInterval? = nil) throws -> FanControlStrategy {
        let deadline = suppliedDeadline ?? (clock() + 10)
        guard clock() < deadline else { throw SMCError.timeout }
        guard let modeKey = modeKey(index: index, format: snapshot.modeKeyFormat) else {
            throw SMCError.firmware(.notFound)
        }

        do {
            try connection.writeKey(modeKey, bytes: [1])
            return .direct
        } catch {
            guard snapshot.forceTestAvailable else {
                throw error
            }
        }

        try connection.writeKey("Ftst", bytes: [1])
        sleep(0.5)

        while clock() < deadline {
            do {
                try connection.writeKey(modeKey, bytes: [1])
                return .forceTestUnlock
            } catch {
                sleep(0.1)
            }
        }

        throw SMCError.timeout
    }

    private func detectModeKeyFormat() -> String? {
        for format in ["F%dmd", "F%dMd"] {
            if keyExists(fanKey(format, 0)) {
                return format
            }
        }
        return nil
    }

    private func keyExists(_ key: String) -> Bool {
        (try? connection.fetchKeyInfo(key)) != nil
    }

    private func fanKey(_ format: String, _ index: Int) -> String {
        String(format: format, index)
    }

    private func modeKey(index: Int, format: String?) -> String? {
        guard let format else {
            return nil
        }
        return fanKey(format, index)
    }

    private func readRPM(key: String) throws -> Float {
        let result = try connection.readKey(key)
        return SMCDataFormat.float(from: result.bytes, size: result.size)
    }

    private func writeRPM(key: String, rpm: Float) throws {
        let (_, output) = try connection.fetchKeyInfo(key)
        try connection.writeKey(key, bytes: SMCDataFormat.bytes(from: rpm, size: output.keyInfo.dataSize))
    }

    private func readRawMode(key: String) throws -> UInt8 {
        let result = try connection.readKey(key)
        guard result.size == 1, result.bytes.count == 1, let raw = result.bytes.first else {
            throw FanControlError.invalidReading
        }
        return raw
    }

    private func readMode(key: String) throws -> FanMode {
        decodeMode(try readRawMode(key: key))
    }

    private func decodeMode(_ raw: UInt8) -> FanMode {
        switch raw {
        case 0:
            return .automatic
        case 1:
            return .manual
        case 3:
            return .system
        default:
            return .unknown
        }
    }
}

public enum FanControlError: LocalizedError {
    case invalidLimits
    case invalidReading
    case autoNotConfirmed
    case autoConfirmationFailed(String)
    case recoveryFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: return "Los límites RPM no son válidos; no se aplicó control manual."
        case .invalidReading: return "Los ventiladores devolvieron una lectura inválida."
        case .autoNotConfirmed: return "No se pudo confirmar la vuelta de los ventiladores a Auto."
        case .autoConfirmationFailed(let detail):
            return "No se pudo confirmar la vuelta de los ventiladores a Auto tras 5 segundos. Estado: \(detail)."
        case .recoveryFailed(let original, let recovery):
            return "\(original) La recuperación a Auto también falló: \(recovery)"
        }
    }
}
