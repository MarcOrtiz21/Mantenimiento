import Foundation
import Testing
import MantenimientoCore
@testable import Mantenimiento

struct TelemetryStoreTests {
    private enum ReadingError: Error { case disconnected }

    private final class Fixture {
        var date = Date(timeIntervalSince1970: 1_000)
        var fullReads = 0
        var statusReads = 0
        var fanReads = 0
        var sensorReads = 0
        var failFans = false
        var failSensors = false

        func store() -> TelemetryStore {
            TelemetryStore(
                clock: { self.date },
                loadTelemetry: {
                    self.fullReads += 1
                    return SystemTelemetryService.placeholderSnapshot()
                },
                loadStatus: { _ in
                    self.statusReads += 1
                    return SystemTelemetryService.placeholderSnapshot()
                },
                loadFans: {
                    self.fanReads += 1
                    if self.failFans { throw ReadingError.disconnected }
                    return try JSONDecoder().decode(FanSnapshot.self, from: Data(
                        #"{"fans":[],"forceTestAvailable":false}"#.utf8
                    ))
                },
                loadSensors: {
                    self.sensorReads += 1
                    if self.failSensors { throw ReadingError.disconnected }
                    return try JSONDecoder().decode(SensorSnapshot.self, from: Data(
                        #"{"readings":[{"sensor":{"key":"TC0D","name":"CPU","group":"CPU","type":"Temperatura"},"value":40}]}"#.utf8
                    ))
                },
                loadResources: {
                    AppResourceSnapshot(date: self.date, cpuRatio: nil, residentMemoryBytes: 0)
                }
            )
        }
    }

    @Test func concurrentConsumersReuseOneSample() {
        let fixture = Fixture()
        let store = fixture.store()
        let first = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        fixture.date += 0.2
        let second = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        #expect(first.date == second.date)
        #expect(fixture.fullReads == 1)
        #expect(fixture.statusReads == 0)
        #expect(fixture.fanReads == 1)
        #expect(fixture.sensorReads == 1)
    }

    @Test func failedReadRetainsLastSuccessAndRecoveryClearsError() {
        let fixture = Fixture()
        let store = fixture.store()
        let first = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        fixture.date += 5
        fixture.failSensors = true
        let failed = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true, force: true)
        #expect(failed.sensors != nil)
        #expect(failed.sensorError != nil)
        #expect(failed.sensorDate == first.sensorDate)
        #expect(!failed.sensorStatus.isCurrent)
        #expect(failed.fanStatus.isCurrent)
        let menu = MenuBarSnapshot.make(shared: failed, previous: nil)
        #expect(menu.sensors == nil)
        #expect(menu.fans != nil)

        fixture.date += 5
        fixture.failSensors = false
        let recovered = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true, force: true)
        #expect(recovered.sensorError == nil)
        #expect(recovered.sensorDate == fixture.date)
        #expect(recovered.sensorStatus.isCurrent)
    }

    @Test func fanFailureDoesNotInvalidateSensors() {
        let fixture = Fixture()
        fixture.failFans = true
        let snapshot = fixture.store().snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        let menu = MenuBarSnapshot.make(shared: snapshot, previous: nil)
        #expect(!snapshot.fanStatus.isCurrent)
        #expect(snapshot.sensorStatus.isCurrent)
        #expect(menu.fans == nil)
        #expect(menu.sensors != nil)
    }

    @Test func invalidationForcesSMCReadWithoutDuplicatingNormalReads() {
        let fixture = Fixture()
        let store = fixture.store()
        _ = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        fixture.date += 1.5
        _ = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        #expect(fixture.fullReads == 1)
        #expect(fixture.statusReads == 1)
        #expect(fixture.sensorReads == 1)
        store.invalidateSMC()
        fixture.date += 0.2
        _ = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        #expect(fixture.sensorReads == 2)
        #expect(fixture.fanReads == 2)
    }

    @Test func oldSuccessfulReadingIsNotCurrent() {
        let date = Date(timeIntervalSince1970: 1_000)
        let status = TelemetryReadingStatus(lastSuccess: date, error: nil, referenceDate: date + 16)
        #expect(!status.isCurrent)
        #expect(!TelemetryReadingStatus(lastSuccess: nil, error: nil, referenceDate: date).isCurrent)
    }

    @Test func longPauseReloadsTelemetryAndSMCWithoutReusingOldSuccess() {
        let fixture = Fixture()
        let store = fixture.store()
        let first = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        fixture.date += 600
        let resumed = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        #expect(resumed.date > first.date)
        #expect(resumed.sensorDate == fixture.date)
        #expect(resumed.fanDate == fixture.date)
        #expect(resumed.diskDate == fixture.date)
        #expect(resumed.sensorStatus.isCurrent)
        #expect(fixture.fullReads == 2 && fixture.sensorReads == 2 && fixture.fanReads == 2)
    }

    @Test func wakeInvalidatesEvenASubsecondCacheAndResetsRateBaselines() {
        let fixture = Fixture()
        let store = fixture.store()
        let first = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        let before = MenuBarSnapshot.make(shared: first, previous: nil)
        fixture.date += 0.5
        store.resetAfterWake()
        let resumed = store.snapshot(previousTelemetry: nil, includeSMC: false, fullTelemetry: false)
        #expect(resumed.date == fixture.date)
        #expect(resumed.samplingEpoch != first.samplingEpoch)
        #expect(resumed.diskReadBps == nil && resumed.diskWriteBps == nil)
        #expect(fixture.fullReads == 2)
        let after = MenuBarSnapshot.make(shared: resumed, previous: before)
        #expect(after.cpuUsage == nil)
        #expect(after.networkDownBps == nil && after.networkUpBps == nil)
        fixture.date += 10
        let next = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        #expect(next.samplingEpoch == resumed.samplingEpoch)
        #expect(next.diskReadBps == 0)
        #expect(MenuBarSnapshot.make(shared: next, previous: after).networkDownBps == 0)
    }

    @Test func twoHoursOfSimulatedSamplingPreserveReadCadence() {
        let fixture = Fixture()
        let store = fixture.store()
        _ = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        for _ in 0..<4_800 {
            fixture.date += 1.5
            _ = store.snapshot(previousTelemetry: nil, includeSMC: true, fullTelemetry: true)
        }
        let stepsPerFullRead = ProcessInfo.processInfo.isLowPowerModeEnabled ? 6 : 3
        #expect(fixture.fullReads == 1 + 4_800 / stepsPerFullRead)
        #expect(fixture.sensorReads == fixture.fullReads && fixture.fanReads == fixture.fullReads)
        #expect(fixture.statusReads == 4_801 - fixture.fullReads)
        #expect(store.latest?.date == fixture.date)
        #expect(store.latest?.sensorStatus.isCurrent == true)
    }
}
