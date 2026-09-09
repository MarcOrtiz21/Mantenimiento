import Foundation
import OSLog
import UserNotifications

enum MaintenanceAlertSeverity {
    case warning
    case critical
}

struct MaintenanceAlert: Identifiable {
    let id: String
    let severity: MaintenanceAlertSeverity
    let title: String
    let detail: String
    let requiredSamples: Int
    let requiresFreshSMC: Bool
}

enum MaintenanceAlertEvaluator {
    static func alerts(for snapshot: MenuBarSnapshot) -> [MaintenanceAlert] {
        var alerts: [MaintenanceAlert] = []

        if AppPreferences.temperatureAlertsEnabled,
           let hottest = snapshot.sensors?.hottestTemperature {
            let temperature = Double(hottest.value)
            if temperature >= AppPreferences.temperatureCriticalThreshold {
                alerts.append(MaintenanceAlert(
                    id: "temperature.critical",
                    severity: .critical,
                    title: "Temperatura crítica",
                    detail: "\(hottest.sensor.name) a \(Int(temperature.rounded())) C",
                    requiredSamples: 2,
                    requiresFreshSMC: true
                ))
            } else if temperature >= AppPreferences.temperatureWarningThreshold {
                alerts.append(MaintenanceAlert(
                    id: "temperature.warning",
                    severity: .warning,
                    title: "Temperatura alta",
                    detail: "\(hottest.sensor.name) a \(Int(temperature.rounded())) C",
                    requiredSamples: 2,
                    requiresFreshSMC: true
                ))
            }
        }

        if AppPreferences.memoryAlertsEnabled,
           snapshot.telemetry.memory.pressureLevel >= AppPreferences.memoryPressureThreshold {
            let isCritical = snapshot.telemetry.memory.pressureLevel >= 3
            alerts.append(MaintenanceAlert(
                id: "memory.pressure",
                severity: isCritical ? .critical : .warning,
                title: isCritical ? "Presión de memoria alta" : "Presión de memoria moderada",
                detail: "\(alertPercent(snapshot.telemetry.memory.usedRatio)) de RAM usada",
                requiredSamples: 3,
                requiresFreshSMC: false
            ))
        }

        if AppPreferences.fanAlertsEnabled, let fans = snapshot.fans?.fans {
            for fan in fans {
                let thermalDemand = snapshot.thermalState == "alto" || snapshot.thermalState == "crítico"
                guard fan.mode == .manual || thermalDemand else {
                    continue
                }

                let expectedRPM = max(fan.targetRPM, fan.minRPM)
                let stalledThreshold = max(expectedRPM * 0.20, 200)
                guard expectedRPM >= 1_000, fan.actualRPM < stalledThreshold else {
                    continue
                }

                alerts.append(MaintenanceAlert(
                    id: "fan.\(fan.index)",
                    severity: .critical,
                    title: "\(fan.displayName) sin respuesta",
                    detail: "\(Int(fan.actualRPM.rounded())) RPM; esperado \(Int(expectedRPM.rounded())) RPM",
                    requiredSamples: 3,
                    requiresFreshSMC: true
                ))
            }
        }

        if AppPreferences.appCostAlertsEnabled,
           let cpuRatio = snapshot.appResources.cpuRatio,
           cpuRatio >= AppPreferences.appCPUThreshold {
            alerts.append(MaintenanceAlert(
                id: "app.cpu",
                severity: .warning,
                title: "Consumo alto de Mantenimiento",
                detail: "La app usa \(alertPercent(cpuRatio)) de CPU",
                requiredSamples: 4,
                requiresFreshSMC: false
            ))
        }

        return alerts
    }
}

final class MaintenanceAlertMonitor {
    static let shared = MaintenanceAlertMonitor()

    private struct State {
        var alert: MaintenanceAlert
        var consecutiveSamples: Int
        var isActive: Bool
        var lastNotificationDate: Date?
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento",
        category: "Alerts"
    )
    private var states: [String: State] = [:]
    private var lastProcessedSMCDate: Date?

    private init() {}

    func process(snapshot: MenuBarSnapshot) {
        let alerts = MaintenanceAlertEvaluator.alerts(for: snapshot)
        let alertsByID = Dictionary(uniqueKeysWithValues: alerts.map { ($0.id, $0) })
        let hasFreshSMC = snapshot.smcDate != nil && snapshot.smcDate != lastProcessedSMCDate

        for id in Array(states.keys) where alertsByID[id] == nil {
            guard var state = states[id] else {
                continue
            }
            if state.alert.requiresFreshSMC && !hasFreshSMC {
                continue
            }
            state.consecutiveSamples = 0
            state.isActive = false
            states[id] = state
        }

        for alert in alerts {
            if alert.requiresFreshSMC && !hasFreshSMC {
                continue
            }

            var state = states[alert.id] ?? State(
                alert: alert,
                consecutiveSamples: 0,
                isActive: false,
                lastNotificationDate: nil
            )
            state.alert = alert
            state.consecutiveSamples += 1

            if state.consecutiveSamples >= alert.requiredSamples {
                if !state.isActive {
                    state.isActive = true
                }
                if shouldNotify(state: state) {
                    state.lastNotificationDate = Date()
                    AlertNotificationService.shared.send(alert)
                    logger.notice("Alert delivered: \(alert.id, privacy: .public)")
                }
            }

            states[alert.id] = state
        }

        if hasFreshSMC {
            lastProcessedSMCDate = snapshot.smcDate
        }
    }

    func reset() {
        states.removeAll()
        lastProcessedSMCDate = nil
        logger.debug("Alert state reset after preferences change")
    }

    private func shouldNotify(state: State) -> Bool {
        guard AppPreferences.systemNotificationsEnabled else {
            return false
        }
        guard let lastNotificationDate = state.lastNotificationDate else {
            return true
        }
        return Date().timeIntervalSince(lastNotificationDate) >= AppPreferences.alertCooldown
    }
}

final class AlertNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento",
        category: "Notifications"
    )

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
        logger.info("Notification center configured")
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Notification authorization result: \(granted, privacy: .public)")
            }
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    func authorizationDescription(completion: @escaping (String) -> Void) {
        center.getNotificationSettings { settings in
            let description: String
            switch settings.authorizationStatus {
            case .notDetermined:
                description = "Sin solicitar"
            case .denied:
                description = "Denegadas"
            case .authorized:
                description = "Permitidas"
            case .provisional:
                description = "Provisionales"
            case .ephemeral:
                description = "Temporales"
            @unknown default:
                description = "Desconocido"
            }
            DispatchQueue.main.async {
                completion(description)
            }
        }
    }

    func send(_ alert: MaintenanceAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.threadIdentifier = "local.marc.mantenimiento.alerts"
        if AppPreferences.notificationSoundEnabled {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: "maintenance.\(alert.id).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { [logger] error in
            if let error {
                logger.error("Notification scheduling failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func sendTestNotification() {
        let alert = MaintenanceAlert(
            id: "test",
            severity: .warning,
            title: "Mantenimiento",
            detail: "Las alertas del sistema estan funcionando.",
            requiredSamples: 1,
            requiresFreshSMC: false
        )
        send(alert)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}

private func alertPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}
