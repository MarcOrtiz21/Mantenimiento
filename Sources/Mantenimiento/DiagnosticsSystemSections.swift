import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var activitySection: some View {
        SectionPanel(title: "Actividad", symbol: "clock.arrow.circlepath") {
            HStack {
                Text("Alertas, cambios de ventiladores, cargador, estado térmico y reposo de los últimos 30 días.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    EventLog.shared.clear()
                    events = []
                } label: {
                    Label("Borrar", systemImage: "trash")
                }
                .disabled(events.isEmpty)
            }

            if events.isEmpty {
                EmptyStateView(message: "Todavía no hay eventos registrados.")
            } else {
                EventTimelineView(events: events)
            }
        }
    }

    var systemSection: some View {
        VStack(spacing: 14) {
            SectionPanel(title: "Estado del sistema", symbol: "checkmark.shield") {
                HealthStatusRow(title: "Accesibilidad", value: accessibilityTrusted ? "Activa" : "Falta permiso", isHealthy: accessibilityTrusted)
                HealthStatusRow(title: "Monitorización de entrada", value: inputMonitoringTrusted ? "Activa" : "Falta permiso", isHealthy: inputMonitoringTrusted)
                HealthStatusRow(title: "Helper de ventiladores", value: helperStatusText, isHealthy: helperAvailable == true)
                HealthStatusRow(title: "Sensores SMC", value: snapshot.sensorStatus.description, isHealthy: snapshot.sensorStatus.isCurrent)
                HealthStatusRow(title: "Ventiladores SMC", value: snapshot.fanStatus.description, isHealthy: snapshot.fanStatus.isCurrent)
                HealthStatusRow(title: "Última lectura", value: lastTelemetryDate?.formatted(date: .omitted, time: .standard) ?? "Esperando...", isHealthy: lastTelemetryDate != nil)
            }

            SectionPanel(title: "Seguridad", symbol: "lock.shield") {
                if let securityDetails {
                    HealthStatusRow(title: "Protección de integridad (SIP)", value: securityValue(securityDetails.systemIntegrityProtection), isHealthy: securityDetails.systemIntegrityProtection == true)
                    HealthStatusRow(title: "FileVault", value: securityValue(securityDetails.fileVault), isHealthy: securityDetails.fileVault == true)
                    HealthStatusRow(title: "Gatekeeper", value: securityValue(securityDetails.gatekeeper), isHealthy: securityDetails.gatekeeper == true)
                    HealthStatusRow(title: "Firewall", value: securityValue(securityDetails.firewall), isHealthy: securityDetails.firewall == true)
                } else {
                    EmptyStateView(message: "Comprobando...")
                }
            }

            SectionPanel(title: "Sistema", symbol: "info.circle") {
            InfoRow(title: "Modelo", value: [hardwareDetails?.modelName, hardwareDetails?.modelIdentifier ?? snapshot.system.model].compactMap { $0 }.joined(separator: " · "))
            if let number = hardwareDetails?.modelNumber {
                InfoRow(title: "Referencia", value: number)
            }
            InfoRow(title: "Chip", value: hardwareDetails?.chip ?? snapshot.system.processor)
            if let cores = hardwareDetails?.coreSummary {
                InfoRow(title: "Núcleos", value: cores)
            }
            if let memory = hardwareDetails?.memory {
                InfoRow(title: "Memoria", value: memory)
            }
            InfoRow(title: "macOS", value: [osDetails.version, osDetails.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
            if let firmware = hardwareDetails?.firmware {
                InfoRow(title: "Firmware", value: firmware)
            }
            InfoRow(
                title: "Encendido",
                value: osDetails.bootDate.map { "\(snapshot.system.uptime) · desde \($0.formatted(date: .abbreviated, time: .shortened))" } ?? snapshot.system.uptime
            )
            InfoRow(title: "Bajo consumo", value: snapshot.system.lowPowerMode)
            InfoRow(title: "Mantenimiento", value: appResourceSummary(snapshot.appResources))

            HStack {
                Button {
                    copyDiagnosticSummary()
                } label: {
                    Label("Copiar diagnóstico", systemImage: "doc.on.doc")
                }
                Button {
                    exportDiagnosticSummary()
                } label: {
                    Label("Exportar diagnóstico", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            }
        }
    }

    func securityValue(_ enabled: Bool?) -> String {
        switch enabled {
        case true?: return "Activado"
        case false?: return "Desactivado"
        case nil: return "Sin datos"
        }
    }
}
