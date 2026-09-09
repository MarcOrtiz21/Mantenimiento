import Darwin
import Foundation

enum ExternalCommandRunner {
    static func capture(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 1.0,
        outputLimit: Int = 262_144
    ) -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let group = DispatchGroup()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.qualityOfService = .utility

        group.enter()
        process.terminationHandler = { _ in
            group.leave()
        }

        do {
            try process.run()
        } catch {
            group.leave()
            return ""
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.interrupt()
            }
            if group.wait(timeout: .now() + 0.15) == .timedOut, process.isRunning {
                process.terminate()
            }
            if group.wait(timeout: .now() + 0.15) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = group.wait(timeout: .now() + 0.15)
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let preferredData = stdoutData.isEmpty ? stderrData : stdoutData
        guard !preferredData.isEmpty else {
            return ""
        }

        let limited = preferredData.prefix(outputLimit)
        return String(data: limited, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
