import Foundation
import ServiceManagement

enum LaunchAtLogin {
    enum State: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    static var stateDescription: String {
        switch state {
        case .enabled:
            return "Se abrirá al iniciar sesión."
        case .disabled:
            return "No se abre al iniciar sesión."
        case .requiresApproval:
            return "Pendiente de aprobar en Ajustes > General > Ítems de inicio."
        case .unavailable:
            return "Solo disponible con la app instalada en Aplicaciones."
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
