import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var macTelemetrySection: some View {
        SectionPanel(title: "Mac", symbol: DashboardSection.mac.symbol(battery: snapshot.telemetry.battery)) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: NSImage.computerName) ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 3) {
                    Text(hardwareDetails?.modelName ?? snapshot.system.model)
                        .font(.system(size: 18, weight: .semibold))
                    Text([hardwareDetails?.chip ?? snapshot.system.processor, hardwareDetails?.memory].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text([osDetails.version, osDetails.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "CPU",
                    value: history.latestCPUUsage.map(formatPercent) ?? "calculando",
                    symbol: "cpu",
                    tint: .accentColor
                )
                MetricView(
                    title: "RAM usada",
                    value: "\(formatBytes(snapshot.telemetry.memory.usedBytes)) / \(formatBytes(snapshot.telemetry.memory.totalBytes))",
                    symbol: "memorychip",
                    tint: .accentColor
                )
                MetricView(
                    title: "Presión RAM",
                    value: snapshot.telemetry.memory.pressureDescription,
                    symbol: "gauge.with.dots.needle.33percent",
                    tint: .secondary
                )
                MetricView(
                    title: "Swap",
                    value: formatBytes(snapshot.telemetry.swap.usedBytes),
                    symbol: "arrow.left.arrow.right.square",
                    tint: .secondary
                )
                MetricView(
                    title: "Disco libre",
                    value: formatBytes(snapshot.telemetry.disk.availableBytes),
                    symbol: "internaldrive",
                    tint: .secondary
                )
                MetricView(
                    title: "Red bajada",
                    value: history.latestNetworkDownBps.map(formatRate) ?? "0 B/s",
                    symbol: "arrow.down.circle",
                    tint: .accentColor
                )
                MetricView(
                    title: "Red subida",
                    value: history.latestNetworkUpBps.map(formatRate) ?? "0 B/s",
                    symbol: "arrow.up.circle",
                    tint: .accentColor
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                InfoRow(title: "Disco", value: "\(snapshot.telemetry.disk.volumeName): \(formatPercent(snapshot.telemetry.disk.usedRatio)) usado")

                if let battery = snapshot.telemetry.battery {
                    InfoRow(title: "Batería", value: batterySummary(battery))
                } else {
                    InfoRow(title: "Batería", value: "sin batería detectada")
                }

                InfoRow(title: "Red", value: networkSummary(snapshot.telemetry.network))
            }
        }
    }

    var coreCountDescription: String {
        let cpu = snapshot.telemetry.cpu
        if let performance = cpu.performanceCoreCount, let efficiency = cpu.efficiencyCoreCount {
            return "\(cpu.coreCount) (\(performance)P + \(efficiency)E)"
        }
        return "\(cpu.coreCount)"
    }

    var loadAverageTint: Color {
        let cpu = snapshot.telemetry.cpu
        guard let load = cpu.loadAverage.first, cpu.coreCount > 0 else { return .secondary }
        let ratio = load / Double(cpu.coreCount)
        return ratio >= 1.5 ? .red : ratio >= 1 ? .orange : .secondary
    }

    var cpuSection: some View {
        let cpu = snapshot.telemetry.cpu
        return SectionPanel(title: "CPU", symbol: "cpu") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Uso total",
                    value: history.latestCPUUsage.map(formatPercent) ?? "calculando",
                    symbol: "cpu",
                    tint: .accentColor
                )
                MetricView(
                    title: "Usuario / sistema",
                    value: history.latest?.cpuUserRatio.flatMap { user in
                        history.latest?.cpuSystemRatio.map { "\(formatPercent(user)) / \(formatPercent($0))" }
                    } ?? "calculando",
                    symbol: "person.2",
                    tint: .secondary
                )
                MetricView(
                    title: "Carga media 1 / 5 / 15 min",
                    value: cpu.loadAverage.count == 3
                        ? cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " / ")
                        : "sin datos",
                    symbol: "gauge.with.dots.needle.33percent",
                    tint: loadAverageTint
                )
                MetricView(
                    title: "Núcleos",
                    value: coreCountDescription,
                    symbol: "circle.grid.3x3",
                    tint: .secondary
                )
                MetricView(
                    title: "Procesos",
                    value: cpu.processCount.map(String.init) ?? "sin datos",
                    symbol: "list.number",
                    tint: .secondary
                )
                MetricView(
                    title: "Temperatura CPU",
                    value: snapshot.sensors?.readings(type: .temperature, group: .cpu).map(\.value).max().map(formatTemperature) ?? "sin datos",
                    symbol: "thermometer.medium",
                    tint: temperatureTint(snapshot.sensors?.readings(type: .temperature, group: .cpu).map { Double($0.value) }.max())
                )
            }

            Text("La carga media cuenta procesos listos para ejecutarse; por encima de \(cpu.coreCount) el Mac tiene más trabajo que núcleos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if history.latestCoreUsages.isEmpty {
                EmptyStateView(message: "Calculando uso por núcleo...")
            } else {
                CPUCoreUsageGridView(usages: history.latestCoreUsages, cpu: cpu)
            }
        }
    }

    var gpuSection: some View {
        SectionPanel(title: "GPU", symbol: "square.stack.3d.up.fill") {
            let gpu = snapshot.telemetry.gpu
            let gpuTemperatures = snapshot.sensors?.readings(type: .temperature, group: .gpu).sortedBySensorNumber() ?? []
            let gpuPower = snapshot.sensors?.readings(type: .power, group: .gpu).first
            let gpuVoltage = snapshot.sensors?.readings(type: .voltage, group: .gpu).first

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Uso GPU",
                    value: history.latestGPUUsage.map(formatPercent) ?? "sin datos",
                    symbol: "square.stack.3d.up.fill",
                    tint: .accentColor
                )
                MetricView(
                    title: "Renderer",
                    value: gpu?.rendererUtilizationPercent.map { "\(Int($0.rounded()))%" } ?? "sin datos",
                    symbol: "rectangle.3.group",
                    tint: .secondary
                )
                MetricView(
                    title: "Tiler",
                    value: gpu?.tilerUtilizationPercent.map { "\(Int($0.rounded()))%" } ?? "sin datos",
                    symbol: "square.grid.3x3",
                    tint: .secondary
                )
                MetricView(
                    title: "Temperatura",
                    value: history.latestGPUTemperature.map(formatTemperature) ?? "sin datos",
                    symbol: "thermometer.medium",
                    tint: temperatureTint(history.latestGPUTemperature)
                )
                MetricView(
                    title: "Memoria GPU",
                    value: gpu?.inUseMemoryBytes.map(formatBytes) ?? "sin datos",
                    symbol: "memorychip",
                    tint: .secondary
                )
                MetricView(
                    title: "Potencia",
                    value: gpuPower.map { String(format: "%.1f W", $0.value) } ?? "sin datos",
                    symbol: "bolt",
                    tint: .secondary
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                InfoRow(title: "Modelo", value: gpu?.model ?? "sin lectura fiable")
                InfoRow(title: "Núcleos", value: gpu?.coreCount.map(String.init) ?? "sin datos")
                InfoRow(title: "Memoria asignada", value: gpu?.allocatedMemoryBytes.map(formatBytes) ?? "sin datos")
                InfoRow(title: "Voltaje", value: gpuVoltage.map { String(format: "%.2f V", $0.value) } ?? "sin datos")
            }

            if gpuTemperatures.isEmpty {
                EmptyStateView(message: snapshot.sensorError ?? "Sin sensores de temperatura GPU disponibles.")
            } else {
                SensorGroupView(
                    title: "Temperaturas GPU",
                    readings: gpuTemperatures,
                    formatter: formatTemperature,
                    ceiling: 110
                )
            }

            GPUDemandListView(entries: gpuDemandEntries, isRefreshing: isRefreshingGPUDemand)
        }
    }

    var memorySection: some View {
        SectionPanel(title: "Memoria", symbol: "memorychip") {
            let memory = snapshot.telemetry.memory
            let memoryTemperatures = snapshot.sensors?.readings(type: .temperature, group: .memory).sortedBySensorNumber() ?? []

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Usada",
                    value: "\(formatBytes(memory.usedBytes)) / \(formatBytes(memory.totalBytes))",
                    symbol: "memorychip",
                    tint: memoryPressureTint(memory.pressureLevel)
                )
                MetricView(
                    title: "Presión",
                    value: memory.pressureDescription,
                    symbol: "gauge.with.dots.needle.33percent",
                    tint: memoryPressureTint(memory.pressureLevel)
                )
                MetricView(
                    title: "Apps",
                    value: formatBytes(memory.appBytes),
                    symbol: "app.connected.to.app.below.fill",
                    tint: .accentColor
                )
                MetricView(
                    title: "Cableada",
                    value: formatBytes(memory.wiredBytes),
                    symbol: "lock",
                    tint: .secondary
                )
                MetricView(
                    title: "Comprimida",
                    value: formatBytes(memory.compressedBytes),
                    symbol: "archivebox",
                    tint: .secondary
                )
                MetricView(
                    title: "Cache",
                    value: formatBytes(memory.cachedFilesBytes),
                    symbol: "tray.full",
                    tint: .secondary
                )
                MetricView(
                    title: "Libre",
                    value: formatBytes(memory.freeBytes),
                    symbol: "circle.dotted",
                    tint: .secondary
                )
                MetricView(
                    title: "Swap",
                    value: formatBytes(snapshot.telemetry.swap.usedBytes),
                    symbol: "arrow.left.arrow.right.square",
                    tint: snapshot.telemetry.swap.usedBytes > 0 ? .orange : .secondary
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                InfoRow(title: "Porcentaje", value: formatPercent(memory.usedRatio))
                InfoRow(title: "Total", value: formatBytes(memory.totalBytes))
                InfoRow(title: "Swap total", value: formatBytes(snapshot.telemetry.swap.totalBytes))
                InfoRow(
                    title: "Compresión",
                    value: memory.compressionRatio.map {
                        String(format: "%.1f : 1 (%@ guardados en %@)", $0, formatBytes(memory.uncompressedInCompressorBytes), formatBytes(memory.compressedBytes))
                    } ?? "sin memoria comprimida"
                )
                InfoRow(
                    title: "Paginación",
                    value: "entrada \(history.latest?.pageInBps.map(formatRate) ?? "--") · salida \(history.latest?.pageOutBps.map(formatRate) ?? "--")"
                )
                InfoRow(
                    title: "Swap activo",
                    value: "entrada \(history.latest?.swapInBps.map(formatRate) ?? "--") · salida \(history.latest?.swapOutBps.map(formatRate) ?? "--")"
                )
                Text("Si el swap de salida sube de forma sostenida, la RAM se queda corta para lo que tienes abierto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !memoryTemperatures.isEmpty {
                SensorGroupView(
                    title: "Temperaturas memoria",
                    readings: memoryTemperatures,
                    formatter: formatTemperature,
                    ceiling: 110
                )
            }
        }
    }
}
