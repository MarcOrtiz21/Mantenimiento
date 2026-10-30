import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var powerSection: some View {
        let power = snapshot.sensors?.readings(type: .power) ?? []

        return VStack(spacing: 14) {
            if let battery = snapshot.telemetry.battery {
                batteryPanel(battery)
                powerFlowPanel(battery)
            }

            SectionPanel(title: "Puertos USB-C", symbol: "cable.connector") {
                USBCPortsView(
                    ports: snapshot.telemetry.battery?.ports ?? [],
                    devices: snapshot.telemetry.usbDevices,
                    adapter: snapshot.telemetry.battery?.adapter
                )
            }

            powerSensorsPanel(power)

            if snapshot.telemetry.battery != nil {
                SectionPanel(title: "Salud a largo plazo", symbol: "chart.line.downtrend.xyaxis") {
                    BatteryHealthTrendView(entries: batteryHealthEntries)
                }
            }

            SectionPanel(title: "Consumo por aplicación", symbol: "leaf") {
                AppEnergyUsageList(usage: appEnergyUsage, isSampling: isSamplingEnergy)
            }
        }
    }

    func powerSensorsPanel(_ power: [SensorReading]) -> some View {
            SectionPanel(title: "Sensores de potencia", symbol: "bolt") {
                ResponsiveChartGrid(charts: [
                    SparklineChartView(
                        title: "Consumo del sistema",
                        value: (history.latest?.systemLoadPower ?? history.latestSystemPower).map { String(format: "%.1f", $0) } ?? "sin datos",
                        unit: "W",
                        symbol: "bolt",
                        points: history.latest?.systemLoadPower != nil ? history.systemLoadPowerPoints : history.powerPoints
                    ),
                    SparklineChartView(
                        title: "Batería (+ carga / − descarga)",
                        value: history.latest?.batteryPower.map { String(format: "%+.1f", $0) } ?? "sin datos",
                        unit: "W",
                        symbol: "bolt.batteryblock",
                        points: history.batteryPowerPoints
                    )
                ])

                if power.isEmpty {
                    EmptyStateView(message: "Sin lecturas de potencia SMC por ahora.")
                } else {
                    SensorGroupView(
                        title: "SMC",
                        readings: power,
                        formatter: { String(format: "%.1f W", $0) },
                        ceiling: 120
                    )
                }
            }
    }

    func batteryPanel(_ battery: BatterySnapshot) -> some View {
        SectionPanel(title: "Batería", symbol: batterySymbolName(battery)) {
            HStack(alignment: .center, spacing: 16) {
                BatteryGlyph(battery: battery, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(battery.percent)%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(batteryHeadline(battery))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Condición",
                    value: battery.condition.map(localizedBatteryCondition) ?? "sin datos",
                    symbol: "heart.text.square",
                    tint: battery.condition.map { localizedBatteryCondition($0) == "Normal" ? Color.green : .orange } ?? .secondary
                )
                MetricView(
                    title: "Capacidad máxima",
                    value: battery.healthPercent.map { "\($0)%" } ?? "sin datos",
                    symbol: "battery.100percent",
                    tint: (battery.healthPercent ?? 100) < 80 ? .orange : .secondary
                )
                MetricView(
                    title: "Ciclos",
                    value: battery.cycleCount.map { cycles in
                        battery.designCycleCount.map { "\(cycles) de \($0)" } ?? "\(cycles)"
                    } ?? "sin datos",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .secondary
                )
                MetricView(
                    title: "Temperatura",
                    value: battery.temperatureCelsius.map { String(format: "%.1f C", $0) } ?? "sin datos",
                    symbol: "thermometer.medium",
                    tint: (battery.temperatureCelsius ?? 0) >= 40 ? .orange : .secondary
                )
                MetricView(
                    title: "Voltaje",
                    value: battery.voltageMillivolts.map { String(format: "%.2f V", Double($0) / 1_000) } ?? "sin datos",
                    symbol: "bolt.horizontal",
                    tint: .secondary
                )
                MetricView(
                    title: "Corriente",
                    value: battery.amperageMilliamps.map { String(format: "%+.2f A", Double($0) / 1_000) } ?? "sin datos",
                    symbol: "waveform.path",
                    tint: .secondary
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                InfoRow(
                    title: "Carga actual",
                    value: battery.currentCapacityMah.map { current in
                        battery.fullChargeCapacityMah.map { "\(current) de \($0) mAh" } ?? "\(current) mAh"
                    } ?? "sin datos"
                )
                InfoRow(
                    title: "Capacidad",
                    value: [
                        battery.fullChargeCapacityMah.map { "completa \($0) mAh" },
                        battery.maxCapacity.map { "nominal \($0) mAh" },
                        battery.designCapacity.map { "diseño \($0) mAh" }
                    ].compactMap { $0 }.joined(separator: " · ")
                )
                if battery.isChargingPaused {
                    InfoRow(title: "Carga en pausa", value: "Carga optimizada, límite de carga o temperatura alta")
                }
            }
            Text("Una batería nueva puede superar su capacidad de diseño; macOS limita la capacidad máxima al 100%.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func powerFlowPanel(_ battery: BatterySnapshot) -> some View {
        SectionPanel(title: battery.externalConnected ? "Alimentación" : "Consumo", symbol: battery.externalConnected ? "powerplug" : "bolt.batteryblock") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                if battery.externalConnected {
                    MetricView(
                        title: "Entrada del cargador",
                        value: battery.systemPowerInWatts.map { String(format: "%.1f W", $0) } ?? "sin datos",
                        symbol: "powerplug.fill",
                        tint: .green
                    )
                }
                MetricView(
                    title: "Consumo del sistema",
                    value: battery.systemLoadWatts.map { String(format: "%.1f W", $0) } ?? "sin datos",
                    symbol: "laptopcomputer",
                    tint: .accentColor
                )
                MetricView(
                    title: (battery.batteryPowerWatts ?? 0) >= 0 ? "Hacia la batería" : "Desde la batería",
                    value: battery.batteryPowerWatts.map { String(format: "%.1f W", abs($0)) } ?? "sin datos",
                    symbol: (battery.batteryPowerWatts ?? 0) >= 0 ? "battery.100percent.bolt" : "battery.50percent",
                    tint: (battery.batteryPowerWatts ?? 0) >= 0 ? .green : .orange
                )
            }

            if let adapter = battery.adapter {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "Cargador", value: adapter.name ?? "conectado")
                    InfoRow(
                        title: "Negociado",
                        value: [
                            adapter.watts.map { "\($0) W" },
                            adapter.voltageMillivolts.map { String(format: "%.0f V", Double($0) / 1_000) },
                            adapter.currentMilliamps.map { String(format: "%.2f A", Double($0) / 1_000) }
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    if let manufacturer = adapter.manufacturer {
                        InfoRow(title: "Fabricante", value: adapter.isWireless ? "\(manufacturer) (inalámbrico)" : manufacturer)
                    }
                }
                if let input = battery.systemPowerInWatts, let watts = adapter.watts, watts > 0, input >= Double(watts) * 0.9 {
                    Text("El cargador va al límite: si el consumo sube, la batería dejará de cargar o se descargará.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if !battery.externalConnected {
                InfoRow(title: "Cargador", value: "desconectado")
            }
        }
    }

    func batteryHeadline(_ battery: BatterySnapshot) -> String {
        if battery.isCharged || (battery.externalConnected && battery.percent >= 100) {
            return "Cargada y conectada"
        }
        if battery.isCharging {
            return battery.timeToFullMinutes.map { "Cargando · llena en \(formatBatteryMinutes($0))" } ?? "Cargando"
        }
        if battery.externalConnected {
            return "Conectada, carga en pausa"
        }
        return battery.timeToEmptyMinutes.map { "Con batería · quedan \(formatBatteryMinutes($0))" } ?? "Con batería · calculando autonomía"
    }
}
