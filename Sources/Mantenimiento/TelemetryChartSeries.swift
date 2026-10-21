import Foundation

struct TelemetryChartPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
    let segment: Int
}

struct TelemetryChartGap: Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
}

struct TelemetryChartData {
    let points: [TelemetryChartPoint]
    let gaps: [TelemetryChartGap]

    func displayPoints(baseline: Double) -> [TelemetryChartDisplayPoint] {
        var display = points.map {
            TelemetryChartDisplayPoint(id: .measurement($0.date), date: $0.date, value: $0.value)
        }
        guard baseline.isFinite else { return display }
        let measuredDates = Set(points.map(\.date))
        for gap in gaps where gap.end > gap.start {
            // La bajada al mínimo es solo presentación; nunca se guarda como lectura.
            let edge = min(0.2, gap.end.timeIntervalSince(gap.start) / 4)
            let start = measuredDates.contains(gap.start) ? gap.start + edge : gap.start
            let end = measuredDates.contains(gap.end) ? gap.end - edge : gap.end
            display.append(TelemetryChartDisplayPoint(id: .pauseStart(gap.start), date: start, value: baseline))
            display.append(TelemetryChartDisplayPoint(id: .pauseEnd(gap.start), date: end, value: baseline))
        }
        return display.sorted { $0.date < $1.date }
    }
}

struct TelemetryChartDisplayPoint: Identifiable {
    enum ID: Hashable {
        case measurement(Date), pauseStart(Date), pauseEnd(Date)
    }

    let id: ID
    let date: Date
    let value: Double

    var isMeasurement: Bool {
        if case .measurement = id { return true }
        return false
    }
}

enum TelemetryChartSeries {
    static func points(_ measurements: [(date: Date, value: Double?)]) -> [TelemetryChartPoint] {
        points(measurements.map { ($0.date, $0.value, 0) })
    }

    static func points(_ measurements: [(date: Date, value: Double?, epoch: UInt64)]) -> [TelemetryChartPoint] {
        make(measurements).points
    }

    static func make(_ measurements: [(date: Date, value: Double?, epoch: UInt64)]) -> TelemetryChartData {
        guard let newestDate = measurements.last?.date else { return TelemetryChartData(points: [], gaps: []) }
        let cutoff = newestDate.addingTimeInterval(-600)
        let predecessor = measurements.last { $0.date < cutoff }
        var previousDate = predecessor?.date
        var previousEpoch = predecessor?.epoch
        var segment = 0
        var points: [TelemetryChartPoint] = []
        var gaps: [TelemetryChartGap] = []
        var gapStart: Date?
        if let predecessor, predecessor.value?.isFinite != true { gapStart = cutoff }
        for measurement in measurements where measurement.date >= cutoff {
            guard previousDate.map({ measurement.date > $0 }) ?? true else { continue }
            if let previousDate,
               !TelemetryContinuity.isContinuous(from: previousDate, to: measurement.date)
                || previousEpoch != measurement.epoch {
                segment += 1
                gapStart = gapStart ?? max(previousDate, cutoff)
            }
            previousDate = measurement.date
            previousEpoch = measurement.epoch
            guard let value = measurement.value, value.isFinite else {
                gapStart = gapStart ?? points.last?.date ?? measurement.date
                segment += 1
                continue
            }
            if let start = gapStart, start < measurement.date {
                gaps.append(TelemetryChartGap(start: start, end: measurement.date))
            }
            gapStart = nil
            points.append(TelemetryChartPoint(date: measurement.date, value: value, segment: segment))
        }
        if let start = gapStart, let end = previousDate, start < end {
            gaps.append(TelemetryChartGap(start: start, end: end))
        }
        return TelemetryChartData(points: points, gaps: gaps)
    }

    /// Promedia el historial persistente por intervalos; los huecos sin grabación quedan como pausas.
    static func history(
        _ rows: [TelemetryHistoryRow],
        column: String,
        range: TelemetryHistoryRange,
        transform: (Double) -> Double = { $0 }
    ) -> TelemetryChartData {
        guard range != .live else { return TelemetryChartData(points: [], gaps: []) }
        let bucket = range.bucketInterval
        var sums: [Int: (total: Double, count: Int)] = [:]
        for row in rows {
            guard let value = row.values[column], value.isFinite else { continue }
            let key = Int((row.date.timeIntervalSince1970 / bucket).rounded(.down))
            let current = sums[key] ?? (0, 0)
            sums[key] = (current.total + transform(value), current.count + 1)
        }

        let maximumGap = max(bucket * 2.5, TelemetryHistoryRange.recordingInterval * 3)
        var points: [TelemetryChartPoint] = []
        var gaps: [TelemetryChartGap] = []
        var segment = 0
        for key in sums.keys.sorted() {
            guard let entry = sums[key] else { continue }
            let date = Date(timeIntervalSince1970: (Double(key) + 0.5) * bucket)
            if let last = points.last, date.timeIntervalSince(last.date) > maximumGap {
                segment += 1
                gaps.append(TelemetryChartGap(start: last.date, end: date))
            }
            points.append(TelemetryChartPoint(date: date, value: entry.total / Double(entry.count), segment: segment))
        }
        return TelemetryChartData(points: points, gaps: gaps)
    }
}

enum TelemetryHistoryRange: String, CaseIterable, Identifiable {
    case live
    case hour
    case day
    case week

    static let recordingInterval: TimeInterval = 30

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "En vivo"
        case .hour: return "1 h"
        case .day: return "24 h"
        case .week: return "7 días"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .live: return 600
        case .hour: return 3_600
        case .day: return 86_400
        case .week: return 7 * 86_400
        }
    }

    var bucketInterval: TimeInterval {
        max(Self.recordingInterval, duration / 240)
    }
}
