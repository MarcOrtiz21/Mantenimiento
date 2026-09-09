import AppKit
import UserNotifications

enum PrivacySettings {
    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoring() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openNotifications() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    static func requestAccessibilityPrompt() {
        _ = InputBlocker.isAccessibilityTrusted(prompt: true)
        openAccessibility()
    }

    static func requestInputMonitoringPrompt() {
        _ = InputBlocker.isInputMonitoringTrusted(prompt: true)
        openInputMonitoring()
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum PermissionReadiness {
    case granted
    case denied
    case notDetermined
    case missing
    case unknown

    var title: String {
        switch self {
        case .granted:
            return "Permitido"
        case .denied:
            return "Denegado"
        case .notDetermined:
            return "Sin solicitar"
        case .missing:
            return "Falta"
        case .unknown:
            return "Desconocido"
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}

enum NotificationPermissionStatus {
    static func current(completion: @escaping (PermissionReadiness) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: PermissionReadiness
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                status = .granted
            case .denied:
                status = .denied
            case .notDetermined:
                status = .notDetermined
            @unknown default:
                status = .unknown
            }
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }
}
