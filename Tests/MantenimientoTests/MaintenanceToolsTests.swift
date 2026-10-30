import Foundation
import Testing
import MantenimientoCore
@testable import Mantenimiento

struct MaintenanceToolsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func storageAnalyzerMeasuresFilesAndReportsMissingFolders() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches/app", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data(count: 100_000).write(to: caches.appendingPathComponent("blob"))

        let target = StorageAnalyzer.targets.first { $0.id == "caches" }!
        let measured = StorageAnalyzer.measure(target, at: home.appendingPathComponent(target.relativePath), timeLimit: 5)
        #expect(measured.access == .measured)
        #expect(measured.sizeBytes >= 100_000)

        let missing = StorageAnalyzer.measure(target, at: home.appendingPathComponent("nope"), timeLimit: 5)
        #expect(missing.access == .missing)
    }

    @Test func storageAnalyzerListsOnlyLargeFiles() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("instalador.dmg")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.write(contentsOf: Data(count: Int(StorageAnalyzer.largeFileThreshold) + 1_000_000))
        try handle.close()
        try Data(count: 1_000).write(to: folder.appendingPathComponent("nota.txt"))

        let files = StorageAnalyzer.largeFiles(in: folder, timeLimit: 5)
        #expect(files.map(\.url.lastPathComponent) == ["instalador.dmg"])
    }

    @Test func snapshotCountIgnoresHeader() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-29-101500.local
        com.apple.TimeMachine.2026-10-30-091500.local
        """
        #expect(StorageAnalyzer.parseSnapshotCount(output) == 2)
        #expect(StorageAnalyzer.parseSnapshotCount("Snapshots for disk /:") == 0)
    }

    @Test func topPowerParserUsesLastSampleAndKeepsSpacesInNames() {
        let output = """
        PID   COMMAND          POWER
        10    mds              0.0
        PID   COMMAND          POWER
        10    mds              97.7
        6635  Cursor Helper    30.1
        """
        let samples = ProcessDemandSampler.parseTopPower(output)
        #expect(samples.count == 2)
        #expect(samples[0].power == 97.7)
        #expect(samples[1].command == "Cursor Helper")
        #expect(samples[1].pid == 6635)
    }

    @Test func launchctlParsersDetectRunningAndDisabledServices() {
        let user = "PID\tStatus\tLabel\n-\t0\tcom.apple.idle\n1018\t0\tcom.google.keystone.agent\n"
        #expect(LaunchItemsScanner.runningLabels(userList: user) == ["com.google.keystone.agent"])

        let system = """
        system = {
        \tservices = {
        \t\t       0      - \tcom.adobe.ARMDC.Communicator
        \t\t     531      - \tlocal.marc.mantenimiento.helper
        \t}
        }
        """
        #expect(LaunchItemsScanner.runningSystemLabels(system) == ["local.marc.mantenimiento.helper"])

        let disabled = """
        \tdisabled services = {
        \t\t"com.example.off" => disabled
        \t\t"com.example.on" => enabled
        \t\t"com.legacy.off" => true
        \t}
        """
        #expect(LaunchItemsScanner.disabledLabels(disabled) == ["com.example.off", "com.legacy.off"])
    }

    @Test func launchItemFlagsMissingProgramAsOrphaned() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plist: [String: Any] = [
            "Label": "com.google.keystone.agent",
            "ProgramArguments": ["/Applications/NoExiste.app/Contents/MacOS/agent", "--run"],
            "RunAtLoad": true
        ]
        let url = folder.appendingPathComponent("agent.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)

        let item = try #require(LaunchItemsScanner.item(at: url, scope: .userAgent, running: [], disabled: []))
        #expect(item.isOrphaned)
        #expect(item.vendor == "Google")
        #expect(item.runsAtLoad)
        #expect(!item.isRunning)
    }

    @Test func usbcPortsDecodeChargerContractAndPoweredDevice() {
        let info: [[String: Any]] = [
            ["PortControllerActiveContractRdo": 0, "PortControllerPortPDO": [0, 0], "PortControllerMaxPower": 0],
            ["PortControllerActiveContractRdo": 1_090_999_765, "PortControllerPortPDO": [134_320_424, 184_617, 307_498, 410_069, 0], "PortControllerMaxPower": 93_800],
            ["PortControllerActiveContractRdo": 0, "PortControllerPortPDO": [0], "PortControllerMaxPower": 0]
        ]
        let fed: [[String: Any]] = [
            ["FedStateOfCharge": 90, "FedPortPowerRole": 1, "FedVendorID": 1452, "FedDesignCapacity": 300, "FedExternalConnected": 0],
            ["FedStateOfCharge": 0, "FedPortPowerRole": 0, "FedVendorID": 0, "FedDesignCapacity": 0, "FedExternalConnected": 1],
            ["FedStateOfCharge": 0, "FedPortPowerRole": 0, "FedVendorID": 0, "FedDesignCapacity": 0, "FedExternalConnected": 0]
        ]

        let ports = SystemTelemetryService.usbcPorts(info: info, fed: fed)

        #expect(ports.map(\.role) == [.poweringDevice, .charger, .idle])
        #expect(ports[0].deviceBatteryPercent == 90)
        #expect(ports[0].deviceVendorID == 1452)
        #expect(ports[0].deviceFullCapacity == nil)
        #expect(ports[1].contractVoltageMillivolts == 20_000)
        #expect(ports[1].contractCurrentMilliamps == 4_690)
        #expect(ports[1].offeredVoltagesMillivolts == [5_000, 9_000, 15_000, 20_000])
        #expect(abs((ports[1].contractWatts ?? 0) - 93.8) < 0.01)
        #expect(ports[2].deviceBatteryPercent == nil)
    }

    @Test func chargeRateEstimatorUsesObservedPace() {
        let estimator = ChargeRateEstimator()
        let start = Date(timeIntervalSince1970: 1_000)
        estimator.record(id: "ipad", level: 270, full: 300, isCharging: true, at: start)
        estimator.record(id: "ipad", level: 271, full: 300, isCharging: true, at: start.addingTimeInterval(100))
        #expect(estimator.minutesToFull(id: "ipad") == nil)

        estimator.record(id: "ipad", level: 272, full: 300, isCharging: true, at: start.addingTimeInterval(220))
        estimator.record(id: "ipad", level: 273, full: 300, isCharging: true, at: start.addingTimeInterval(340))
        #expect(estimator.minutesToFull(id: "ipad") == 54)

        estimator.record(id: "ipad", level: 273, full: 300, isCharging: false, at: start.addingTimeInterval(400))
        #expect(estimator.minutesToFull(id: "ipad") == nil)
    }

    @Test func adapterFirmwareAndProfilerConditionParse() {
        #expect(SystemTelemetryService.adapterFirmwareVersion("01090058") == "1090058")
        #expect(SystemTelemetryService.adapterFirmwareVersion("0") == "0")
        let json = #"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_cycle_count":55,"sppower_battery_health":"Good"}}]}"#
        #expect(SystemTelemetryService.parseProfilerBatteryCondition(json) == "Good")
        #expect(SystemTelemetryService.parseProfilerBatteryCondition("{}") == nil)
    }

    @Test func batteryHealthLogStoresOneRowPerDay() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = BatteryHealthLog(fileURL: folder.appendingPathComponent("battery-health.csv"))
        let json = #"{"percent":80,"isCharging":false,"isCharged":false,"externalConnected":true,"cycleCount":55,"designCapacity":6249,"maxCapacity":6296,"ports":[]}"#
        let battery = try JSONDecoder().decode(BatterySnapshot.self, from: Data(json.utf8))

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        log.recordIfNeeded(battery, now: day)
        log.recordIfNeeded(battery, now: day.addingTimeInterval(60))
        log.recordIfNeeded(battery, now: day.addingTimeInterval(86_400))

        let entries = log.entries()
        #expect(entries.count == 2)
        #expect(entries.first?.capacityMah == 6296)
        #expect(entries.first?.designCapacityMah == 6249)
        #expect(entries.first?.cycleCount == 55)
    }
}
