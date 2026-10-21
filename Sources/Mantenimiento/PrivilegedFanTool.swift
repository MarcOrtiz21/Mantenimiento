import Foundation
import MantenimientoCore

enum PrivilegedFanTool {
    private static let operationLock = NSLock()

    static func setFanRPM(index: Int, rpm: Float) throws -> String {
        guard rpm.isFinite, rpm > 0, rpm <= 100_000 else { throw FanControlError.invalidLimits }
        return try run(arguments: ["set", String(index), String(Int(rpm.rounded()))], manual: true)
    }

    static func setFanAuto(index: Int) throws -> String {
        try run(arguments: ["auto", String(index)])
    }

    static func setAllFansAuto() throws -> String {
        try run(arguments: ["auto-all"])
    }

    static func setAllFansTurbo() throws -> String {
        try run(arguments: ["turbo"], manual: true)
    }

    static func heartbeat() throws {
        _ = try PrivilegedHelperClient.run(arguments: ["heartbeat"], timeout: FanHelperProtocol.responseTimeout)
    }

    static func shouldRetryPrivileged(_ error: Error) -> Bool {
        (error as? SMCError)?.requiresPrivileges == true
    }

    private static func run(arguments: [String], manual: Bool = false) throws -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        let greeting: String
        do { greeting = try PrivilegedHelperClient.run(arguments: ["ping"], timeout: FanHelperProtocol.responseTimeout) }
        catch { throw PrivilegedFanToolError.helperRequired }
        if manual, greeting != FanHelperProtocol.greeting { throw PrivilegedFanToolError.helperRequired }
        return try PrivilegedHelperClient.run(
            arguments: arguments,
            requestID: greeting == FanHelperProtocol.greeting ? UUID() : nil,
            timeout: FanHelperProtocol.responseTimeout
        )
    }
}

enum PrivilegedFanToolError: LocalizedError {
    case helperRequired

    var errorDescription: String? {
        "Instala o actualiza el helper de seguridad en Preferencias > Helper. Solo se pide autorización al instalarlo."
    }
}
