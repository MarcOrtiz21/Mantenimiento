import Foundation

/// Últimos minutos de las métricas del desplegable; se alimenta siempre, aunque esté cerrado.
final class MenuBarSparklineHistory {
    static let shared = MenuBarSparklineHistory()
    static let window: TimeInterval = 5 * 60

    struct Sample {
        let date: Date
        let cpu: Double?
        let gpu: Double?
        let memory: Double?
        let networkDown: Double?
        let networkUp: Double?
        let systemWatts: Double?
    }

    private(set) var samples: [Sample] = []

    func record(_ snapshot: MenuBarSnapshot) {
        let telemetry = snapshot.telemetry
        let sample = Sample(
            date: snapshot.date,
            cpu: snapshot.cpuUsage,
            gpu: telemetry.gpu?.utilizationRatio,
            memory: telemetry.memory.isAvailable ? telemetry.memory.usedRatio : nil,
            networkDown: snapshot.networkDownBps,
            networkUp: snapshot.networkUpBps,
            systemWatts: telemetry.battery?.systemLoadWatts
        )
        if let last = samples.last, sample.date <= last.date {
            return
        }
        samples.append(sample)
        let cutoff = sample.date.addingTimeInterval(-Self.window)
        if let firstKept = samples.firstIndex(where: { $0.date >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
    }

    func values(_ keyPath: KeyPath<Sample, Double?>) -> [Double] {
        samples.compactMap { $0[keyPath: keyPath] }.filter(\.isFinite)
    }
}
