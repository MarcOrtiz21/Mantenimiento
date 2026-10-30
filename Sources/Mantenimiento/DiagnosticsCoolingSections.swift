import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var cleanSection: some View {
        SectionPanel(title: "Limpieza", symbol: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    PermissionBadge(
                        title: accessibilityTrusted ? "Accesibilidad activa" : "Falta Accesibilidad",
                        isGranted: accessibilityTrusted
                    )
                    PermissionBadge(
                        title: inputMonitoringTrusted ? "Entrada activa" : "Falta Entrada",
                        isGranted: inputMonitoringTrusted
                    )

                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        requestAccessibilityPermission()
                    } label: {
                        Label("Accesibilidad", systemImage: "gearshape")
                    }

                    Button {
                        requestInputMonitoringPermission()
                    } label: {
                        Label("Entrada", systemImage: "keyboard")
                    }
                    .help("Necesario para bloquear teclado, trackpad y ratón durante Limpieza.")

                    Button {
                        repairCleanPermissions()
                    } label: {
                        Label("Reparar permisos", systemImage: "wrench.and.screwdriver")
                    }
                    .help("Restablece solo los permisos de Mantenimiento para concederlos de nuevo.")

                    Button {
                        NotificationCenter.default.post(name: .preferencesRequested, object: nil)
                    } label: {
                        Label("Todos los permisos", systemImage: "lock.shield")
                    }
                    .help("Abre Preferencias para Accesibilidad, entrada y notificaciones.")

                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        requestCleanMode(duration: 60)
                    } label: {
                        Label("1 min", systemImage: "lock")
                    }

                    Button {
                        requestCleanMode(duration: 120)
                    } label: {
                        Label("2 min", systemImage: "lock")
                    }

                    Button {
                        requestCleanMode(duration: 300)
                    } label: {
                        Label("5 min", systemImage: "lock")
                    }
                }
            }
        }
    }

    var fanSection: some View {
        SectionPanel(title: "Ventiladores", symbol: "fanblades") {
            if let fanError = snapshot.fanError {
                EmptyStateView(message: fanError)
            } else if let fans = snapshot.fans {
                HStack(spacing: 10) {
                    Text(fans.modeKeyFormat == nil ? "Control manual no disponible" : "Control manual disponible")
                        .help("Clave SMC de modo: \(fans.modeKeyFormat ?? "no encontrada") · Ftst \(fans.forceTestAvailable ? "disponible" : "no disponible")")
                    Spacer()
                    Button(role: .destructive) {
                        setAllFansTurbo()
                    } label: {
                        Label("Turbo", systemImage: "flame.fill")
                    }
                    .disabled(isWorking)

                    Button {
                        setAllFansAuto()
                    } label: {
                        Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isWorking)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                GlobalFanControlView(
                    fans: fans,
                    isWorking: isWorking,
                    onTurbo: setAllFansTurbo,
                    onAuto: setAllFansAuto
                )

                VStack(spacing: 12) {
                    ForEach(fans.fans, id: \.index) { fan in
                        FanRowView(
                            reading: fan,
                            isWorking: isWorking,
                            onSet: setFan,
                            onAuto: setFanAuto
                        )
                    }
                }
            } else {
                EmptyStateView(message: "No se han encontrado ventiladores.")
            }
        }
    }

    var temperatureSection: some View {
        SectionPanel(title: "Temperaturas", symbol: "thermometer.medium") {
            let temperatures = snapshot.sensors?.temperatures ?? []

            if temperatures.isEmpty {
                EmptyStateView(message: snapshot.sensorError ?? "No hay temperaturas SMC disponibles.")
            } else {
                ForEach(SensorGroup.allCases, id: \.self) { group in
                    let items = temperatures.filter { $0.sensor.group == group }
                    if !items.isEmpty {
                        SensorGroupView(
                            title: group.rawValue,
                            readings: items.sortedBySensorNumber(),
                            formatter: formatTemperature,
                            ceiling: 110
                        )
                    }
                }
            }
        }
    }
}
