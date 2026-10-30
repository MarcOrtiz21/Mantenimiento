import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var graphSection: some View {
        SectionPanel(title: "Gráficas", symbol: "chart.xyaxis.line") {
            HStack(spacing: 10) {
                Picker("Periodo", selection: $historyRange) {
                    ForEach(TelemetryHistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)

                if isLoadingHistory {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                Button {
                    exportPersistentHistory()
                } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                }
            }

            if historyRange == .live {
                liveCharts
            } else if historyRows.isEmpty && !isLoadingHistory {
                EmptyStateView(message: "Todavía no hay historial guardado en este periodo. Se graba una muestra cada 30 s mientras la app está abierta.")
            } else {
                historyCharts
            }
        }
    }

    var historyCharts: some View {
        ResponsiveChartGrid(charts: [
            historyChart("CPU total", symbol: "cpu", column: "cpu_percent", unit: "%"),
            historyChart("GPU", symbol: "square.stack.3d.up.fill", column: "gpu_percent", unit: "%"),
            historyChart("Temperatura max", symbol: "thermometer.medium", column: "max_temperature_c", unit: "C"),
            historyChart("Temperatura CPU", symbol: "thermometer.medium", column: "cpu_temperature_c", unit: "C"),
            historyChart("Temperatura GPU", symbol: "thermometer.medium", column: "gpu_temperature_c", unit: "C"),
            historyChart("RPM media", symbol: "fanblades", column: "average_rpm", unit: "RPM", decimals: 0),
            historyChart("Potencia sistema", symbol: "bolt", column: "system_power_w", unit: "W"),
            historyChart("Batería", symbol: "battery.75percent", column: "battery_percent", unit: "%", decimals: 0),
            historyChart("Carga/descarga", symbol: "bolt.batteryblock", column: "battery_power_w", unit: "W"),
            historyChart("Memoria usada", symbol: "memorychip", column: "ram_percent", unit: "%", decimals: 0),
            historyChart("Swap", symbol: "arrow.left.arrow.right.square", column: "swap_used_bytes", unit: "GB", transform: { $0 / 1_073_741_824 }),
            historyChart("Carga media 1 min", symbol: "gauge.with.dots.needle.33percent", column: "load_average_1m", unit: ""),
            historyRateChart("Red bajada", symbol: "arrow.down.circle", column: "network_down_bps"),
            historyRateChart("Red subida", symbol: "arrow.up.circle", column: "network_up_bps"),
            historyRateChart("Disco lectura", symbol: "arrow.down.doc", column: "disk_read_bps"),
            historyRateChart("Disco escritura", symbol: "arrow.up.doc", column: "disk_write_bps")
        ])
    }

    func historyChart(
        _ title: String,
        symbol: String,
        column: String,
        unit: String,
        decimals: Int = 1,
        transform: @escaping (Double) -> Double = { $0 }
    ) -> SparklineChartView {
        let data = TelemetryChartSeries.history(historyRows, column: column, range: historyRange, transform: transform)
        let values = data.points.map(\.value)
        let format = "%.\(decimals)f"
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return SparklineChartView(
            title: title,
            value: average.map { String(format: format, $0) } ?? "sin datos",
            unit: unit,
            symbol: symbol,
            points: data,
            footnote: values.max().map { "media · máx \(String(format: format, $0)) \(unit)" }
        )
    }

    func historyRateChart(_ title: String, symbol: String, column: String) -> SparklineChartView {
        let data = TelemetryChartSeries.history(historyRows, column: column, range: historyRange)
        let values = data.points.map(\.value)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return SparklineChartView(
            title: title,
            value: average.map(formatRateValue) ?? "sin datos",
            unit: average.map(rateUnit) ?? "",
            symbol: symbol,
            points: data,
            footnote: values.max().map { "media · máx \(formatRate($0))" }
        )
    }

    var liveCharts: some View {
            ResponsiveChartGrid(charts: [
                SparklineChartView(
                    title: "CPU total",
                    value: history.latestCPUUsage.map(formatPercent) ?? "sin datos",
                    unit: "",
                    symbol: "cpu",
                    points: history.cpuPoints
                ),
                SparklineChartView(
                    title: "GPU",
                    value: history.latestGPUUsage.map(formatPercent) ?? "sin datos",
                    unit: "",
                    symbol: "square.stack.3d.up.fill",
                    points: history.gpuPoints
                ),
                SparklineChartView(
                    title: "Temperatura max",
                    value: history.latestMaxTemperature.map(formatTemperatureValue) ?? "sin datos",
                    unit: "C",
                    symbol: "thermometer.medium",
                    points: history.temperaturePoints
                ),
                SparklineChartView(
                    title: "Temperatura GPU",
                    value: history.latestGPUTemperature.map(formatTemperatureValue) ?? "sin datos",
                    unit: "C",
                    symbol: "thermometer.medium",
                    points: history.gpuTemperaturePoints
                ),
                SparklineChartView(
                    title: "RPM media",
                    value: history.latestAverageRPM.map { "\(Int($0.rounded()))" } ?? "sin datos",
                    unit: "RPM",
                    symbol: "fanblades",
                    points: history.rpmPoints
                ),
                SparklineChartView(
                    title: "Potencia sistema",
                    value: history.latestSystemPower.map { String(format: "%.1f", $0) } ?? "sin datos",
                    unit: "W",
                    symbol: "bolt",
                    points: history.powerPoints
                ),
                SparklineChartView(
                    title: "Memoria usada",
                    value: history.latestMemoryRatio.map(formatPercent) ?? "sin datos",
                    unit: "",
                    symbol: "memorychip",
                    points: history.memoryPoints
                ),
                SparklineChartView(
                    title: "Red bajada",
                    value: history.latestNetworkDownBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestNetworkDownBps.map(rateUnit) ?? "",
                    symbol: "arrow.down.circle",
                    points: history.networkDownPoints
                ),
                SparklineChartView(
                    title: "Red subida",
                    value: history.latestNetworkUpBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestNetworkUpBps.map(rateUnit) ?? "",
                    symbol: "arrow.up.circle",
                    points: history.networkUpPoints
                ),
                SparklineChartView(
                    title: "Disco lectura",
                    value: history.latestDiskReadBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestDiskReadBps.map(rateUnit) ?? "",
                    symbol: "arrow.down.doc",
                    points: history.diskReadPoints
                ),
                SparklineChartView(
                    title: "Disco escritura",
                    value: history.latestDiskWriteBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestDiskWriteBps.map(rateUnit) ?? "",
                    symbol: "arrow.up.doc",
                    points: history.diskWritePoints
                )
            ])
    }
}
