import Foundation

enum AppPreferenceKeys {
    static let openPanelAtLaunch = "openPanelAtLaunch"
    static let showStatusItem = "showStatusItem"
    static let statusRefreshInterval = "statusRefreshInterval"
    static let showCPUInMenuBar = "showCPUInMenuBar"
    static let showGPUInMenuBar = "showGPUInMenuBar"
    static let showMemoryInMenuBar = "showMemoryInMenuBar"
    static let showNetworkInMenuBar = "showNetworkInMenuBar"
    static let showBatteryInMenuBar = "showBatteryInMenuBar"
    static let systemNotificationsEnabled = "systemNotificationsEnabled"
    static let notificationSoundEnabled = "notificationSoundEnabled"
    static let temperatureAlertsEnabled = "temperatureAlertsEnabled"
    static let temperatureWarningThreshold = "temperatureWarningThreshold"
    static let temperatureCriticalThreshold = "temperatureCriticalThreshold"
    static let memoryAlertsEnabled = "memoryAlertsEnabled"
    static let memoryPressureThreshold = "memoryPressureThreshold"
    static let fanAlertsEnabled = "fanAlertsEnabled"
    static let appCostAlertsEnabled = "appCostAlertsEnabled"
    static let appCPUThreshold = "appCPUThreshold"
    static let alertCooldown = "alertCooldown"
    static let diskAlertsEnabled = "diskAlertsEnabled"
    static let diskFreeThreshold = "diskFreeThreshold"
    static let runawayProcessAlertsEnabled = "runawayProcessAlertsEnabled"
    static let runawayProcessThreshold = "runawayProcessThreshold"
    static let runawayProcessDuration = "runawayProcessDuration"
}

enum AppPreferences {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            AppPreferenceKeys.openPanelAtLaunch: true,
            AppPreferenceKeys.showStatusItem: true,
            AppPreferenceKeys.statusRefreshInterval: 1.5,
            AppPreferenceKeys.showCPUInMenuBar: true,
            AppPreferenceKeys.showGPUInMenuBar: true,
            AppPreferenceKeys.showMemoryInMenuBar: true,
            AppPreferenceKeys.showNetworkInMenuBar: true,
            AppPreferenceKeys.showBatteryInMenuBar: false,
            AppPreferenceKeys.systemNotificationsEnabled: false,
            AppPreferenceKeys.notificationSoundEnabled: false,
            AppPreferenceKeys.temperatureAlertsEnabled: true,
            AppPreferenceKeys.temperatureWarningThreshold: 85.0,
            AppPreferenceKeys.temperatureCriticalThreshold: 95.0,
            AppPreferenceKeys.memoryAlertsEnabled: true,
            AppPreferenceKeys.memoryPressureThreshold: 3,
            AppPreferenceKeys.fanAlertsEnabled: true,
            AppPreferenceKeys.appCostAlertsEnabled: false,
            AppPreferenceKeys.appCPUThreshold: 0.10,
            AppPreferenceKeys.alertCooldown: 900.0,
            AppPreferenceKeys.diskAlertsEnabled: true,
            AppPreferenceKeys.diskFreeThreshold: 0.10,
            AppPreferenceKeys.runawayProcessAlertsEnabled: true,
            AppPreferenceKeys.runawayProcessThreshold: 0.9,
            AppPreferenceKeys.runawayProcessDuration: 300.0
        ])
    }

    static var openPanelAtLaunch: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.openPanelAtLaunch)
    }

    static var showStatusItem: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.showStatusItem)
    }

    static var statusRefreshInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: AppPreferenceKeys.statusRefreshInterval)
        if value >= 1.0 {
            return value
        }
        return 1.5
    }

    static var enabledMenuBarSections: [MenuBarSection] {
        let defaults = UserDefaults.standard
        let sections: [MenuBarSection] = [
            defaults.bool(forKey: AppPreferenceKeys.showCPUInMenuBar) ? .cpu : nil,
            defaults.bool(forKey: AppPreferenceKeys.showGPUInMenuBar) ? .gpu : nil,
            defaults.bool(forKey: AppPreferenceKeys.showMemoryInMenuBar) ? .memory : nil,
            defaults.bool(forKey: AppPreferenceKeys.showNetworkInMenuBar) ? .network : nil
        ].compactMap { $0 }

        return sections.isEmpty ? [.cpu, .gpu, .memory, .network] : sections
    }

    static func displayedMenuBarSections(hasBattery: Bool) -> [MenuBarSection] {
        enabledMenuBarSections
    }

    static var systemNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.systemNotificationsEnabled)
    }

    static var notificationSoundEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.notificationSoundEnabled)
    }

    static var temperatureAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.temperatureAlertsEnabled)
    }

    static var temperatureWarningThreshold: Double {
        min(max(UserDefaults.standard.double(forKey: AppPreferenceKeys.temperatureWarningThreshold), 60), 105)
    }

    static var temperatureCriticalThreshold: Double {
        max(
            min(max(UserDefaults.standard.double(forKey: AppPreferenceKeys.temperatureCriticalThreshold), 65), 110),
            temperatureWarningThreshold + 5
        )
    }

    static var memoryAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.memoryAlertsEnabled)
    }

    static var memoryPressureThreshold: Int {
        max(UserDefaults.standard.integer(forKey: AppPreferenceKeys.memoryPressureThreshold), 2)
    }

    static var fanAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.fanAlertsEnabled)
    }

    static var appCostAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.appCostAlertsEnabled)
    }

    static var appCPUThreshold: Double {
        min(max(UserDefaults.standard.double(forKey: AppPreferenceKeys.appCPUThreshold), 0.03), 0.50)
    }

    static var alertCooldown: TimeInterval {
        max(UserDefaults.standard.double(forKey: AppPreferenceKeys.alertCooldown), 300)
    }

    static var diskAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.diskAlertsEnabled)
    }

    static var diskFreeThreshold: Double {
        min(max(UserDefaults.standard.double(forKey: AppPreferenceKeys.diskFreeThreshold), 0.03), 0.30)
    }

    static var runawayProcessAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppPreferenceKeys.runawayProcessAlertsEnabled)
    }

    /// Fracción de un núcleo (1,0 = un núcleo completo).
    static var runawayProcessThreshold: Double {
        min(max(UserDefaults.standard.double(forKey: AppPreferenceKeys.runawayProcessThreshold), 0.5), 4)
    }

    static var runawayProcessDuration: TimeInterval {
        min(max(UserDefaults.standard.double(forKey: AppPreferenceKeys.runawayProcessDuration), 60), 3_600)
    }
}
