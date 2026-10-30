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

    @Test func batteryHealthLogStoresOneRowPerDay() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = BatteryHealthLog(fileURL: folder.appendingPathComponent("battery-health.csv"))
        let json = #"{"percent":80,"isCharging":false,"isCharged":false,"externalConnected":true,"cycleCount":55,"designCapacity":6249,"maxCapacity":6296}"#
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
