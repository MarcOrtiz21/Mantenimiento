import Foundation
import MantenimientoCore

struct BatteryHealthEntry: Equatable {
    let day: Date
    let capacityMah: Int
    let designCapacityMah: Int
    let cycleCount: Int?

    var capacityRatio: Double {
        designCapacityMah > 0 ? Double(capacityMah) / Double(designCapacityMah) : 0
    }
}

/// Una fila por día con la capacidad real de la batería; se conserva sin límite (unos 40 bytes por día).
final class BatteryHealthLog {
    static let shared = BatteryHealthLog()

    private let queue = DispatchQueue(label: "local.marc.mantenimiento.battery-health")
    private let fileURL: URL
    private var lastRecordedDay: String?

    static let header = "day,capacity_mah,design_capacity_mah,cycle_count"

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mantenimiento", isDirectory: true)
            self.fileURL = support.appendingPathComponent("battery-health.csv")
        }
    }

    func recordIfNeeded(_ battery: BatterySnapshot?, now: Date = Date()) {
        guard let battery,
              let capacity = battery.fullChargeCapacityMah ?? battery.maxCapacity,
              let design = battery.designCapacity,
              capacity > 0, design > 0 else {
            return
        }
        let day = Self.dayFormatter.string(from: now)
        queue.async { [self] in
            if lastRecordedDay == nil {
                lastRecordedDay = Self.parse(readText()).last.map { Self.dayFormatter.string(from: $0.day) }
            }
            guard lastRecordedDay != day else { return }
            let line = "\(day),\(capacity),\(design),\(battery.cycleCount.map(String.init) ?? "")\n"
            append(line)
            lastRecordedDay = day
        }
    }

    func entries() -> [BatteryHealthEntry] {
        queue.sync { Self.parse(readText()) }
    }

    static func parse(_ text: String) -> [BatteryHealthEntry] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let day = dayFormatter.date(from: String(fields[0])),
                  let capacity = Int(fields[1]),
                  let design = Int(fields[2]) else {
                return nil
            }
            let cycles = fields.count > 3 ? Int(fields[3]) : nil
            return BatteryHealthEntry(day: day, capacityMah: capacity, designCapacityMah: design, cycleCount: cycles)
        }
    }

    private func readText() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            try? (Self.header + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
