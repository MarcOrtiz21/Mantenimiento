import Foundation
import MantenimientoCore

extension Notification.Name {
    static let telemetryUpdated = Notification.Name("local.marc.mantenimiento.telemetryUpdated")
}

struct TelemetryReadingStatus {
    let lastSuccess: Date?
    let error: String?
    let referenceDate: Date

    var isCurrent: Bool {
        guard error == nil, let lastSuccess else { return false }
        return referenceDate.timeIntervalSince(lastSuccess) <= 15
    }

    var description: String {
        guard let lastSuccess else { return error == nil ? "Esperando lectura" : "Sin lecturas" }
        let time = lastSuccess.formatted(date: .omitted, time: .standard)
        return isCurrent ? "Actual · \(time)" : "Última válida · \(time)"
    }
}

struct SharedTelemetrySnapshot {
    let date: Date
    let samplingEpoch: UInt64
    let smcDate: Date?
    let telemetry: SystemTelemetrySnapshot
    let fans: FanSnapshot?
    let sensors: SensorSnapshot?
    let fanError: String?
    let sensorError: String?
    let fanDate: Date?
    let sensorDate: Date?
    let appResources: AppResourceSnapshot
    let diskDate: Date
    let diskReadBps: Double?
    let diskWriteBps: Double?
    var diskReadOpsPerSecond: Double?
    var diskWriteOpsPerSecond: Double?

    var fanStatus: TelemetryReadingStatus {
        TelemetryReadingStatus(lastSuccess: fanDate, error: fanError, referenceDate: date)
    }

    var sensorStatus: TelemetryReadingStatus {
        TelemetryReadingStatus(lastSuccess: sensorDate, error: sensorError, referenceDate: date)
    }
}

final class TelemetryStore {
    static let shared = TelemetryStore()

    private let lock = NSLock()
    private let sampleLock = NSLock()
    private let clock: () -> Date
    private let loadTelemetry: () -> SystemTelemetrySnapshot
    private let loadStatus: (SystemTelemetrySnapshot?) -> SystemTelemetrySnapshot
    private let loadFans: () throws -> FanSnapshot
    private let loadSensors: () throws -> SensorSnapshot
    private let loadResources: () -> AppResourceSnapshot
    private var latestSnapshot: SharedTelemetrySnapshot?
    private var fullTelemetryDate: Date?
    private var lastSMCAttempt: Date?
    private var smcInvalidationGeneration: UInt64 = 0
    private var loadedSMCGeneration: UInt64 = 0
    private var samplingEpoch: UInt64 = 0
    private var loadedSamplingEpoch: UInt64 = 0

    private var slowInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 8 : 4.5
    }

    init(
        clock: @escaping () -> Date = Date.init,
        loadTelemetry: @escaping () -> SystemTelemetrySnapshot = SystemTelemetryService.snapshot,
        loadStatus: @escaping (SystemTelemetrySnapshot?) -> SystemTelemetrySnapshot = { SystemTelemetryService.statusSnapshot(previous: $0) },
        loadFans: @escaping () throws -> FanSnapshot = { try FanService.make().snapshot() },
        loadSensors: @escaping () throws -> SensorSnapshot = { try SensorService.make().snapshot() },
        loadResources: @escaping () -> AppResourceSnapshot = { AppResourceMonitor.shared.snapshot() }
    ) {
        self.clock = clock
        self.loadTelemetry = loadTelemetry
        self.loadStatus = loadStatus
        self.loadFans = loadFans
        self.loadSensors = loadSensors
        self.loadResources = loadResources
    }

    var latest: SharedTelemetrySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    func snapshot(
        previousTelemetry: SystemTelemetrySnapshot?,
        includeSMC: Bool,
        fullTelemetry: Bool,
        force: Bool = false
    ) -> SharedTelemetrySnapshot {
        // Reutiliza la misma muestra si dos consumidores coinciden al iniciar o abrir un panel.
        sampleLock.lock()
        defer { sampleLock.unlock() }
        let date = clock()
        let previous = latest
        lock.lock()
        let generation = smcInvalidationGeneration
        let epoch = samplingEpoch
        lock.unlock()
        let samplingRestarted = epoch != loadedSamplingEpoch
        if samplingRestarted {
            fullTelemetryDate = nil
            lastSMCAttempt = nil
            loadedSamplingEpoch = epoch
        }
        let smcInvalidated = generation != loadedSMCGeneration
        if !force, !samplingRestarted, let previous, date.timeIntervalSince(previous.date) < 1,
           (!includeSMC || (lastSMCAttempt != nil && !smcInvalidated)),
           (!fullTelemetry || fullTelemetryDate != nil) {
            return previous
        }

        let previousDiskDate = fullTelemetryDate
        let shouldLoadFull = force || fullTelemetryDate == nil
            || fullTelemetryDate.map { date.timeIntervalSince($0) >= slowInterval } == true
        let telemetry = shouldLoadFull
            ? loadTelemetry()
            : loadStatus(previous?.telemetry ?? previousTelemetry)
        if shouldLoadFull { fullTelemetryDate = date }
        let diskReadBps = shouldLoadFull
            ? Self.counterRate(telemetry.diskIO.readBytes, previous?.telemetry.diskIO.readBytes, date, previousDiskDate)
            : previous?.diskReadBps
        let diskWriteBps = shouldLoadFull
            ? Self.counterRate(telemetry.diskIO.writtenBytes, previous?.telemetry.diskIO.writtenBytes, date, previousDiskDate)
            : previous?.diskWriteBps
        let diskReadOps = shouldLoadFull
            ? Self.counterRate(telemetry.diskIO.readOperations, previous?.telemetry.diskIO.readOperations, date, previousDiskDate)
            : previous?.diskReadOpsPerSecond
        let diskWriteOps = shouldLoadFull
            ? Self.counterRate(telemetry.diskIO.writeOperations, previous?.telemetry.diskIO.writeOperations, date, previousDiskDate)
            : previous?.diskWriteOpsPerSecond

        var fans = previous?.fans
        var sensors = previous?.sensors
        var fanError = previous?.fanError
        var sensorError = previous?.sensorError
        var fanDate = previous?.fanDate
        var sensorDate = previous?.sensorDate
        let shouldLoadSMC = includeSMC
            && (force || smcInvalidated || lastSMCAttempt == nil || lastSMCAttempt.map { date.timeIntervalSince($0) >= slowInterval } == true)

        if shouldLoadSMC {
            lastSMCAttempt = date
            loadedSMCGeneration = generation
            do {
                fans = try loadFans()
                fanDate = date
                fanError = nil
            } catch {
                fanError = error.localizedDescription
            }
            do {
                let reading = try loadSensors()
                guard !reading.readings.isEmpty else { throw SensorReadError.unavailable }
                sensors = reading
                sensorDate = date
                sensorError = nil
            } catch {
                sensorError = error.localizedDescription
            }
        }

        var snapshot = SharedTelemetrySnapshot(
            date: date,
            samplingEpoch: epoch,
            smcDate: lastSMCAttempt,
            telemetry: telemetry,
            fans: fans,
            sensors: sensors,
            fanError: fanError,
            sensorError: sensorError,
            fanDate: fanDate,
            sensorDate: sensorDate,
            appResources: loadResources(),
            diskDate: fullTelemetryDate ?? date,
            diskReadBps: diskReadBps,
            diskWriteBps: diskWriteBps
        )
        snapshot.diskReadOpsPerSecond = diskReadOps
        snapshot.diskWriteOpsPerSecond = diskWriteOps
        lock.lock()
        latestSnapshot = snapshot
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .telemetryUpdated, object: snapshot)
        }
        return snapshot
    }

    func invalidateSMC() {
        lock.lock()
        defer { lock.unlock() }
        smcInvalidationGeneration &+= 1
    }

    func resetAfterWake() {
        lock.lock()
        defer { lock.unlock() }
        samplingEpoch &+= 1
        smcInvalidationGeneration &+= 1
    }

    static func counterRate(_ current: UInt64, _ previous: UInt64?, _ date: Date, _ previousDate: Date?) -> Double? {
        guard let previous, let previousDate, current >= previous,
              TelemetryContinuity.isContinuous(from: previousDate, to: date) else { return nil }
        return Double(current - previous) / date.timeIntervalSince(previousDate)
    }
}
