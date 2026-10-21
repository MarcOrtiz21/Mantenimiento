import Foundation

public enum FanHelperProtocol {
    public static let greeting = "pong-v3"
    public static let responseTimeout: TimeInterval = 25
    public static let leaseDuration: TimeInterval = 30
}

public struct FanHelperRequest {
    public enum Command: Equatable {
        case ping, heartbeat, turbo, autoAll
        case set(Int, Float)
        case auto(Int)

        public var changesManualControl: Bool {
            switch self {
            case .set, .turbo: return true
            default: return false
            }
        }
    }

    public let id: UUID?
    public let command: Command

    public static func parse(_ text: String) throws -> FanHelperRequest {
        guard text.utf8.count <= 256, !text.contains("\n"), !text.contains("\r") else {
            throw ProtocolError.invalidRequest
        }
        var parts = text.split(separator: " ").map(String.init)
        var id: UUID?
        if parts.first == "request" {
            guard parts.count >= 3, let parsedID = UUID(uuidString: parts[1]) else {
                throw ProtocolError.invalidRequest
            }
            id = parsedID
            parts.removeFirst(2)
        }
        let command: Command
        switch parts {
        case ["ping"]: command = .ping
        case ["heartbeat"]: command = .heartbeat
        case ["turbo"]: command = .turbo
        case ["auto-all"]: command = .autoAll
        default:
            if parts.count == 3, parts[0] == "set", let index = Int(parts[1]), (0..<16).contains(index),
               let rpm = Float(parts[2]), rpm.isFinite, rpm > 0, rpm <= 100_000 {
                command = .set(index, rpm)
            } else if parts.count == 2, parts[0] == "auto", let index = Int(parts[1]), (0..<16).contains(index) {
                command = .auto(index)
            } else {
                throw ProtocolError.invalidRequest
            }
        }
        guard !command.changesManualControl || id != nil else { throw ProtocolError.invalidRequest }
        return FanHelperRequest(id: id, command: command)
    }

    public enum ProtocolError: LocalizedError {
        case invalidRequest
        public var errorDescription: String? { "Petición del helper inválida o incompatible." }
    }
}

public struct ManualFanLease {
    public private(set) var ownerPID: Int32?
    public private(set) var deadline: TimeInterval?

    public init() {}

    public mutating func begin(pid: Int32, now: TimeInterval) {
        ownerPID = pid
        deadline = now + FanHelperProtocol.leaseDuration
    }

    public mutating func renew(pid: Int32, now: TimeInterval) -> Bool {
        guard ownerPID == pid, let deadline, now < deadline else { return false }
        self.deadline = now + FanHelperProtocol.leaseDuration
        return true
    }

    public func needsRecovery(now: TimeInterval, ownerIsAlive: Bool) -> Bool {
        guard let deadline else { return false }
        return !ownerIsAlive || now >= deadline
    }

    public mutating func clear() {
        ownerPID = nil
        deadline = nil
    }
}
