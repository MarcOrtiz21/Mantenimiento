import Foundation
import Testing
@testable import Mantenimiento
@testable import MantenimientoCore

struct TelemetryAccuracyTests {
    @Test func diskUsesItsActualSamplingIntervalAndKeepsCachedRate() {
        var date = Date(timeIntervalSince1970: 1_000)
        var bytes: UInt64 = 0
        let empty = SystemTelemetryService.placeholderSnapshot()
        let store = TelemetryStore(
            clock: { date },
            loadTelemetry: {
                bytes += 450
                return SystemTelemetrySnapshot(cpu: empty.cpu, gpu: nil, memory: empty.memory, swap: empty.swap,
                    disk: empty.disk, diskIO: DiskIOSnapshot(readBytes: bytes, writtenBytes: bytes, readOperations: 0, writeOperations: 0),
                    battery: nil, network: empty.network)
            },
            loadStatus: { $0 ?? empty },
            loadFans: { throw SMCError.noFans },
            loadSensors: { throw SensorReadError.notSupported },
            loadResources: { AppResourceSnapshot(date: date, cpuRatio: nil, residentMemoryBytes: 0) }
        )
        _ = store.snapshot(previousTelemetry: nil, includeSMC: false, fullTelemetry: true)
        date += 1.5
        #expect(store.snapshot(previousTelemetry: nil, includeSMC: false, fullTelemetry: false).diskReadBps == nil)
        date += 3
        let fresh = store.snapshot(previousTelemetry: nil, includeSMC: false, fullTelemetry: true, force: true)
        #expect(fresh.diskReadBps == 100)
        let diskDate = fresh.diskDate
        date += 1.5
        let cached = store.snapshot(previousTelemetry: nil, includeSMC: false, fullTelemetry: false)
        #expect(cached.diskReadBps == 100)
        #expect(cached.diskDate == diskDate)
    }

    @Test func chartIDsStayStableAndMissingDataBreaksLines() {
        let date = Date(timeIntervalSince1970: 1_000)
        let input: [(Date, Double?)] = [(date, 30), (date + 1, nil), (date + 2, 40)]
        let first = TelemetryChartSeries.points(input)
        let second = TelemetryChartSeries.points(input)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first[0].segment != first[1].segment)
        #expect(TelemetryChartSeries.points([(date, 30), (date, 30)]).count == 1)
    }

    @Test func chartBreaksAtLongSamplingGaps() {
        let date = Date(timeIntervalSince1970: 1_000)
        let points = TelemetryChartSeries.points([(date, 10), (date + 5, 20), (date + 120, 30), (date + 125, 40)])
        #expect(points[0].segment == points[1].segment)
        #expect(points[1].segment != points[2].segment)
        #expect(points[2].segment == points[3].segment)
    }

    @Test func evenAShortWakeStartsANewChartSegment() {
        let date = Date(timeIntervalSince1970: 1_000)
        let points = TelemetryChartSeries.points([(date, 10, UInt64(0)), (date + 1.5, 20, UInt64(1))])
        #expect(points[0].segment != points[1].segment)
    }

    @Test func chartsDiscardAncientPointsInsteadOfSpanningHours() {
        let date = Date(timeIntervalSince1970: 1_000)
        let points = TelemetryChartSeries.points([(date, 10), (date + 5, 20), (date + 3_600, 30), (date + 3_605, 40)])
        #expect(points.map(\.date) == [date + 3_600, date + 3_605])
    }

    @Test func outOfOrderMeasurementsCannotMakeLinesDoubleBack() {
        let date = Date(timeIntervalSince1970: 1_000)
        let points = TelemetryChartSeries.points([(date + 1, 10), (date, 20), (date + 2, 30)])
        #expect(points.map(\.date) == [date + 1, date + 2])
    }

    @Test func diskRatesDoNotAverageAcrossSuspension() {
        let date = Date(timeIntervalSince1970: 1_000)
        #expect(TelemetryStore.counterRate(1_000, 100, date + 600, date) == nil)
        #expect(TelemetryStore.counterRate(550, 100, date + 4.5, date) == 100)
    }

    @Test func missingIntervalsStaySeparateFromRealMeasurements() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 40, 0), (date + 5, nil, 0), (date + 10, 45, 0)])
        #expect(data.points.map(\.value) == [40, 45])
        #expect(data.gaps.count == 1)
        #expect(data.gaps.first?.start == date)
        #expect(data.gaps.first?.end == date + 10)
    }

    @Test func actualZerosAreMeasurementsNotMissingData() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 0, 0), (date + 5, 0, 0)])
        #expect(data.points.map(\.value) == [0, 0])
        #expect(data.gaps.isEmpty)
    }

    @Test func wakeAndLongPauseCreateStableGapIntervals() {
        let date = Date(timeIntervalSince1970: 1_000)
        let input: [(date: Date, value: Double?, epoch: UInt64)] = [
            (date, 40, 0), (date + 15, 45, 1), (date + 20, 44, 1), (date + 120, 42, 1)
        ]
        let first = TelemetryChartSeries.make(input)
        let second = TelemetryChartSeries.make(input)
        #expect(first.gaps.map(\.id) == second.gaps.map(\.id))
        #expect(first.gaps.map(\.start) == [date, date + 20])
        #expect(first.gaps.map(\.end) == [date + 15, date + 120])
    }

    @Test func trailingMissingReadingsStayVisibleUntilRecovery() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 40, 0), (date + 5, nil, 0), (date + 10, nil, 0)])
        #expect(data.points.count == 1)
        #expect(data.gaps.count == 1)
        #expect(data.gaps.first?.start == date)
        #expect(data.gaps.first?.end == date + 10)
    }

    @Test func unavailableMetricsHaveNoInventedMeasurements() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, nil, 0), (date + 5, nil, 0)])
        #expect(data.points.isEmpty)
        #expect(data.gaps.first?.start == date)
        #expect(data.gaps.first?.end == date + 5)
    }

    @Test func longSuspensionKeepsItsGapWithinTheRecentWindow() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 40, 0), (date + 3_600, 45, 1), (date + 3_605, 46, 1)])
        #expect(data.points.map(\.value) == [45, 46])
        #expect(data.gaps.count == 1)
        #expect(data.gaps.first?.start == date + 3_005)
        #expect(data.gaps.first?.end == date + 3_600)
    }

    @Test func displayBridgesPausesAtTheMinimumWithoutChangingRealValues() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 40, 0), (date + 60, 45, 1)])
        let display = data.displayPoints(baseline: 35)
        #expect(display.map(\.value) == [40, 35, 35, 45])
        #expect(display.filter(\.isMeasurement).map(\.value) == data.points.map(\.value))
        #expect(display[1].date > date)
        #expect(display[2].date < date + 60)
        #expect(zip(display, display.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test func displayKeepsATrailingPauseFlatAtTheMinimum() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 40, 0), (date + 10, nil, 0)])
        let display = data.displayPoints(baseline: 35)
        #expect(display.map(\.value) == [40, 35, 35])
        #expect(display.last?.date == date + 10)
        #expect(data.points.count == 1)
    }

    @Test func missingMetricCanRenderABaselineWithoutInventingMeasurements() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, nil, 0), (date + 5, nil, 0)])
        let display = data.displayPoints(baseline: 0)
        #expect(display.map(\.value) == [0, 0])
        #expect(display.allSatisfy { !$0.isMeasurement })
        #expect(data.points.isEmpty)
    }

    @Test func displayPointIdentitiesStayStableAndRealZerosStayReal() {
        let date = Date(timeIntervalSince1970: 1_000)
        let data = TelemetryChartSeries.make([(date, 0, 0), (date + 60, 0, 1)])
        let first = data.displayPoints(baseline: 0)
        let second = data.displayPoints(baseline: 0)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.filter(\.isMeasurement).count == 2)
        #expect(first.allSatisfy { $0.value == 0 })
    }

    @Test func historyExportPrunesExpiredRowsWithoutDeletingDestinationFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("history.csv")
        let destination = directory.appendingPathComponent("export.csv")
        try "date,cpu_percent\n2026-01-01T00:00:00.000Z,10\n2026-01-09T00:00:00.000Z,20\n".write(to: source, atomically: true, encoding: .utf8)
        try "previous export".write(to: destination, atomically: true, encoding: .utf8)
        let formatter = ISO8601DateFormatter()
        let now = try #require(formatter.date(from: "2026-01-10T00:00:00Z"))
        let recorder = TelemetryHistoryRecorder(fileURL: source, clock: { now })
        try recorder.export(to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(!text.contains("2026-01-01"))
        #expect(text.contains("2026-01-09"))
    }
}
