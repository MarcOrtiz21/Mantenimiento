import Foundation
import Testing
import MantenimientoCore
@testable import Mantenimiento

struct MaintenanceFeatureTests {
    @Test func sensorCatalogMapsProcessorGenerations() {
        #expect(SensorCatalog.platform(forProcessorBrand: "Apple M1 Pro") == .m1)
        #expect(SensorCatalog.platform(forProcessorBrand: "Apple M2") == .m2)
        #expect(SensorCatalog.platform(forProcessorBrand: "Apple M3 Max") == .m3)
        #expect(SensorCatalog.platform(forProcessorBrand: "Apple M4 Pro") == .m4)
        #expect(SensorCatalog.platform(forProcessorBrand: "Apple M5") == .m4)
        #expect(SensorCatalog.platform(forProcessorBrand: "Intel(R) Core(TM) i7") == .none)
    }

    @Test func signedMilliampsDecodesTwoComplement() {
        #expect(SystemTelemetryService.signedMilliamps(1_500) == 1_500)
        #expect(SystemTelemetryService.signedMilliamps(Int(UInt32.max)) == -1)
        #expect(SystemTelemetryService.signedMilliamps(Int(UInt32.max) - 999) == -1_000)
    }

    @Test func historyParserReadsKnownColumnsAndFiltersByDate() {
        let csv = """
        date,cpu_percent,battery_percent
        2026-10-20T10:00:00.000Z,12.5,80
        2026-10-21T10:00:00.000Z,40,,
        not-a-date,1,2
        """
        let since = ISO8601DateFormatter().date(from: "2026-10-21T00:00:00Z")!
        let rows = TelemetryHistoryRecorder.parse(csv, since: since)

        #expect(rows.count == 1)
        #expect(rows.first?.values["cpu_percent"] == 40)
        #expect(rows.first?.values["battery_percent"] == nil)
    }

    @Test func historySeriesAveragesBucketsAndMarksGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let bucket = TelemetryHistoryRange.hour.bucketInterval
        let rows = [
            TelemetryHistoryRow(date: start, values: ["cpu_percent": 10]),
            TelemetryHistoryRow(date: start.addingTimeInterval(1), values: ["cpu_percent": 30]),
            TelemetryHistoryRow(date: start.addingTimeInterval(bucket * 10), values: ["cpu_percent": 50])
        ]

        let data = TelemetryChartSeries.history(rows, column: "cpu_percent", range: .hour)

        #expect(data.points.count == 2)
        #expect(data.points.first?.value == 20)
        #expect(data.gaps.count == 1)
        #expect(TelemetryChartSeries.history(rows, column: "cpu_percent", range: .live).points.isEmpty)
    }

    @Test func runawayDetectorWaitsForSustainedUsage() {
        AppPreferences.registerDefaults()
        let detector = RunawayProcessDetector()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let busy = [
            MenuDemandEntry(name: "/usr/bin/yes", detail: "120%", sortValue: 120),
            MenuDemandEntry(name: "kernel_task", detail: "300%", sortValue: 300)
        ]

        #expect(detector.process(entries: busy, now: start).isEmpty)
        #expect(detector.process(entries: busy, now: start.addingTimeInterval(120)).isEmpty)

        let alerts = detector.process(entries: busy, now: start.addingTimeInterval(AppPreferences.runawayProcessDuration))
        #expect(alerts.map(\.id) == ["process.yes"])
        #expect(detector.process(entries: busy, now: start.addingTimeInterval(AppPreferences.runawayProcessDuration + 30)).isEmpty)
    }

    @Test func runawayDetectorResetsWhenUsageDrops() {
        AppPreferences.registerDefaults()
        let detector = RunawayProcessDetector()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let busy = [MenuDemandEntry(name: "loop", detail: "", sortValue: 150)]
        let idle = [MenuDemandEntry(name: "loop", detail: "", sortValue: 5)]

        _ = detector.process(entries: busy, now: start)
        _ = detector.process(entries: idle, now: start.addingTimeInterval(200))
        let alerts = detector.process(entries: busy, now: start.addingTimeInterval(AppPreferences.runawayProcessDuration + 10))
        #expect(alerts.isEmpty)
    }
}
