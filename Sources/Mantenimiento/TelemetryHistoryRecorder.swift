import Foundation
import OSLog

final class TelemetryHistoryRecorder {
    static let shared = TelemetryHistoryRecorder()

    private let queue = DispatchQueue(label: "local.marc.mantenimiento.history", qos: .utility)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento",
        category: "History"
    )
    private let sampleInterval: TimeInterval = 30
    private let retentionInterval: TimeInterval = 7 * 24 * 60 * 60
    private var lastRecordDate: Date?
    private let fileURL: URL

    private init() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directoryURL = baseURL.appendingPathComponent("Mantenimiento", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = directoryURL.appendingPathComponent("telemetry-history.csv")

        queue.async { [weak self] in
            self?.prepareFile()
            self?.pruneExpiredRows()
        }
    }

    func record(snapshot: MenuBarSnapshot) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            if let lastRecordDate, snapshot.date.timeIntervalSince(lastRecordDate) < sampleInterval {
                return
            }

            prepareFile()
            appendLine(csvLine(for: snapshot))
            lastRecordDate = snapshot.date
        }
    }

    func export(to destinationURL: URL) throws {
        try queue.sync {
            prepareFile()
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: fileURL, to: destinationURL)
        }
    }

    func clear() throws {
        try queue.sync {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            lastRecordDate = nil
            prepareFile()
        }
    }

    private func prepareFile() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        let header = "date,cpu_percent,gpu_percent,ram_percent,memory_pressure,max_temperature_c,average_rpm,system_power_w,network_down_bps,network_up_bps,disk_read_bps,disk_write_bps,battery_percent,app_cpu_percent,app_ram_bytes,thermal_state\n"
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(header.utf8))
    }

    private func appendLine(_ line: String) {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            logger.error("Could not open history file for append")
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            logger.error("History write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func csvLine(for snapshot: MenuBarSnapshot) -> String {
        let hottestTemperature = snapshot.sensors?.hottestTemperature.map { Double($0.value) }
        let averageRPM: Double? = snapshot.fans?.fans.isEmpty == false
            ? snapshot.fans.map { fans in
                fans.fans.reduce(0) { $0 + Double(max($1.actualRPM, 0)) } / Double(fans.fans.count)
            }
            : nil
        let systemPower = snapshot.sensors?.readings.first(where: { $0.sensor.key == "PSTR" }).map { Double($0.value) }

        return [
            Self.dateFormatter.string(from: snapshot.date),
            csvNumber(snapshot.cpuUsage.map { $0 * 100 }),
            csvNumber(snapshot.telemetry.gpu?.utilizationPercent),
            csvNumber(snapshot.telemetry.memory.usedRatio * 100),
            String(snapshot.telemetry.memory.pressureLevel),
            csvNumber(hottestTemperature),
            csvNumber(averageRPM),
            csvNumber(systemPower),
            csvNumber(snapshot.networkDownBps),
            csvNumber(snapshot.networkUpBps),
            csvNumber(snapshot.diskReadBps),
            csvNumber(snapshot.diskWriteBps),
            snapshot.telemetry.battery.map { String($0.percent) } ?? "",
            csvNumber(snapshot.appResources.cpuRatio.map { $0 * 100 }),
            String(snapshot.appResources.residentMemoryBytes),
            csvEscaped(snapshot.thermalState)
        ].joined(separator: ",")
    }

    private func pruneExpiredRows() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first, lines.count > 1 else {
            return
        }

        let cutoff = Date().addingTimeInterval(-retentionInterval)
        let retained = lines.dropFirst().filter { line in
            guard let firstField = line.split(separator: ",", maxSplits: 1).first,
                  let date = Self.dateFormatter.date(from: String(firstField)) else {
                return false
            }
            return date >= cutoff
        }

        let output = ([header] + retained).joined(separator: "\n") + "\n"
        do {
            try output.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.info("History retention complete: \(retained.count, privacy: .public) rows")
        } catch {
            logger.error("History retention failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func csvNumber(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? ""
    }

    private func csvEscaped(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
