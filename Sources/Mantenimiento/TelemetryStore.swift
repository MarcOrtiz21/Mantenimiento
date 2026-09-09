import Foundation
import MantenimientoCore

struct SharedTelemetrySnapshot {
    let date: Date
    let smcDate: Date?
    let telemetry: SystemTelemetrySnapshot
    let fans: FanSnapshot?
    let sensors: SensorSnapshot?
    let fanError: String?
    let sensorError: String?
    let appResources: AppResourceSnapshot
}

final class TelemetryStore {
    static let shared = TelemetryStore()

    private let lock = NSLock()
    private let sampleLock = NSLock()
    private var fullTelemetryInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 8.0 : 4.5
    }

    private var smcInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 8.0 : 4.5
    }

    private var cachedTelemetry: SystemTelemetrySnapshot?
    private var cachedTelemetryDate: Date?
    private var cachedFans: FanSnapshot?
    private var cachedFanError: String?
    private var cachedSensors: SensorSnapshot?
    private var cachedSensorError: String?
    private var cachedSMCDate: Date?

    private init() {}

    func snapshot(
        previousTelemetry: SystemTelemetrySnapshot?,
        includeSMC: Bool,
        fullTelemetry: Bool,
        force: Bool = false
    ) -> SharedTelemetrySnapshot {
        // Serializa las lecturas de SMC cuando ventana y barra refrescan a la vez.
        sampleLock.lock()
        defer { sampleLock.unlock() }

        let date = Date()
        let state = cachedState()
        let shouldLoadFullTelemetry = force
            || fullTelemetry
            || state.telemetry == nil
            || state.telemetryDate.map { date.timeIntervalSince($0) >= fullTelemetryInterval } != false
        let shouldLoadSMC = includeSMC
            && (force || state.smcDate == nil || state.smcDate.map { date.timeIntervalSince($0) >= smcInterval } != false)

        let telemetry: SystemTelemetrySnapshot
        if shouldLoadFullTelemetry {
            telemetry = SystemTelemetryService.snapshot()
        } else if let previousTelemetry = state.telemetry ?? previousTelemetry {
            telemetry = SystemTelemetryService.statusSnapshot(previous: previousTelemetry)
        } else {
            telemetry = SystemTelemetryService.statusSnapshot()
        }

        let fanResult: Result<FanSnapshot, Error>? = shouldLoadSMC
            ? Result { try FanService.make().snapshot() }
            : nil
        let sensorResult: Result<SensorSnapshot, Error>? = shouldLoadSMC
            ? Result { try SensorService.make().snapshot() }
            : nil

        let fans = fanResult.flatMap { try? $0.get() } ?? state.fans
        let sensors = sensorResult.flatMap { try? $0.get() } ?? state.sensors
        let fanError = fanResult?.failureDescription ?? state.fanError
        let sensorError = sensorResult?.failureDescription ?? state.sensorError
        let smcDate = shouldLoadSMC ? date : state.smcDate
        let appResources = AppResourceMonitor.shared.snapshot()

        lock.lock()
        cachedTelemetry = telemetry
        cachedTelemetryDate = date
        cachedFans = fans
        cachedFanError = fanError
        cachedSensors = sensors
        cachedSensorError = sensorError
        cachedSMCDate = smcDate
        lock.unlock()

        return SharedTelemetrySnapshot(
            date: date,
            smcDate: smcDate,
            telemetry: telemetry,
            fans: fans,
            sensors: sensors,
            fanError: fanError,
            sensorError: sensorError,
            appResources: appResources
        )
    }

    func invalidateSMC() {
        lock.lock()
        cachedSMCDate = nil
        lock.unlock()
    }

    private func cachedState() -> CachedState {
        lock.lock()
        defer { lock.unlock() }
        return CachedState(
            telemetry: cachedTelemetry,
            telemetryDate: cachedTelemetryDate,
            fans: cachedFans,
            fanError: cachedFanError,
            sensors: cachedSensors,
            sensorError: cachedSensorError,
            smcDate: cachedSMCDate
        )
    }
}

private struct CachedState {
    let telemetry: SystemTelemetrySnapshot?
    let telemetryDate: Date?
    let fans: FanSnapshot?
    let fanError: String?
    let sensors: SensorSnapshot?
    let sensorError: String?
    let smcDate: Date?
}

private extension Result {
    var failureDescription: String? {
        if case .failure(let error) = self {
            return error.localizedDescription
        }
        return nil
    }
}
