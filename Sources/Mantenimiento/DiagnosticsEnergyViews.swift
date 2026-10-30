import AppKit
import SwiftUI

struct AppEnergyUsageList: View {
    let usage: [AppEnergyUsage]
    let isSampling: Bool

    private var rows: [AppEnergyUsage] { Array(usage.prefix(10)) }
    private var maximum: Double { max(rows.first?.energyImpact ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usage.isEmpty {
                EmptyStateView(message: isSampling ? "Midiendo el impacto energético…" : "Ninguna aplicación tiene impacto energético apreciable.")
            } else {
                ForEach(rows) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: AppEnergyUsage) -> some View {
        HStack(spacing: 10) {
            Group {
                if let path = entry.appPath {
                    Image(nsImage: AppNetworkUsageList.cachedIcon(path))
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if entry.processCount > 1 {
                        Text("\(entry.processCount) procesos")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(String(format: "%.1f", entry.energyImpact))
                        .font(.system(.callout, design: .rounded).monospacedDigit())
                }
                ProgressView(value: min(entry.energyImpact / maximum, 1))
                    .tint(tint(entry.energyImpact))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(entry.appPath ?? entry.name)
    }

    private func tint(_ impact: Double) -> Color {
        impact >= 50 ? .orange : impact >= 20 ? .yellow : .green
    }
}

struct BatteryHealthTrendView: View {
    let entries: [BatteryHealthEntry]

    private var chartData: TelemetryChartData {
        TelemetryChartData(
            points: entries.map { TelemetryChartPoint(date: $0.day, value: $0.capacityRatio * 100, segment: 0) },
            gaps: []
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entries.count < 2 {
                EmptyStateView(message: entries.isEmpty
                    ? "Se guarda la capacidad real una vez al día. La gráfica aparecerá a partir de mañana."
                    : "Primera medición guardada: \(entries[0].capacityMah) mAh. La gráfica aparecerá a partir de mañana.")
            } else if let first = entries.first, let last = entries.last {
                SparklineChartView(
                    title: "Capacidad real respecto al diseño",
                    value: String(format: "%.1f", last.capacityRatio * 100),
                    unit: "%",
                    symbol: "battery.100percent",
                    points: chartData
                )
                InfoRow(title: "Desde", value: first.day.formatted(date: .abbreviated, time: .omitted))
                InfoRow(title: "Capacidad", value: "\(first.capacityMah) → \(last.capacityMah) mAh (\(signed(last.capacityMah - first.capacityMah)) mAh)")
                if let firstCycles = first.cycleCount, let lastCycles = last.cycleCount, lastCycles > firstCycles {
                    let lossPerHundred = Double(first.capacityMah - last.capacityMah) / Double(first.designCapacityMah) * 100
                        / Double(lastCycles - firstCycles) * 100
                    InfoRow(title: "Ciclos", value: "\(firstCycles) → \(lastCycles) · \(String(format: "%.1f", max(lossPerHundred, 0)))% de capacidad cada 100 ciclos")
                }
            }
        }
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }
}
