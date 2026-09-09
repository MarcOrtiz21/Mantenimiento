import Foundation
import MantenimientoCore

enum PrivilegedFanTool {
    static func setFanRPM(index: Int, rpm: Float) throws -> String {
        try run(arguments: ["set", String(index), String(Int(rpm.rounded()))])
    }

    static func setFanAuto(index: Int) throws -> String {
        try run(arguments: ["auto", String(index)])
    }

    static func setAllFansAuto() throws -> String {
        try run(arguments: ["auto-all"])
    }

    static func setAllFansTurbo() throws -> String {
        try run(arguments: ["turbo"])
    }

    static func shouldRetryPrivileged(_ error: Error) -> Bool {
        if let smcError = error as? SMCError {
            return smcError.requiresPrivileges
        }

        return error.localizedDescription.localizedCaseInsensitiveContains("privileg")
    }

    private static func run(arguments: [String]) throws -> String {
        var helperError: Error?
        for attempt in 0..<2 {
            do {
                return try PrivilegedHelperClient.run(arguments: arguments)
            } catch {
                helperError = error
                if attempt == 0 {
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
        }

        if let helperError {
            // El fallback con autorización solo se intenta tras dos fallos breves del helper.
            // Conservamos el error para el caso de que la herramienta tampoco esté disponible.
            _ = helperError
        }

        let toolURL = try bundledToolURL()
        let command = ([toolURL.path] + arguments)
            .map(shellQuoted)
            .joined(separator: " ")

        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = errorOutput

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw PrivilegedFanToolError.failed(errorText.isEmpty ? text : errorText)
        }

        return text
    }

    private static func bundledToolURL() throws -> URL {
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let candidate = executableDirectory.appendingPathComponent("mantenimiento-fanctl")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw PrivilegedFanToolError.missingTool
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum PrivilegedFanToolError: LocalizedError {
    case missingTool
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool:
            return "No se encontró mantenimiento-fanctl dentro de la app."
        case .failed(let message):
            return message.isEmpty ? "La autorización de administrador falló o fue cancelada." : message
        }
    }
}
