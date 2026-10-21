import Foundation
import MantenimientoCore

struct MaintenanceReviewItem: Identifiable, Equatable {
    enum Status: Int, Comparable {
        case ok
        case info
        case warning
        case critical

        static func < (lhs: Status, rhs: Status) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
}

enum MaintenanceReview {
    struct Input {
        let bootVolume: VolumeSnapshot?
        let disk: DiskSnapshot
        let uptime: TimeInterval
        let memory: MemorySnapshot
        let swap: SwapSnapshot
        let battery: BatterySnapshot?
        let security: SecurityDetails?
    }

    static let longUptime: TimeInterval = 14 * 24 * 60 * 60

    static func items(for input: Input) -> [MaintenanceReviewItem] {
        var items: [MaintenanceReviewItem] = []

        let totalBytes = input.bootVolume?.totalBytes ?? input.disk.totalBytes
        let availableBytes = input.bootVolume?.availableBytes ?? input.disk.availableBytes
        if totalBytes > 0 {
            let freeRatio = Double(availableBytes) / Double(totalBytes)
            let free = ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
            let status: MaintenanceReviewItem.Status = freeRatio < 0.05 ? .critical : freeRatio < 0.12 ? .warning : .ok
            items.append(MaintenanceReviewItem(
                id: "disk",
                title: "Espacio en disco",
                detail: status == .ok
                    ? "\(free) libres (\(percent(freeRatio)))."
                    : "Solo quedan \(free) (\(percent(freeRatio))). macOS necesita margen para swap y actualizaciones.",
                status: status
            ))
        }

        let days = Int(input.uptime / 86_400)
        items.append(MaintenanceReviewItem(
            id: "uptime",
            title: "Tiempo encendido",
            detail: input.uptime >= longUptime
                ? "\(days) días sin reiniciar. Reiniciar libera memoria y aplica actualizaciones pendientes."
                : days > 0 ? "\(days) días desde el último arranque." : "Arrancado hoy.",
            status: input.uptime >= longUptime ? .info : .ok
        ))

        if input.memory.isAvailable {
            let swapRatio = input.memory.totalBytes > 0 ? Double(input.swap.usedBytes) / Double(input.memory.totalBytes) : 0
            let swap = ByteCountFormatter.string(fromByteCount: Int64(input.swap.usedBytes), countStyle: .memory)
            let status: MaintenanceReviewItem.Status = input.memory.pressureLevel >= 4 || swapRatio >= 0.5
                ? .critical
                : input.memory.pressureLevel >= 2 || swapRatio >= 0.25 ? .warning : .ok
            items.append(MaintenanceReviewItem(
                id: "memory",
                title: "Memoria y swap",
                detail: status == .ok
                    ? "Presión \(input.memory.pressureDescription), swap \(swap)."
                    : "Presión \(input.memory.pressureDescription) y \(swap) de swap. Cierra apps pesadas o reinicia.",
                status: status
            ))
        }

        if let battery = input.battery {
            let health = battery.healthPercent
            let condition = battery.condition.map(localizedBatteryCondition)
            let needsService = condition.map { $0 != "Normal" } ?? false
            let status: MaintenanceReviewItem.Status = needsService ? .warning : (health ?? 100) < 80 ? .warning : .ok
            var parts: [String] = []
            if let condition { parts.append("Condición \(condition.lowercased())") }
            if let health { parts.append("capacidad máxima \(health)%") }
            if let cycles = battery.cycleCount {
                parts.append(battery.designCycleCount.map { "\(cycles) de \($0) ciclos" } ?? "\(cycles) ciclos")
            }
            items.append(MaintenanceReviewItem(
                id: "battery",
                title: "Batería",
                detail: parts.isEmpty ? "Sin datos de salud." : parts.joined(separator: ", ") + ".",
                status: status
            ))
        }

        if let security = input.security {
            items.append(securityItem(
                id: "sip", title: "Protección de integridad (SIP)", enabled: security.systemIntegrityProtection,
                disabledDetail: "Desactivada. Solo debería estarlo temporalmente.", disabledStatus: .critical
            ))
            items.append(securityItem(
                id: "filevault", title: "FileVault", enabled: security.fileVault,
                disabledDetail: "El disco no está cifrado. Actívalo en Ajustes > Privacidad y seguridad.", disabledStatus: .warning
            ))
            items.append(securityItem(
                id: "gatekeeper", title: "Gatekeeper", enabled: security.gatekeeper,
                disabledDetail: "Se pueden abrir apps sin verificar.", disabledStatus: .warning
            ))
            items.append(securityItem(
                id: "firewall", title: "Firewall", enabled: security.firewall,
                disabledDetail: "Desactivado. Recomendable en redes públicas.", disabledStatus: .info
            ))
        }

        return items
    }

    private static func securityItem(
        id: String,
        title: String,
        enabled: Bool?,
        disabledDetail: String,
        disabledStatus: MaintenanceReviewItem.Status
    ) -> MaintenanceReviewItem {
        switch enabled {
        case true?:
            return MaintenanceReviewItem(id: id, title: title, detail: "Activado.", status: .ok)
        case false?:
            return MaintenanceReviewItem(id: id, title: title, detail: disabledDetail, status: disabledStatus)
        case nil:
            return MaintenanceReviewItem(id: id, title: title, detail: "No se pudo comprobar.", status: .info)
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

func localizedBatteryCondition(_ condition: String) -> String {
    switch condition.lowercased() {
    case "good", "normal":
        return "Normal"
    case "fair":
        return "Aceptable"
    case "poor":
        return "Deficiente"
    case "check battery":
        return "Revisar batería"
    case "service recommended", "permanent battery failure":
        return "Servicio recomendado"
    default:
        return condition
    }
}
