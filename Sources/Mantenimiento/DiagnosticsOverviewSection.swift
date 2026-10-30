import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var overview: some View {
        let verdict = OverviewVerdict.make(snapshot: snapshot, cpuUsage: history.latestCPUUsage)

        return VStack(spacing: 14) {
            SectionPanel(title: "Estado", symbol: verdict.symbol) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: verdict.symbol)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(verdict.tint)
                        .frame(width: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verdict.title)
                            .font(.system(size: 20, weight: .semibold))
                        Text(verdict.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "CPU",
                    value: history.latestCPUUsage.map(formatPercent) ?? "calculando",
                    symbol: "cpu",
                    tint: .accentColor
                )
                MetricView(
                    title: "GPU",
                    value: history.latestGPUUsage.map(formatPercent) ?? "sin datos",
                    symbol: "square.stack.3d.up.fill",
                    tint: .accentColor
                )
                MetricView(
                    title: "Memoria",
                    value: snapshot.telemetry.memory.isAvailable ? formatPercent(snapshot.telemetry.memory.usedRatio) : "--",
                    symbol: "memorychip",
                    tint: snapshot.telemetry.memory.pressureLevel >= 2 ? .orange : .secondary
                )
                NetworkMetricView(up: history.latestNetworkUpBps, down: history.latestNetworkDownBps)
                MetricView(
                    title: "Temp. máx.",
                    value: snapshot.sensors?.hottestTemperature.map { formatTemperature($0.value) } ?? "sin datos",
                    symbol: "flame",
                    tint: snapshot.system.thermalTint
                )
                if let battery = snapshot.telemetry.battery {
                    BatteryMetricView(battery: battery)
                        .onTapGesture { selectedSection = .energy }
                }
            }

            MaintenanceReviewPanel(items: maintenanceReviewItems)

            SectionPanel(title: "Mayor carga", symbol: "speedometer") {
                if isRefreshingTopDemand && topCPUDemand == nil {
                    Text("Buscando el proceso que más CPU usa...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let topCPUDemand {
                    InfoRow(title: shortProcessName(topCPUDemand.name), value: topCPUDemand.detail)
                    Text("Proceso con más uso de CPU en este momento.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sin actividad destacada.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var maintenanceReviewItems: [MaintenanceReviewItem] {
        MaintenanceReview.items(for: MaintenanceReview.Input(
            bootVolume: snapshot.telemetry.volumes.first(where: \.isRootVolume),
            disk: snapshot.telemetry.disk,
            uptime: ProcessInfo.processInfo.systemUptime,
            memory: snapshot.telemetry.memory,
            swap: snapshot.telemetry.swap,
            battery: snapshot.telemetry.battery,
            security: securityDetails
        ))
    }
}
