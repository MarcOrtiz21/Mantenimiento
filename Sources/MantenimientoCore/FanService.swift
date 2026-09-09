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
}

public enum FanControlStrategy: String, Codable {
    case direct
    case forceTestUnlock
}

public final class FanService {
    private let connection: SMCConnection

    public init(connection: SMCConnection) {
        self.connection = connection
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
            forceTestAvailable: forceTestAvailable
        )
    }

    public func setFanRPM(index: Int, rpm: Float) throws -> FanControlStrategy {
        let snapshot = try snapshot()
        guard let fan = snapshot.fans.first(where: { $0.index == index }) else {
            throw SMCError.noFans
        }

        let boundedRPM = min(max(rpm, fan.safeMinimumManualRPM), fan.maxRPM)
        let strategy = try enableManualMode(index: index, snapshot: snapshot)
        do {
            try writeRPM(key: fanKey("F%dTg", index), rpm: boundedRPM)
        } catch {
            try? setFanAuto(index: index)
            throw error
        }
        return strategy
    }

    public func setFanAuto(index: Int) throws {
        let snapshot = try snapshot()
        guard snapshot.fans.contains(where: { $0.index == index }) else {
            throw SMCError.noFans
        }

        var firstError: Error?
        if let modeKey = modeKey(index: index, format: snapshot.modeKeyFormat) {
            do {
                try connection.writeKey(modeKey, bytes: [0])
            } catch {
                firstError = error
            }
        }

        let remainingManual = snapshot.fans
            .filter { $0.index != index }
            .contains { fan in
                if let modeKey = modeKey(index: fan.index, format: snapshot.modeKeyFormat),
                   let mode = try? readMode(key: modeKey) {
                    return mode == .manual
                }
                return false
            }

        if !remainingManual, snapshot.forceTestAvailable {
            do {
                try connection.writeKey("Ftst", bytes: [0])
                firstError = nil
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }

    public func setAllFansAuto() throws {
        let snapshot = try snapshot()
        var firstError: Error?
        for fan in snapshot.fans {
            if let modeKey = modeKey(index: fan.index, format: snapshot.modeKeyFormat) {
                do {
                    try connection.writeKey(modeKey, bytes: [0])
                } catch {
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
        }

        if snapshot.forceTestAvailable {
            do {
                try connection.writeKey("Ftst", bytes: [0])
                firstError = nil
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
    }

    public func setAllFansToMaximum() throws {
        let snapshot = try snapshot()
        var firstError: Error?

        for fan in snapshot.fans {
            do {
                _ = try enableManualMode(index: fan.index, snapshot: snapshot)
                try writeRPM(key: fanKey("F%dTg", fan.index), rpm: fan.maxRPM)
            } catch {
                if firstError == nil {
                    firstError = error
                }
                try? setFanAuto(index: fan.index)
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func fanCount() throws -> Int {
        let result = try connection.readKey("FNum")
        if result.size >= 2 {
            return Int(SMCDataFormat.uint16(from: result.bytes))
        }
        return Int(SMCDataFormat.uint8(from: result.bytes))
    }

    private func readFan(index: Int, modeKeyFormat: String?) throws -> FanReading {
        let actual = try readRPM(key: fanKey("F%dAc", index))
        let target = (try? readRPM(key: fanKey("F%dTg", index))) ?? 0
        let minimum = (try? readRPM(key: fanKey("F%dMn", index))) ?? 0
        let maximum = (try? readRPM(key: fanKey("F%dMx", index))) ?? max(actual, target, minimum)
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

    private func enableManualMode(index: Int, snapshot: FanSnapshot) throws -> FanControlStrategy {
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
        Thread.sleep(forTimeInterval: 0.5)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                try connection.writeKey(modeKey, bytes: [1])
                return .forceTestUnlock
            } catch {
                Thread.sleep(forTimeInterval: 0.1)
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
        SMCDataFormat.uint8(from: try connection.readKey(key).bytes)
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
