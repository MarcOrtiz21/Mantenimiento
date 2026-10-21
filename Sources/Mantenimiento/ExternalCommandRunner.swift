import Darwin
import Foundation

enum ExternalCommandRunner {
    static func capture(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 1.0,
        outputLimit: Int = 262_144
    ) -> String {
        guard timeout.isFinite, timeout > 0, outputLimit > 0 else { return "" }
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

        // Vaciamos ambas salidas mientras el proceso trabaja, con memoria acotada.
        let output = BoundedCommandOutput(stdout: stdout, stderr: stderr, limit: outputLimit)
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
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

        let preferredData = output.finish()
        guard !preferredData.isEmpty else {
            return ""
        }

        return String(decoding: preferredData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class BoundedCommandOutput {
    private let queue = DispatchQueue(label: "local.marc.mantenimiento.command-output", qos: .utility)
    private let readers = DispatchGroup()
    private let limit: Int
    private var sources: [DispatchSourceRead] = []
    private var stdoutData = Data()
    private var stderrData = Data()

    init(stdout: Pipe, stderr: Pipe, limit: Int) {
        self.limit = limit
        startReading(stdout.fileHandleForReading.fileDescriptor, isError: false)
        startReading(stderr.fileHandleForReading.fileDescriptor, isError: true)
    }

    private func startReading(_ descriptor: Int32, isError: Bool) {
        let fd = dup(descriptor)
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let group = readers
        group.enter()
        source.setCancelHandler {
            close(fd)
            group.leave()
        }
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8_192)
            // Un productor continuo no debe bloquear la cancelación de los lectores.
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    if isError {
                        self.stderrData.append(contentsOf: buffer.prefix(min(count, max(0, self.limit - self.stderrData.count))))
                    } else {
                        self.stdoutData.append(contentsOf: buffer.prefix(min(count, max(0, self.limit - self.stdoutData.count))))
                    }
                } else if count == 0 {
                    source?.cancel()
                    return
                } else if errno != EINTR {
                    if errno != EAGAIN && errno != EWOULDBLOCK { source?.cancel() }
                    return
                }
            }
        }
        sources.append(source)
        source.resume()
    }

    func finish() -> Data {
        // Un descendiente puede heredar el pipe: no esperamos EOF indefinidamente.
        _ = readers.wait(timeout: .now() + 0.15)
        let data = queue.sync {
            sources.forEach { $0.cancel() }
            return stdoutData.isEmpty ? stderrData : stdoutData
        }
        _ = readers.wait(timeout: .now() + 0.15)
        return data
    }
}
