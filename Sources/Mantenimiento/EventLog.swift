import Foundation
import OSLog

extension Notification.Name {
    static let maintenanceEventLogged = Notification.Name("local.marc.mantenimiento.eventLogged")
}

struct MaintenanceEvent: Codable, Identifiable, Equatable {
    enum Category: String, Codable {
        case alert
        case fans
        case power
        case thermal
        case system
    }

    enum Severity: String, Codable {
        case info
        case warning
        case critical
    }

    var id: UUID = UUID()
    let date: Date
    let category: Category
    let severity: Severity
    let title: String
    let detail: String?
}

final class EventLog {
    static let shared = EventLog()

    private let queue = DispatchQueue(label: "local.marc.mantenimiento.events", qos: .utility)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento",
        category: "Events"
    )
    private let fileURL: URL
    private let clock: () -> Date
    private let maximumCount = 1_000
    private let retentionInterval: TimeInterval = 30 * 24 * 60 * 60
    private var cache: [MaintenanceEvent]?

    init(fileURL suppliedURL: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directoryURL = suppliedURL?.deletingLastPathComponent() ?? baseURL.appendingPathComponent("Mantenimiento", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        fileURL = suppliedURL ?? directoryURL.appendingPathComponent("events.json")
    }

    func record(
        _ category: MaintenanceEvent.Category,
        severity: MaintenanceEvent.Severity = .info,
        title: String,
        detail: String? = nil
    ) {
        let event = MaintenanceEvent(date: clock(), category: category, severity: severity, title: title, detail: detail)
        queue.async { [weak self] in
            guard let self else { return }
            var events = loadIfNeeded()
            events.append(event)
            let cutoff = clock().addingTimeInterval(-retentionInterval)
            events.removeAll { $0.date < cutoff }
            if events.count > maximumCount {
                events.removeFirst(events.count - maximumCount)
            }
            cache = events
            persist(events)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .maintenanceEventLogged, object: event)
            }
        }
    }

    /// Más recientes primero.
    func events(limit: Int = 300) -> [MaintenanceEvent] {
        queue.sync {
            Array(loadIfNeeded().suffix(limit).reversed())
        }
    }

    func clear() {
        queue.sync {
            cache = []
            persist([])
        }
        NotificationCenter.default.post(name: .maintenanceEventLogged, object: nil)
    }

    private func loadIfNeeded() -> [MaintenanceEvent] {
        if let cache { return cache }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode([MaintenanceEvent].self, from: $0) } ?? []
        cache = events
        return events
    }

    private func persist(_ events: [MaintenanceEvent]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(events).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Event log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
