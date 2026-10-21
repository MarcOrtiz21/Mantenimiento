import Foundation
import OSLog

struct TelemetryHistoryRow {
    let date: Date
    let values: [String: Double]
}

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
    private var lastPruneDate: Date?
    private var isHeaderVerified = false
    private let fileURL: URL
    private let clock: () -> Date

    init(fileURL suppliedURL: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directoryURL = suppliedURL?.deletingLastPathComponent() ?? baseURL.appendingPathComponent("Mantenimiento", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = suppliedURL ?? directoryURL.appendingPathComponent("telemetry-history.csv")

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
            if appendLine(csvLine(for: snapshot)) { lastRecordDate = snapshot.date }
            if lastPruneDate.map({ self.clock().timeIntervalSince($0) >= 3600 }) ?? true { pruneExpiredRows() }
        }
    }

    func export(to destinationURL: URL) throws {
        try queue.sync {
            prepareFile()
            pruneExpiredRows()
            let data = try Data(contentsOf: fileURL)
            try data.write(to: destinationURL, options: .atomic)
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

    /// Filas en orden cronológico desde `date`, con las columnas numéricas por nombre.
    func rows(since date: Date) -> [TelemetryHistoryRow] {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return Self.parse(text, since: date)
        }
    }

    static func parse(_ text: String, since date: Date) -> [TelemetryHistoryRow] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return [] }
        let columns = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        return lines.compactMap { line -> TelemetryHistoryRow? in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = fields.first,
                  let rowDate = dateFormatter.date(from: String(first)),
                  rowDate >= date else {
                return nil
            }
            var values: [String: Double] = [:]
            for (index, field) in fields.enumerated().dropFirst() where index < columns.count {
                if let value = Double(field) {
                    values[columns[index]] = value
                }
            }
            return TelemetryHistoryRow(date: rowDate, values: values)
        }
    }

    static let columns = [
        "date", "cpu_percent", "gpu_percent", "ram_percent", "memory_pressure", "max_temperature_c",
        "average_rpm", "system_power_w", "network_down_bps", "network_up_bps", "disk_read_bps",
        "disk_write_bps", "battery_percent", "app_cpu_percent", "app_ram_bytes", "thermal_state",
        "cpu_temperature_c", "gpu_temperature_c", "battery_power_w", "system_power_in_w",
        "swap_used_bytes", "load_average_1m"
    ]

    private static var header: String {
        columns.joined(separator: ",")
    }

    private func prepareFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data((Self.header + "\n").utf8))
            isHeaderVerified = true
            return
        }
        if !isHeaderVerified {
            migrateHeaderIfNeeded()
            isHeaderVerified = true
        }
    }

    /// Las columnas nuevas se añaden al final; las filas antiguas se completan con campos vacíos.
    private func migrateHeaderIfNeeded() {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        let prefix = (try? handle.read(upToCount: 4_096)) ?? Data()
        try? handle.close()
        let currentHeader = String(decoding: prefix, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard currentHeader != Self.header,
              Self.header.hasPrefix(currentHeader),
              let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }

        let oldCount = currentHeader.split(separator: ",", omittingEmptySubsequences: false).count
        let padding = String(repeating: ",", count: max(Self.columns.count - oldCount, 0))
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().map { String($0) + padding }
        let output = ([Self.header] + rows).joined(separator: "\n") + "\n"
        do {
            try output.write(to: fileURL, atomically: true, encoding: .utf8)
            logger.info("History header migrated to \(Self.columns.count, privacy: .public) columns")
        } catch {
            logger.error("History migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendLine(_ line: String) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            logger.error("Could not open history file for append")
            return false
        }
        defer { try? handle.close() }

        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            return true
        } catch {
            logger.error("History write failed: \(error.localizedDescription, privacy: .public)")
            return false
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
            csvNumber(snapshot.telemetry.memory.isAvailable ? snapshot.telemetry.memory.usedRatio * 100 : nil),
            snapshot.telemetry.memory.pressureLevel >= 0 ? String(snapshot.telemetry.memory.pressureLevel) : "",
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
            csvEscaped(snapshot.thermalState),
            csvNumber(snapshot.cpuTemperature),
            csvNumber(snapshot.gpuTemperature),
            csvNumber(snapshot.telemetry.battery?.batteryPowerWatts),
            csvNumber(snapshot.telemetry.battery?.systemPowerInWatts),
            snapshot.telemetry.swap.totalBytes > 0 ? String(snapshot.telemetry.swap.usedBytes) : "",
            csvNumber(snapshot.telemetry.cpu.loadAverage.first)
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

        let cutoff = clock().addingTimeInterval(-retentionInterval)
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
            lastPruneDate = clock()
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
