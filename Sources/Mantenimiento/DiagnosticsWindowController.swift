import AppKit
import Charts
import MantenimientoCore
import SwiftUI
import UniformTypeIdentifiers

final class DiagnosticsWindowController: NSWindowController {
    init() {
        let viewController = NSHostingController(rootView: DiagnosticsRootView())
        let window = NSWindow(contentViewController: viewController)
        window.title = "Mantenimiento"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 860, height: 660))
        window.minSize = NSSize(width: 680, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameUsingName("Mantenimiento.Diagnostics")
        window.setFrameAutosaveName("Mantenimiento.Diagnostics")

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct DiagnosticsRootView: View {
    @State private var snapshot = DashboardSnapshot.placeholder()
    @State private var statusMessage = "Listo"
    @State private var isWorking = false
    @State private var isRefreshing = false
    @State private var accessibilityTrusted = InputBlocker.isAccessibilityTrusted(prompt: false)
    @State private var inputMonitoringTrusted = InputBlocker.isInputMonitoringTrusted(prompt: false)
    @State private var history = TelemetryHistory()
    @State private var selectedSection: DashboardSection = .overview
    @State private var refreshSequence = 0
    @State private var gpuDemandEntries: [GPUProcessDemandEntry] = []
    @State private var isRefreshingGPUDemand = false
    @State private var topCPUDemand: MenuDemandEntry?
    @State private var isRefreshingTopDemand = false
    @State private var helperAvailable: Bool?
    @State private var helperStatusText = "Comprobando..."
    @State private var lastTelemetryDate: Date?
    @State private var historyRange: TelemetryHistoryRange = .live
    @State private var historyRows: [TelemetryHistoryRow] = []
    @State private var isLoadingHistory = false
    @State private var wifiDetails: WiFiDetails?
    @State private var routeDetails: NetworkRouteDetails?
    @State private var connectivity: ConnectivityDetails?
    @State private var storageDetails: [String: StorageDeviceDetails] = [:]
    @State private var hardwareDetails: HardwareDetails?
    @State private var securityDetails: SecurityDetails?
    @State private var osDetails = SystemDetailsProvider.shared.operatingSystemDetails()
    @State private var events: [MaintenanceEvent] = []
    @State private var lastLatencyCheck: Date?
    @State private var appNetworkUsage: [AppNetworkUsage] = []
    @State private var isSamplingAppNetwork = false

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(selection: $selectedSection, battery: snapshot.telemetry.battery)
                    .frame(width: 168)
                    .padding(.vertical, 16)
                    .padding(.leading, 12)
                    .padding(.trailing, 10)

                Divider()

                VStack(spacing: 12) {
                    header

                    ScrollView {
                        VStack(spacing: 14) {
                            if !snapshot.sensorStatus.isCurrent || !snapshot.fanStatus.isCurrent || !snapshot.telemetry.memory.isAvailable {
                                VStack(alignment: .leading, spacing: 6) {
                                    if !snapshot.sensorStatus.isCurrent {
                                        HealthStatusRow(title: "Sensores", value: snapshot.sensorStatus.description, isHealthy: false)
                                            .help(snapshot.sensorStatus.error ?? "")
                                    }
                                    if !snapshot.fanStatus.isCurrent {
                                        HealthStatusRow(title: "Ventiladores", value: snapshot.fanStatus.description, isHealthy: false)
                                            .help(snapshot.fanStatus.error ?? "")
                                    }
                                    if !snapshot.telemetry.memory.isAvailable {
                                        HealthStatusRow(title: "Memoria", value: "Sin lectura fiable", isHealthy: false)
                                    }
                                }
                            }
                            selectedContent
                        }
                        .padding(.bottom, 10)
                    }
                    .scrollIndicators(.visible)

                    footer
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            refreshPermissionState()
            if history.samples.isEmpty {
                if let shared = TelemetryStore.shared.latest {
                    applySnapshot(DashboardSnapshot.make(shared: shared))
                } else {
                    reloadSnapshot(status: nil, includeSMC: true, fullTelemetry: true)
                }
            }
            refreshTopCPUDemand(force: true)
            refreshHealthStatus()
            refreshSectionDetails(selectedSection, force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .telemetryUpdated)) { notification in
            guard isDiagnosticsWindowVisible,
                  let shared = notification.object as? SharedTelemetrySnapshot else { return }
            applySnapshot(DashboardSnapshot.make(shared: shared))
            refreshSequence += 1
            if refreshSequence.isMultiple(of: 3) {
                refreshGPUDemand()
                refreshTopCPUDemand()
                refreshSectionDetails(selectedSection)
            }
            if selectedSection == .cleaning || selectedSection == .system {
                refreshPermissionState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maintenanceEventLogged)) { _ in
            if selectedSection == .activity {
                refreshEvents()
            }
        }
        .onChange(of: historyRange) { _ in
            loadHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.title == "Mantenimiento" else { return }
            if let shared = TelemetryStore.shared.latest {
                applySnapshot(DashboardSnapshot.make(shared: shared))
            }
            refresh()
        }
        .onChange(of: selectedSection) { section in
            if section == .gpu {
                refreshGPUDemand(force: true)
            }
            if section == .overview {
                refreshTopCPUDemand(force: true)
            }
            if section == .cleaning {
                refreshPermissionState()
            }
            if section == .system {
                refreshHealthStatus()
            }
            refreshSectionDetails(section, force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .diagnosticsSectionRequested)) { notification in
            guard let rawValue = notification.userInfo?["section"] as? String,
                  let section = DashboardSection(rawValue: rawValue) else {
                return
            }
            selectedSection = section
            if section == .gpu {
                refreshGPUDemand(force: true)
            }
            if section == .overview {
                refreshTopCPUDemand(force: true)
            }
            if section == .system {
                refreshHealthStatus()
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedSection {
        case .overview:
            overview
        case .graphs:
            graphSection
        case .mac:
            macTelemetrySection
        case .cpu:
            cpuSection
        case .gpu:
            gpuSection
        case .memory:
            if snapshot.telemetry.memory.isAvailable { memorySection }
            else { EmptyStateView(message: "No hay una lectura de memoria fiable.") }
        case .network:
            networkSection
        case .storage:
            storageSection
        case .cleaning:
            cleanSection
        case .fans:
            fanSection
        case .temperatures:
            temperatureSection
        case .energy:
            powerSection
        case .activity:
            activitySection
        case .system:
            systemSection
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppMark(size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("Mantenimiento")
                    .font(.system(size: 24, weight: .semibold))
                Text(snapshot.system.processor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Actualizar")
            .disabled(isWorking || isRefreshing)
        }
    }

    private var overview: some View {
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

    private var maintenanceReviewItems: [MaintenanceReviewItem] {
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

    private var graphSection: some View {
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

    private var historyCharts: some View {
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

    private func historyChart(
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

    private func historyRateChart(_ title: String, symbol: String, column: String) -> SparklineChartView {
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

    private var liveCharts: some View {
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

    private var macTelemetrySection: some View {
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

    private var coreCountDescription: String {
        let cpu = snapshot.telemetry.cpu
        if let performance = cpu.performanceCoreCount, let efficiency = cpu.efficiencyCoreCount {
            return "\(cpu.coreCount) (\(performance)P + \(efficiency)E)"
        }
        return "\(cpu.coreCount)"
    }

    private var loadAverageTint: Color {
        let cpu = snapshot.telemetry.cpu
        guard let load = cpu.loadAverage.first, cpu.coreCount > 0 else { return .secondary }
        let ratio = load / Double(cpu.coreCount)
        return ratio >= 1.5 ? .red : ratio >= 1 ? .orange : .secondary
    }

    private var cpuSection: some View {
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

    private var gpuSection: some View {
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

    private var memorySection: some View {
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

    private var networkSection: some View {
        let network = snapshot.telemetry.network
        let primaryName = routeDetails?.primaryInterface
        let primary = network.interfaces.first { $0.name == primaryName }

        return VStack(spacing: 14) {
            SectionPanel(title: "Conexión", symbol: connectivity?.isConnected == false ? "wifi.slash" : "network") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricView(
                        title: "Estado",
                        value: connectivity.map { $0.isConnected ? "Conectado" : "Sin conexión" } ?? "Comprobando",
                        symbol: connectivity?.isConnected == false ? "xmark.circle" : "checkmark.circle",
                        tint: connectivity?.isConnected == false ? .red : .green
                    )
                    MetricView(
                        title: "Latencia a Internet",
                        value: connectivity?.latencyMilliseconds.map { String(format: "%.0f ms", $0) }
                            ?? (connectivity?.checkedAt == nil ? "midiendo" : "sin respuesta"),
                        symbol: "timer",
                        tint: latencyTint(connectivity?.latencyMilliseconds)
                    )
                    MetricView(
                        title: "Bajada",
                        value: history.latestNetworkDownBps.map(formatRate) ?? "0 B/s",
                        symbol: "arrow.down.circle",
                        tint: .accentColor
                    )
                    MetricView(
                        title: "Subida",
                        value: history.latestNetworkUpBps.map(formatRate) ?? "0 B/s",
                        symbol: "arrow.up.circle",
                        tint: .accentColor
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "Interfaz principal", value: primary.map { "\($0.displayName) (\($0.name))" } ?? primaryName ?? "ninguna")
                    InfoRow(title: "IP local", value: primary?.ipv4Addresses.first ?? "sin IPv4")
                    if let ipv6 = primary?.ipv6Addresses.first {
                        InfoRow(title: "IPv6", value: ipv6)
                    }
                    InfoRow(title: "Router", value: routeDetails?.router ?? "sin datos")
                    InfoRow(title: "DNS", value: routeDetails.map { $0.dnsServers.isEmpty ? "sin datos" : $0.dnsServers.prefix(3).joined(separator: ", ") } ?? "sin datos")
                    if connectivity?.isExpensive == true || connectivity?.isConstrained == true {
                        InfoRow(
                            title: "Tipo",
                            value: [connectivity?.isExpensive == true ? "datos móviles / compartida" : nil, connectivity?.isConstrained == true ? "modo datos reducidos" : nil]
                                .compactMap { $0 }.joined(separator: ", ")
                        )
                    }
                    InfoRow(
                        title: "Desde arranque",
                        value: "↓ \(formatBytes(network.totalReceivedBytes)) · ↑ \(formatBytes(network.totalSentBytes))"
                    )
                }
            }

            SectionPanel(title: "Tráfico por aplicación", symbol: "app.connected.to.app.below.fill") {
                AppNetworkUsageList(usage: appNetworkUsage)
            }

            if let wifi = wifiDetails {
                wifiPanel(wifi)
            }

            SectionPanel(title: "Interfaces", symbol: "point.3.connected.trianglepath.dotted") {
                NetworkInterfaceDetailList(
                    interfaces: network.interfaces,
                    rates: history.latestNetworkInterfaceRates,
                    primaryName: primaryName
                )
            }
        }
    }

    private func wifiPanel(_ wifi: WiFiDetails) -> some View {
        SectionPanel(title: "Wi-Fi", symbol: wifi.isPoweredOn ? "wifi" : "wifi.slash") {
            if !wifi.isPoweredOn {
                EmptyStateView(message: "El Wi-Fi está apagado.")
            } else if wifi.rssi == nil && wifi.channel == nil {
                EmptyStateView(message: "El Wi-Fi está encendido pero no hay red asociada.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricView(
                        title: "Señal",
                        value: wifi.rssi.map { "\($0) dBm · \(wifi.signalQuality ?? "")" } ?? "sin datos",
                        symbol: wifiSignalSymbol(wifi.rssi),
                        tint: wifiSignalTint(wifi.rssi)
                    )
                    MetricView(
                        title: "Velocidad de enlace",
                        value: wifi.transmitRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "sin datos",
                        symbol: "speedometer",
                        tint: .accentColor
                    )
                    MetricView(
                        title: "Relación señal/ruido",
                        value: wifi.signalToNoise.map { "\($0) dB" } ?? "sin datos",
                        symbol: "waveform",
                        tint: (wifi.signalToNoise ?? 40) < 20 ? .orange : .secondary
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "Red", value: wifi.ssid ?? "nombre oculto (requiere permiso de Ubicación)")
                    InfoRow(
                        title: "Canal",
                        value: [wifi.channel.map(String.init), wifi.band, wifi.channelWidth].compactMap { $0 }.joined(separator: " · ")
                    )
                    InfoRow(title: "Estándar", value: wifi.standard ?? "sin datos")
                    InfoRow(title: "Seguridad", value: wifi.security ?? "sin datos")
                    InfoRow(title: "Ruido", value: wifi.noise.map { "\($0) dBm" } ?? "sin datos")
                }
            }
        }
    }

    private var storageSection: some View {
        let volumes = snapshot.telemetry.volumes
        let root = volumes.first(where: \.isRootVolume)
        let rootDetails = storageDetails[root?.path ?? "/"]
        let diskIO = snapshot.telemetry.diskIO

        return VStack(spacing: 14) {
            SectionPanel(title: "Disco de arranque", symbol: "internaldrive") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricView(
                        title: "Libre",
                        value: formatBytes(root?.availableBytes ?? snapshot.telemetry.disk.availableBytes),
                        symbol: "internaldrive",
                        tint: diskFreeTint(root)
                    )
                    MetricView(
                        title: "Usado",
                        value: formatPercent(root?.usedRatio ?? snapshot.telemetry.disk.usedRatio),
                        symbol: "chart.pie",
                        tint: .secondary
                    )
                    MetricView(
                        title: "Estado SMART",
                        value: rootDetails?.smartStatus.map(localizedSMARTStatus) ?? "comprobando",
                        symbol: rootDetails?.smartStatus == "Verified" ? "checkmark.shield" : "exclamationmark.shield",
                        tint: rootDetails?.smartStatus == nil ? .secondary : rootDetails?.smartStatus == "Verified" ? .green : .orange
                    )
                    MetricView(
                        title: "Cifrado",
                        value: rootDetails?.isEncrypted.map { $0 ? "FileVault activo" : "Sin cifrar" } ?? "comprobando",
                        symbol: rootDetails?.isEncrypted == false ? "lock.open" : "lock",
                        tint: rootDetails?.isEncrypted == false ? .orange : .secondary
                    )
                }

                if let root {
                    VolumeUsageBar(volume: root)
                }

                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(title: "Volumen", value: root?.name ?? snapshot.telemetry.disk.volumeName)
                    InfoRow(title: "Modelo", value: rootDetails?.mediaName ?? "sin datos")
                    InfoRow(
                        title: "Conexión",
                        value: [rootDetails?.busProtocol, rootDetails?.isSolidState == true ? "SSD" : nil].compactMap { $0 }.joined(separator: " · ")
                    )
                    InfoRow(
                        title: "Sistema de archivos",
                        value: [rootDetails?.fileSystem, root?.format].compactMap { $0 }.first ?? "sin datos"
                    )
                    if let physical = rootDetails?.physicalSizeBytes {
                        InfoRow(title: "Tamaño físico", value: formatBytes(physical))
                    }
                    InfoRow(
                        title: "Capacidad",
                        value: "\(formatBytes(root?.usedBytes ?? snapshot.telemetry.disk.usedBytes)) usados de \(formatBytes(root?.totalBytes ?? snapshot.telemetry.disk.totalBytes))"
                    )
                }
            }

            SectionPanel(title: "Actividad del disco", symbol: "arrow.up.arrow.down") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    MetricView(
                        title: "Lectura",
                        value: history.latestDiskReadBps.map(formatRate) ?? "0 B/s",
                        symbol: "arrow.down.doc",
                        tint: .accentColor
                    )
                    MetricView(
                        title: "Escritura",
                        value: history.latestDiskWriteBps.map(formatRate) ?? "0 B/s",
                        symbol: "arrow.up.doc",
                        tint: .accentColor
                    )
                    MetricView(
                        title: "Operaciones/s",
                        value: snapshot.diskReadOpsPerSecond.flatMap { reads in
                            snapshot.diskWriteOpsPerSecond.map { "\(Int(reads.rounded())) L · \(Int($0.rounded())) E" }
                        } ?? "calculando",
                        symbol: "speedometer",
                        tint: .secondary
                    )
                }
                InfoRow(
                    title: "Desde arranque",
                    value: "leídos \(formatBytes(diskIO.readBytes)) · escritos \(formatBytes(diskIO.writtenBytes))"
                )
            }

            SectionPanel(title: "Volúmenes", symbol: "externaldrive") {
                if volumes.isEmpty {
                    EmptyStateView(message: "Calculando volúmenes...")
                } else {
                    ForEach(volumes) { volume in
                        VolumeRowView(volume: volume, details: storageDetails[volume.path]) {
                            ejectVolume(volume)
                        }
                    }
                }
            }
        }
    }

    private func diskFreeTint(_ volume: VolumeSnapshot?) -> Color {
        guard let volume, volume.totalBytes > 0 else { return .secondary }
        let free = 1 - volume.usedRatio
        return free < 0.05 ? .red : free < 0.12 ? .orange : .secondary
    }

    private func ejectVolume(_ volume: VolumeSnapshot) {
        statusMessage = "Expulsando \(volume.name)..."
        let url = URL(fileURLWithPath: volume.path)
        Task.detached(priority: .userInitiated) {
            let result: String
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                result = "\(volume.name) expulsado."
            } catch {
                result = "No se pudo expulsar \(volume.name): \(error.localizedDescription)"
            }
            await MainActor.run {
                statusMessage = result
                reloadSnapshot(status: nil, includeSMC: false, fullTelemetry: true, force: true)
            }
        }
    }

    private var cleanSection: some View {
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

    private var fanSection: some View {
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

    private var temperatureSection: some View {
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

    private var powerSection: some View {
        let power = snapshot.sensors?.readings(type: .power) ?? []

        return VStack(spacing: 14) {
            if let battery = snapshot.telemetry.battery {
                batteryPanel(battery)
                powerFlowPanel(battery)
            }

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
    }

    private func batteryPanel(_ battery: BatterySnapshot) -> some View {
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

    private func powerFlowPanel(_ battery: BatterySnapshot) -> some View {
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

    private func batteryHeadline(_ battery: BatterySnapshot) -> String {
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

    private var activitySection: some View {
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

    private var systemSection: some View {
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

    private func securityValue(_ enabled: Bool?) -> String {
        switch enabled {
        case true?: return "Activado"
        case false?: return "Desactivado"
        case nil: return "Sin datos"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
    }

    private var isDiagnosticsWindowVisible: Bool {
        NSApp.windows.contains { window in
            window.title == "Mantenimiento" && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    private func refresh() {
        reloadSnapshot(
            status: "Actualizado \(Date.now.formatted(date: .omitted, time: .shortened))",
            includeSMC: true,
            fullTelemetry: true,
            force: true
        )
    }

    private func applySnapshot(_ nextSnapshot: DashboardSnapshot) {
        guard lastTelemetryDate.map({ nextSnapshot.date > $0 }) ?? true else { return }
        snapshot = nextSnapshot
        history.append(nextSnapshot)
        lastTelemetryDate = nextSnapshot.date
    }

    private func reloadSnapshot(status: String?, includeSMC: Bool, fullTelemetry: Bool, force: Bool = false) {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        let previousSnapshot = snapshot
        Task {
            let nextSnapshot = await Task.detached(priority: .utility) {
                DashboardSnapshot.load(
                    previous: previousSnapshot,
                    includeSMC: includeSMC,
                    fullTelemetry: fullTelemetry,
                    force: force
                )
            }.value

            await MainActor.run {
                applySnapshot(nextSnapshot)
                if let status {
                    statusMessage = status
                }
                isRefreshing = false
            }
        }
    }

    private func refreshTopCPUDemand(force: Bool = false) {
        guard !isRefreshingTopDemand else {
            return
        }
        guard force || selectedSection == .overview else {
            return
        }

        isRefreshingTopDemand = true
        Task {
            let entry = await Task.detached(priority: .utility) {
                ProcessDemandSampler.shared.cpuEntries().first
            }.value

            await MainActor.run {
                topCPUDemand = entry
                isRefreshingTopDemand = false
            }
        }
    }

    private func refreshGPUDemand(force: Bool = false) {
        guard !isRefreshingGPUDemand else {
            return
        }
        guard force || selectedSection == .gpu else {
            return
        }

        isRefreshingGPUDemand = true
        Task {
            let entries = await Task.detached(priority: .utility) {
                loadGPUProcessDemand()
            }.value

            await MainActor.run {
                gpuDemandEntries = entries
                isRefreshingGPUDemand = false
            }
        }
    }

    private func refreshPermissionState() {
        accessibilityTrusted = InputBlocker.isAccessibilityTrusted(prompt: false)
        inputMonitoringTrusted = InputBlocker.isInputMonitoringTrusted(prompt: false)
    }

    private func refreshHealthStatus() {
        Task.detached(priority: .utility) {
            let response = PrivilegedHelperInstaller.ping()
            let isAvailable = response == FanHelperProtocol.greeting
            await MainActor.run {
                helperAvailable = isAvailable
                helperStatusText = isAvailable ? "Activo v3" : response != nil ? "Actualización necesaria" : "No disponible"
            }
        }
    }

    private func refreshSectionDetails(_ section: DashboardSection, force: Bool = false) {
        let provider = SystemDetailsProvider.shared
        switch section {
        case .network:
            Task.detached(priority: .utility) {
                let wifi = provider.wifiDetails()
                let route = provider.routeDetails()
                let connectivity = provider.currentConnectivity()
                await MainActor.run {
                    wifiDetails = wifi
                    routeDetails = route
                    self.connectivity = connectivity
                }
            }
            if !isSamplingAppNetwork {
                isSamplingAppNetwork = true
                Task.detached(priority: .utility) {
                    let usage = ProcessDemandSampler.shared.appNetworkUsage()
                    await MainActor.run {
                        appNetworkUsage = usage
                        isSamplingAppNetwork = false
                    }
                }
            }
            if force || lastLatencyCheck.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
                lastLatencyCheck = Date()
                provider.measureLatency { result in
                    connectivity = result
                }
            }
        case .storage:
            let paths = snapshot.telemetry.volumes.map(\.path)
            let targets = paths.isEmpty ? ["/"] : paths
            Task.detached(priority: .utility) {
                var loaded: [String: StorageDeviceDetails] = [:]
                for path in targets {
                    loaded[path] = provider.storageDetails(forVolumeAt: path)
                }
                let details = loaded
                await MainActor.run {
                    storageDetails = details
                }
            }
        case .overview, .system:
            Task.detached(priority: .utility) {
                let security = provider.securityDetails()
                let hardware = section == .system ? provider.hardwareDetails() : nil
                await MainActor.run {
                    securityDetails = security
                    if let hardware { hardwareDetails = hardware }
                    osDetails = provider.operatingSystemDetails()
                }
            }
        case .mac:
            guard hardwareDetails == nil else { return }
            Task.detached(priority: .utility) {
                let hardware = provider.hardwareDetails()
                await MainActor.run { hardwareDetails = hardware }
            }
        case .activity:
            refreshEvents()
        case .graphs:
            if force { loadHistory() }
        default:
            break
        }
    }

    private func refreshEvents() {
        Task.detached(priority: .utility) {
            let loaded = EventLog.shared.events()
            await MainActor.run { events = loaded }
        }
    }

    private func loadHistory() {
        guard historyRange != .live else {
            historyRows = []
            return
        }
        isLoadingHistory = true
        let since = Date().addingTimeInterval(-historyRange.duration)
        Task.detached(priority: .utility) {
            let rows = TelemetryHistoryRecorder.shared.rows(since: since)
            await MainActor.run {
                historyRows = rows
                isLoadingHistory = false
            }
        }
    }

    private func requestAccessibilityPermission() {
        PrivacySettings.requestAccessibilityPrompt()
        refreshPermissionState()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    private func requestInputMonitoringPermission() {
        PrivacySettings.requestInputMonitoringPrompt()
        refreshPermissionState()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    private func requestCleanMode(duration: TimeInterval) {
        NotificationCenter.default.post(
            name: .cleanModeStartRequested,
            object: nil,
            userInfo: ["duration": duration]
        )
        refreshPermissionState()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    private func repairCleanPermissions() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento"
        resetTCC(service: "Accessibility", bundleIdentifier: bundleIdentifier)
        resetTCC(service: "ListenEvent", bundleIdentifier: bundleIdentifier)
        statusMessage = "Permisos de limpieza restablecidos. Actívalos de nuevo en Ajustes."
        requestAccessibilityPermission()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    private func resetTCC(service: String, bundleIdentifier: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        try? process.run()
        process.waitUntilExit()
    }

    private func refreshPermissionStateAfterSystemSettingsUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshPermissionState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            refreshPermissionState()
        }
    }

    private func copyDiagnosticSummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticSummary(), forType: .string)
        statusMessage = "Diagnóstico copiado al portapapeles."
    }

    private func exportPersistentHistory() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "mantenimiento-telemetria-\(Date.now.formatted(.iso8601.year().month().day())).csv"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try TelemetryHistoryRecorder.shared.export(to: destinationURL)
            statusMessage = "Historial exportado."
        } catch {
            statusMessage = "No se pudo exportar: \(error.localizedDescription)"
        }
    }

    private func exportDiagnosticSummary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "mantenimiento-diagnostico.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticSummary().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Diagnóstico exportado."
        } catch { statusMessage = "No se pudo exportar el diagnóstico." }
    }

    private func diagnosticSummary() -> String {
        var lines: [String] = [
            "Mantenimiento - diagnóstico rápido",
            "Versión: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "desarrollo")",
            "Fecha: \(Date.now.formatted(date: .numeric, time: .standard))",
            "Modelo: \(snapshot.system.model)",
            "Procesador: \(snapshot.system.processor)",
            "Estado térmico: \(snapshot.system.thermalState)",
            "Uptime: \(snapshot.system.uptime)",
            "CPU: \(history.latestCPUUsage.map(formatPercent) ?? "calculando")",
            "GPU: \(snapshot.telemetry.gpu?.utilizationRatio.map(formatPercent) ?? "sin datos")",
            "RAM: \(formatBytes(snapshot.telemetry.memory.usedBytes)) / \(formatBytes(snapshot.telemetry.memory.totalBytes)) (\(formatPercent(snapshot.telemetry.memory.usedRatio)))",
            "Presión RAM: \(snapshot.telemetry.memory.pressureDescription)",
            "Swap: \(formatBytes(snapshot.telemetry.swap.usedBytes))",
            "Temperatura máxima: \(snapshot.sensors?.hottestTemperature.map { formatTemperature($0.value) } ?? "sin datos")",
            "Ventiladores: \(snapshot.fans?.fans.map { "\($0.displayName) \(formatRPM($0.actualRPM))" }.joined(separator: ", ") ?? "sin datos")",
            "Red: bajada \(history.latestNetworkDownBps.map(formatRate) ?? "calculando"), subida \(history.latestNetworkUpBps.map(formatRate) ?? "calculando")",
            "Coste app: \(appResourceSummary(snapshot.appResources))"
        ]

        if let battery = snapshot.telemetry.battery {
            lines.append("Batería: \(batterySummary(battery))")
            if let condition = battery.condition {
                lines.append("Condición batería: \(localizedBatteryCondition(condition))")
            }
            if let adapter = battery.adapter {
                lines.append("Cargador: \(adapter.name ?? "conectado")\(adapter.watts.map { " (\($0) W)" } ?? "")")
            }
        }

        lines.append("macOS: \(osDetails.version)\(osDetails.build.map { " (\($0))" } ?? "")")
        if let root = snapshot.telemetry.volumes.first(where: \.isRootVolume) {
            lines.append("Disco: \(formatBytes(root.availableBytes)) libres de \(formatBytes(root.totalBytes))\(storageDetails[root.path]?.smartStatus.map { ", SMART \(localizedSMARTStatus($0))" } ?? "")")
        }
        if let wifi = wifiDetails, let rssi = wifi.rssi {
            lines.append("Wi-Fi: \(rssi) dBm\(wifi.transmitRateMbps.map { String(format: ", %.0f Mbps", $0) } ?? "")")
        }
        let review = maintenanceReviewItems.filter { $0.status >= .warning }
        if !review.isEmpty {
            lines.append("Revisión: " + review.map { "\($0.title): \($0.detail)" }.joined(separator: " | "))
        }

        return lines.joined(separator: "\n")
    }

    private func setFan(_ index: Int, _ rpm: Float) {
        runFanAction("Aplicando velocidad al ventilador \(index + 1)...") {
            _ = try await Task.detached { try PrivilegedFanTool.setFanRPM(index: index, rpm: rpm) }.value
            NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
            return "Ventilador \(index + 1) en manual."
        }
    }

    private func setFanAuto(_ index: Int) {
        runFanAction("Aplicando automático al ventilador \(index + 1)...") {
            _ = try await Task.detached { try PrivilegedFanTool.setFanAuto(index: index) }.value
            return "Ventilador \(index + 1) en automático."
        }
    }

    private func setAllFansAuto() {
        runFanAction("Aplicando automático a los ventiladores...") {
            _ = try await Task.detached { try PrivilegedFanTool.setAllFansAuto() }.value
            NotificationCenter.default.post(name: .fanAutomaticControlDidSucceed, object: nil)
            return "Ventiladores en automático."
        }
    }

    private func setAllFansTurbo() {
        runFanAction("Activando turbo en todos los ventiladores...") {
            _ = try await Task.detached { try PrivilegedFanTool.setAllFansTurbo() }.value
            NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
            return "Turbo activo: ventiladores al máximo."
        }
    }

    private func runFanAction(_ pendingMessage: String, operation: @escaping () async throws -> String) {
        guard !isWorking else {
            return
        }

        statusMessage = pendingMessage
        isWorking = true

        Task {
            let message: String
            do {
                message = try await operation()
                EventLog.shared.record(.fans, title: message)
            } catch {
                message = error.localizedDescription
            }

            TelemetryStore.shared.invalidateSMC()
            let nextSnapshot = await Task.detached(priority: .utility) {
                DashboardSnapshot.load(force: true)
            }.value

            await MainActor.run {
                statusMessage = message
                isWorking = false
                applySnapshot(nextSnapshot)
            }
        }
    }
}

private struct DashboardSnapshot {
    let date: Date
    let samplingEpoch: UInt64
    let diskDate: Date
    let diskReadBps: Double?
    let diskWriteBps: Double?
    let fanStatus: TelemetryReadingStatus
    let sensorStatus: TelemetryReadingStatus
    let system: SystemSnapshot
    let fans: FanSnapshot?
    let sensors: SensorSnapshot?
    let telemetry: SystemTelemetrySnapshot
    let appResources: AppResourceSnapshot
    let fanError: String?
    let sensorError: String?
    var diskReadOpsPerSecond: Double?
    var diskWriteOpsPerSecond: Double?

    static func placeholder() -> DashboardSnapshot {
        DashboardSnapshot(
            date: .distantPast,
            samplingEpoch: 0,
            diskDate: .distantPast,
            diskReadBps: nil,
            diskWriteBps: nil,
            fanStatus: TelemetryReadingStatus(lastSuccess: nil, error: nil, referenceDate: .now),
            sensorStatus: TelemetryReadingStatus(lastSuccess: nil, error: nil, referenceDate: .now),
            system: SystemSnapshot(
                model: "Mac",
                processor: "Cargando telemetría...",
                thermalState: "nominal",
                lowPowerMode: "desconocido",
                uptime: "--",
                thermalTint: .secondary
            ),
            fans: nil,
            sensors: nil,
            telemetry: SystemTelemetryService.placeholderSnapshot(),
            appResources: AppResourceSnapshot(date: .now, cpuRatio: nil, residentMemoryBytes: 0),
            fanError: nil,
            sensorError: nil
        )
    }

    static func load(
        previous: DashboardSnapshot? = nil,
        includeSMC: Bool = true,
        fullTelemetry: Bool = true,
        force: Bool = false
    ) -> DashboardSnapshot {
        let shared = TelemetryStore.shared.snapshot(
            previousTelemetry: previous?.telemetry,
            includeSMC: includeSMC,
            fullTelemetry: fullTelemetry,
            force: force
        )

        return make(shared: shared)
    }

    static func make(shared: SharedTelemetrySnapshot) -> DashboardSnapshot {
        DashboardSnapshot(
            date: shared.date,
            samplingEpoch: shared.samplingEpoch,
            diskDate: shared.diskDate,
            diskReadBps: shared.diskReadBps,
            diskWriteBps: shared.diskWriteBps,
            fanStatus: shared.fanStatus,
            sensorStatus: shared.sensorStatus,
            system: .current(),
            fans: shared.fanStatus.isCurrent ? shared.fans : nil,
            sensors: shared.sensorStatus.isCurrent ? shared.sensors : nil,
            telemetry: shared.telemetry,
            appResources: shared.appResources,
            fanError: shared.fanError,
            sensorError: shared.sensorError,
            diskReadOpsPerSecond: shared.diskReadOpsPerSecond,
            diskWriteOpsPerSecond: shared.diskWriteOpsPerSecond
        )
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case graphs
    case mac
    case cpu
    case gpu
    case memory
    case network
    case storage
    case cleaning
    case fans
    case temperatures
    case energy
    case activity
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Resumen"
        case .graphs:
            return "Gráficas"
        case .mac:
            return "Mac"
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .memory:
            return "Memoria"
        case .network:
            return "Red"
        case .storage:
            return "Disco"
        case .cleaning:
            return "Limpieza"
        case .fans:
            return "Ventiladores"
        case .temperatures:
            return "Temperaturas"
        case .energy:
            return "Energía"
        case .activity:
            return "Actividad"
        case .system:
            return "Sistema"
        }
    }

    var symbol: String {
        switch self {
        case .overview:
            return "gauge"
        case .graphs:
            return "chart.xyaxis.line"
        case .mac:
            return "desktopcomputer"
        case .cpu:
            return "cpu"
        case .gpu:
            return "square.stack.3d.up.fill"
        case .memory:
            return "memorychip"
        case .network:
            return "network"
        case .storage:
            return "internaldrive"
        case .cleaning:
            return "keyboard"
        case .fans:
            return "fanblades"
        case .temperatures:
            return "thermometer.medium"
        case .energy:
            return "bolt"
        case .activity:
            return "clock.arrow.circlepath"
        case .system:
            return "gearshape.2"
        }
    }

    func symbol(battery: BatterySnapshot?) -> String {
        switch self {
        case .mac:
            return battery == nil ? "desktopcomputer" : "laptopcomputer"
        case .energy:
            return battery == nil ? symbol : batterySymbolName(battery)
        default:
            return symbol
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: DashboardSection
    let battery: BatterySnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(DashboardSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: 8) {
                            Label(section.title, systemImage: section.symbol(battery: battery))
                                .font(.callout)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .foregroundStyle(selection == section ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .background(
                        selection == section ? Color.accentColor.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct TelemetryHistory {
    private(set) var samples: [TelemetrySample] = []
    private let maxSampleCount = 80

    mutating func append(_ snapshot: DashboardSnapshot) {
        guard samples.last.map({ snapshot.date > $0.date }) ?? true else { return }
        samples.append(TelemetrySample(snapshot: snapshot, previous: samples.last))
        if samples.count > maxSampleCount {
            samples.removeFirst(samples.count - maxSampleCount)
        }
    }

    var temperaturePoints: TelemetryChartData {
        points(\.maxTemperature)
    }

    var cpuPoints: TelemetryChartData {
        points(\.cpuUsage)
    }

    var gpuPoints: TelemetryChartData {
        points(\.gpuUsage)
    }

    var gpuTemperaturePoints: TelemetryChartData {
        points(\.gpuTemperature)
    }

    var rpmPoints: TelemetryChartData {
        points(\.averageRPM)
    }

    var powerPoints: TelemetryChartData {
        points(\.systemPower)
    }

    var memoryPoints: TelemetryChartData {
        points(\.memoryUsedRatio)
    }

    var networkDownPoints: TelemetryChartData {
        points(\.networkDownBps)
    }

    var networkUpPoints: TelemetryChartData {
        points(\.networkUpBps)
    }

    var diskReadPoints: TelemetryChartData {
        points(\.diskReadBps, date: \.diskDate)
    }

    var diskWritePoints: TelemetryChartData {
        points(\.diskWriteBps, date: \.diskDate)
    }

    var batteryPowerPoints: TelemetryChartData {
        points(\.batteryPower)
    }

    var systemLoadPowerPoints: TelemetryChartData {
        points(\.systemLoadPower)
    }

    var latest: TelemetrySample? {
        samples.last
    }

    private func points(_ value: KeyPath<TelemetrySample, Double?>, date: KeyPath<TelemetrySample, Date> = \.date) -> TelemetryChartData {
        TelemetryChartSeries.make(samples.map { ($0[keyPath: date], $0[keyPath: value], $0.samplingEpoch) })
    }

    var latestMaxTemperature: Double? {
        samples.last?.maxTemperature
    }

    var latestCPUUsage: Double? {
        samples.last?.cpuUsage
    }

    var latestGPUUsage: Double? {
        samples.last?.gpuUsage
    }

    var latestGPUTemperature: Double? {
        samples.last?.gpuTemperature
    }

    var latestCoreUsages: [CPUCoreUsage] {
        samples.last?.coreUsages ?? []
    }

    var latestAverageRPM: Double? {
        samples.last?.averageRPM
    }

    var latestSystemPower: Double? {
        samples.last?.systemPower
    }

    var latestMemoryRatio: Double? {
        memoryPoints.points.last?.value
    }

    var latestNetworkDownBps: Double? {
        samples.last?.networkDownBps
    }

    var latestNetworkUpBps: Double? {
        samples.last?.networkUpBps
    }

    var latestNetworkInterfaceRates: [NetworkInterfaceRate] {
        samples.last?.networkInterfaceRates ?? []
    }

    var latestDiskReadBps: Double? {
        samples.last?.diskReadBps
    }

    var latestDiskWriteBps: Double? {
        samples.last?.diskWriteBps
    }
}

private struct TelemetrySample: Identifiable {
    let id = UUID()
    let date: Date
    let samplingEpoch: UInt64
    let diskDate: Date
    let maxTemperature: Double?
    let averageRPM: Double?
    let systemPower: Double?
    let memoryUsedRatio: Double?
    let gpuUsage: Double?
    let gpuTemperature: Double?
    let cpuCores: [CPUCoreSnapshot]
    let cpuUsage: Double?
    let coreUsages: [CPUCoreUsage]
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let diskReadBps: Double?
    let diskWriteBps: Double?
    let networkReceivedBytes: UInt64
    let networkSentBytes: UInt64
    let networkInterfaces: [NetworkInterfaceSnapshot]
    let networkDownBps: Double?
    let networkUpBps: Double?
    let networkInterfaceRates: [NetworkInterfaceRate]
    let memory: MemorySnapshot
    let cpuUserRatio: Double?
    let cpuSystemRatio: Double?
    let pageInBps: Double?
    let pageOutBps: Double?
    let swapInBps: Double?
    let swapOutBps: Double?
    let batteryPower: Double?
    let systemLoadPower: Double?
    let systemPowerIn: Double?

    init(snapshot: DashboardSnapshot, previous: TelemetrySample?) {
        memory = snapshot.telemetry.memory
        batteryPower = snapshot.telemetry.battery?.batteryPowerWatts
        systemLoadPower = snapshot.telemetry.battery?.systemLoadWatts
        systemPowerIn = snapshot.telemetry.battery?.systemPowerInWatts
        date = snapshot.date
        samplingEpoch = snapshot.samplingEpoch
        diskDate = snapshot.diskDate
        maxTemperature = snapshot.sensors?.hottestTemperature.map { Double($0.value) }

        if let fans = snapshot.fans?.fans, !fans.isEmpty {
            let total = fans.reduce(Double(0)) { $0 + Double(max($1.actualRPM, 0)) }
            averageRPM = total / Double(fans.count)
        } else {
            averageRPM = nil
        }

        systemPower = snapshot.sensors?.readings.first(where: { $0.sensor.key == "PSTR" }).map {
            Double($0.value)
        }
        memoryUsedRatio = snapshot.telemetry.memory.isAvailable ? snapshot.telemetry.memory.usedRatio : nil
        gpuUsage = snapshot.telemetry.gpu?.utilizationRatio
        gpuTemperature = snapshot.sensors?.readings(type: .temperature, group: .gpu).map { Double($0.value) }.max()
        cpuCores = snapshot.telemetry.cpu.cores
        diskReadBytes = snapshot.telemetry.diskIO.readBytes
        diskWrittenBytes = snapshot.telemetry.diskIO.writtenBytes
        networkReceivedBytes = snapshot.telemetry.network.totalReceivedBytes
        networkSentBytes = snapshot.telemetry.network.totalSentBytes
        networkInterfaces = snapshot.telemetry.network.interfaces

        if let previous, previous.samplingEpoch == samplingEpoch,
           TelemetryContinuity.isContinuous(from: previous.date, to: date) {
            let interval = max(date.timeIntervalSince(previous.date), 0.1)
            let cpu = computeCPUUsage(current: cpuCores, previous: previous.cpuCores)
            cpuUsage = cpu.total
            coreUsages = cpu.cores
            let split = computeCPUSplit(current: snapshot.telemetry.cpu, previous: previous.cpuCores)
            cpuUserRatio = split?.user
            cpuSystemRatio = split?.system
            let pageRate = { (current: UInt64, old: UInt64) -> Double? in
                current >= old ? Double(current - old) / interval : nil
            }
            let currentMemory = snapshot.telemetry.memory
            pageInBps = pageRate(currentMemory.pageInBytes, previous.memory.pageInBytes)
            pageOutBps = pageRate(currentMemory.pageOutBytes, previous.memory.pageOutBytes)
            swapInBps = pageRate(currentMemory.swapInBytes, previous.memory.swapInBytes)
            swapOutBps = pageRate(currentMemory.swapOutBytes, previous.memory.swapOutBytes)

            diskReadBps = snapshot.diskReadBps
            diskWriteBps = snapshot.diskWriteBps

            if networkReceivedBytes >= previous.networkReceivedBytes {
                networkDownBps = Double(networkReceivedBytes - previous.networkReceivedBytes) / interval
            } else {
                networkDownBps = nil
            }

            if networkSentBytes >= previous.networkSentBytes {
                networkUpBps = Double(networkSentBytes - previous.networkSentBytes) / interval
            } else {
                networkUpBps = nil
            }

            networkInterfaceRates = computeNetworkInterfaceRates(
                current: networkInterfaces,
                previous: previous.networkInterfaces,
                interval: interval
            )
        } else {
            cpuUsage = nil
            coreUsages = []
            cpuUserRatio = nil
            cpuSystemRatio = nil
            pageInBps = nil
            pageOutBps = nil
            swapInBps = nil
            swapOutBps = nil
            diskReadBps = snapshot.diskReadBps
            diskWriteBps = snapshot.diskWriteBps
            networkDownBps = nil
            networkUpBps = nil
            networkInterfaceRates = []
        }
    }
}

private struct CPUCoreUsage: Identifiable {
    let id: Int
    let index: Int
    let usage: Double
}

private struct NetworkInterfaceRate: Identifiable {
    let id: String
    let name: String
    let displayName: String
    let receivedBps: Double
    let sentBps: Double
}

private struct GPUProcessDemandEntry: Identifiable {
    let id: String
    let name: String
    let detail: String
    let sortValue: Double
}

private func computeCPUUsage(
    current: [CPUCoreSnapshot],
    previous: [CPUCoreSnapshot]
) -> (total: Double?, cores: [CPUCoreUsage]) {
    let previousByIndex = Dictionary(uniqueKeysWithValues: previous.map { ($0.index, $0) })
    var activeDeltaTotal: UInt64 = 0
    var totalDeltaTotal: UInt64 = 0
    var usages: [CPUCoreUsage] = []

    for core in current.sorted(by: { $0.index < $1.index }) {
        guard let old = previousByIndex[core.index],
              core.totalTicks >= old.totalTicks,
              core.activeTicks >= old.activeTicks else {
            continue
        }

        let totalDelta = core.totalTicks - old.totalTicks
        let activeDelta = core.activeTicks - old.activeTicks
        guard totalDelta > 0 else {
            continue
        }

        activeDeltaTotal += activeDelta
        totalDeltaTotal += totalDelta
        usages.append(CPUCoreUsage(
            id: core.index,
            index: core.index,
            usage: min(max(Double(activeDelta) / Double(totalDelta), 0), 1)
        ))
    }

    let total = totalDeltaTotal > 0 ? min(max(Double(activeDeltaTotal) / Double(totalDeltaTotal), 0), 1) : nil
    return (total, usages)
}

private func computeCPUSplit(current: CPUSnapshot, previous: [CPUCoreSnapshot]) -> (user: Double, system: Double)? {
    let previousUser = previous.reduce(UInt64(0)) { $0 + $1.userTicks + $1.niceTicks }
    let previousSystem = previous.reduce(UInt64(0)) { $0 + $1.systemTicks }
    let previousTotal = previous.reduce(UInt64(0)) { $0 + $1.totalTicks }
    guard current.totalUserTicks >= previousUser,
          current.totalSystemTicks >= previousSystem,
          current.totalTicks > previousTotal else {
        return nil
    }
    let total = Double(current.totalTicks - previousTotal)
    return (
        min(max(Double(current.totalUserTicks - previousUser) / total, 0), 1),
        min(max(Double(current.totalSystemTicks - previousSystem) / total, 0), 1)
    )
}

private func computeNetworkInterfaceRates(
    current: [NetworkInterfaceSnapshot],
    previous: [NetworkInterfaceSnapshot],
    interval: TimeInterval
) -> [NetworkInterfaceRate] {
    let previousByName = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })

    return current.compactMap { interface in
        guard let old = previousByName[interface.name],
              interface.receivedBytes >= old.receivedBytes,
              interface.sentBytes >= old.sentBytes else {
            return nil
        }

        return NetworkInterfaceRate(
            id: interface.name,
            name: interface.name,
            displayName: interface.displayName,
            receivedBps: Double(interface.receivedBytes - old.receivedBytes) / interval,
            sentBps: Double(interface.sentBytes - old.sentBytes) / interval
        )
    }
    .sorted {
        ($0.receivedBps + $0.sentBps) > ($1.receivedBps + $1.sentBps)
    }
}

private func loadGPUProcessDemand() -> [GPUProcessDemandEntry] {
    let output = runDiagnosticCommand("/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXDeviceUserClient", "-d", "1"])
    var currentName: String?
    var currentPID: String?
    var currentTime: UInt64 = 0
    var totals: [String: UInt64] = [:]

    func flush() {
        guard let name = currentName, currentTime > 0 else {
            currentName = nil
            currentPID = nil
            currentTime = 0
            return
        }

        let key = currentPID.map { "\(name) (\($0))" } ?? name
        totals[key, default: 0] += currentTime
        currentName = nil
        currentPID = nil
        currentTime = 0
    }

    for line in output.split(separator: "\n").map(String.init) {
        if line.contains("AGXDeviceUserClient") {
            flush()
            continue
        }

        if line.contains("IOUserClientCreator"),
           let match = firstDiagnosticMatch(in: line, pattern: #"pid\s+(\d+),\s*([^"]+)"#),
           match.count == 3 {
            currentPID = match[1]
            currentName = match[2].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for value in allDiagnosticMatches(in: line, pattern: #""accumulatedGPUTime"=(\d+)"#) {
            if value.count == 2, let time = UInt64(value[1]) {
                currentTime += time
            }
        }
    }
    flush()

    return totals
        .sorted { $0.value > $1.value }
        .map { name, nanoseconds in
            GPUProcessDemandEntry(
                id: name,
                name: name,
                detail: gpuTime(nanoseconds),
                sortValue: Double(nanoseconds)
            )
        }
}

private func runDiagnosticCommand(_ executable: String, arguments: [String]) -> String {
    ExternalCommandRunner.capture(
        executable: executable,
        arguments: arguments,
        timeout: 0.9
    )
}

private func firstDiagnosticMatch(in text: String, pattern: String) -> [String]? {
    allDiagnosticMatches(in: text, pattern: pattern).first
}

private func allDiagnosticMatches(in text: String, pattern: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).map { match in
        (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

private func gpuTime(_ nanoseconds: UInt64) -> String {
    let seconds = Double(nanoseconds) / 1_000_000_000
    if seconds >= 60 {
        return String(format: "%.1f min GPU", seconds / 60)
    }
    return String(format: "%.1f s GPU", seconds)
}

private struct AppMark: View {
    let size: CGFloat

    var body: some View {
        AppIconView(size: size)
    }
}

private struct MetricView: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct BatteryMetricView: View {
    let battery: BatterySnapshot

    private var detail: String {
        if battery.isCharging {
            return battery.timeToFullMinutes.map { "llena en \(formatBatteryMinutes($0))" } ?? "cargando"
        }
        if battery.externalConnected {
            return battery.isCharged || battery.percent >= 100 ? "cargada" : "carga en pausa"
        }
        return battery.timeToEmptyMinutes.map { "quedan \(formatBatteryMinutes($0))" } ?? "con batería"
    }

    var body: some View {
        HStack(spacing: 10) {
            BatteryGlyph(battery: battery, height: 13)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Batería")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(battery.percent)%")
                        .font(.system(size: 17, weight: .semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .help("Abrir Energía")
    }
}

private struct MaintenanceReviewPanel: View {
    let items: [MaintenanceReviewItem]

    private var issues: [MaintenanceReviewItem] {
        items.filter { $0.status >= .warning }
    }

    var body: some View {
        SectionPanel(title: "Revisión de mantenimiento", symbol: "checklist") {
            Text(issues.isEmpty
                 ? "Todo en orden: \(items.count) comprobaciones sin avisos."
                 : "\(issues.count) \(issues.count == 1 ? "punto necesita" : "puntos necesitan") atención.")
                .font(.callout)
                .foregroundStyle(issues.isEmpty ? Color.secondary : Color.orange)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
                ForEach(items.sorted { $0.status > $1.status }) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: symbol(item.status))
                            .foregroundStyle(tint(item.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func symbol(_ status: MaintenanceReviewItem.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    private func tint(_ status: MaintenanceReviewItem.Status) -> Color {
        switch status {
        case .ok: return .green
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct EventTimelineView: View {
    let events: [MaintenanceEvent]

    private var groups: [(day: Date, events: [MaintenanceEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]?.sorted { $0.date > $1.date } ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(dayTitle(group.day))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.events) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(event.category))
                                .foregroundStyle(tint(event.severity))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title)
                                    .font(.callout)
                                if let detail = event.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Text(event.date.formatted(date: .omitted, time: .shortened))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoy" }
        if calendar.isDateInYesterday(day) { return "Ayer" }
        return day.formatted(date: .complete, time: .omitted).capitalized
    }

    private func symbol(_ category: MaintenanceEvent.Category) -> String {
        switch category {
        case .alert: return "bell.badge"
        case .fans: return "fanblades"
        case .power: return "powerplug"
        case .thermal: return "thermometer.medium"
        case .system: return "power"
        }
    }

    private func tint(_ severity: MaintenanceEvent.Severity) -> Color {
        switch severity {
        case .info: return .accentColor
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct NetworkMetricView: View {
    let up: Double?
    let down: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Red").font(.caption).foregroundStyle(.secondary)
                rateRow(symbol: "arrow.up", rate: up, color: .green)
                rateRow(symbol: "arrow.down", rate: down, color: .red)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 50)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func rateRow(symbol: String, rate: Double?, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color).font(.caption)
            Text(rate.map(formatRate) ?? "--")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private struct PermissionBadge: View {
    let title: String
    let isGranted: Bool

    var body: some View {
        Label(
            title,
            systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption.weight(.medium))
        .foregroundStyle(isGranted ? Color.green : Color.orange)
        .lineLimit(1)
    }
}

private struct HealthStatusRow: View {
    let title: String
    let value: String
    let isHealthy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isHealthy ? Color.green : Color.orange)
                .frame(width: 18)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct SectionPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .labelStyle(.titleAndIcon)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private func shortProcessName(_ name: String) -> String {
    let token = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? name
    let last = URL(fileURLWithPath: token).lastPathComponent
    return last.isEmpty ? name : last
}

private struct SparklineChartView: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let points: TelemetryChartData
    var footnote: String? = nil

    private var domain: ClosedRange<Double> {
        let values = points.points.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...1
        }

        let padding = max((maxValue - minValue) * 0.18, max(abs(maxValue) * 0.08, 1))
        return max(0, minValue - padding)...(maxValue + padding)
    }

    var body: some View {
        let displayPoints = points.displayPoints(baseline: domain.lowerBound)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    Text(unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(displayPoints) { point in
                    LineMark(
                        x: .value("Tiempo", point.date),
                        y: .value(title, point.value)
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(point.isMeasurement ? title : "Pausa de medición")
                    .accessibilityValue(point.isMeasurement ? String(point.value) : "Sin medición real")
                    if displayPoints.count == 1 {
                        PointMark(x: .value("Tiempo", point.date), y: .value(title, point.value))
                            .symbolSize(12)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                if displayPoints.isEmpty {
                    RuleMark(y: .value(title, domain.lowerBound))
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Sin medición real")
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: domain)
            .frame(height: 74)
            .animation(.easeInOut(duration: 0.35), value: points.points.last?.date)

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ResponsiveChartGrid: View {
    let charts: [SparklineChartView]
    @State private var availableWidth: CGFloat = 0

    private var columnCount: Int {
        min(3, max(1, Int((availableWidth + 12) / 232)))
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: charts.count, by: columnCount)), id: \.self) { start in
                HStack(spacing: 12) {
                    ForEach(start..<min(start + columnCount, charts.count), id: \.self) { index in
                        charts[index].frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { availableWidth = $0 }
            }
        }
    }
}

private struct CPUCoreUsageGridView: View {
    let usages: [CPUCoreUsage]
    let cpu: CPUSnapshot

    private func label(for index: Int) -> String {
        switch cpu.coreKind(at: index) {
        case .efficiency?:
            return "Eficiencia \(index + 1)"
        case .performance?:
            return "Rendimiento \(index - (cpu.efficiencyCoreCount ?? 0) + 1)"
        case nil:
            return "Núcleo \(index + 1)"
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            ForEach(usages.sorted { $0.index < $1.index }) { core in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(label(for: core.index))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(formatPercent(core.usage))
                            .font(.system(.caption, design: .rounded).monospacedDigit())
                    }

                    ProgressView(value: core.usage, total: 1)
                        .tint(.accentColor)
                        .animation(.easeInOut(duration: 0.55), value: core.usage)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

private struct NetworkInterfaceDetailList: View {
    let interfaces: [NetworkInterfaceSnapshot]
    let rates: [NetworkInterfaceRate]
    let primaryName: String?

    @State private var showsSystemTunnels = false

    private var ordered: [NetworkInterfaceSnapshot] {
        interfaces.sorted { lhs, rhs in
            if (lhs.name == primaryName) != (rhs.name == primaryName) { return lhs.name == primaryName }
            if (lhs.kind == .vpn) != (rhs.kind == .vpn) { return rhs.kind == .vpn }
            return (lhs.receivedBytes + lhs.sentBytes) > (rhs.receivedBytes + rhs.sentBytes)
        }
    }

    /// Los túneles internos de macOS (iCloud, Continuidad, AirDrop) solo tienen direcciones link-local.
    private func isSystemTunnel(_ interface: NetworkInterfaceSnapshot) -> Bool {
        interface.kind == .vpn
            && interface.name != primaryName
            && interface.ipv4Addresses.isEmpty
            && interface.ipv6Addresses.isEmpty
    }

    var body: some View {
        let visible = ordered.filter { !isSystemTunnel($0) }
        let tunnels = ordered.filter(isSystemTunnel)

        VStack(alignment: .leading, spacing: 8) {
            if interfaces.isEmpty {
                EmptyStateView(message: "Sin interfaces activas.")
            }
            ForEach(visible) { interface in
                interfaceRow(interface, title: interface.displayName)
            }
            if !tunnels.isEmpty {
                DisclosureGroup(isExpanded: $showsSystemTunnels) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tunnels) { interface in
                            interfaceRow(interface, title: "Túnel del sistema")
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Túneles internos de macOS (\(tunnels.count))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func interfaceRow(_ interface: NetworkInterfaceSnapshot, title: String) -> some View {
        let rate = rates.first { $0.name == interface.name }
        return VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: interface.kind))
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(title)
                                    .font(.callout.weight(.medium))
                                if interface.name == primaryName {
                                    Text("principal")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                                }
                            }
                            Text(interface.name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Label(rate.map { formatRate($0.receivedBps) } ?? "--", systemImage: "arrow.down")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .frame(width: 110, alignment: .trailing)
                        Label(rate.map { formatRate($0.sentBps) } ?? "--", systemImage: "arrow.up")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .frame(width: 110, alignment: .trailing)
                    }

                    Text(detailLine(interface))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func detailLine(_ interface: NetworkInterfaceSnapshot) -> String {
        var parts: [String] = []
        if let ipv4 = interface.ipv4Addresses.first { parts.append("IP \(ipv4)") }
        if let mac = interface.macAddress { parts.append("MAC \(mac)") }
        if let speed = interface.linkSpeedBitsPerSecond, interface.kind != .vpn {
            parts.append(speed >= 1_000_000_000
                ? String(format: "Enlace %.1f Gb/s", Double(speed) / 1_000_000_000)
                : "Enlace \(speed / 1_000_000) Mb/s")
        }
        if let mtu = interface.mtu { parts.append("MTU \(mtu)") }
        parts.append("Total ↓ \(formatBytes(interface.receivedBytes)) ↑ \(formatBytes(interface.sentBytes))")
        let errors = interface.inputErrors + interface.outputErrors
        if errors > 0 { parts.append("\(errors) errores") }
        return parts.joined(separator: " · ")
    }

    private func symbol(for kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .vpn: return "lock.shield"
        case .other: return "network"
        }
    }
}

private struct AppNetworkUsageList: View {
    enum Mode: String, CaseIterable, Identifiable {
        case now = "Ahora"
        case total = "Acumulado"
        var id: String { rawValue }
    }

    let usage: [AppNetworkUsage]
    @State private var mode: Mode = .now

    private static var iconCache: [String: NSImage] = [:]

    private var isMeasuring: Bool {
        !usage.isEmpty && usage.allSatisfy { $0.receivedBps == nil }
    }

    private var rows: [AppNetworkUsage] {
        switch mode {
        case .now:
            return Array(usage.filter { $0.currentBps > 0 }.sorted { $0.currentBps > $1.currentBps }.prefix(10))
        case .total:
            return Array(usage.sorted { $0.totalBytes > $1.totalBytes }.prefix(10))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)

            if usage.isEmpty {
                EmptyStateView(message: "Leyendo el tráfico de las aplicaciones…")
            } else if mode == .now && isMeasuring {
                EmptyStateView(message: "Midiendo…")
            } else if rows.isEmpty {
                EmptyStateView(message: "Ninguna aplicación está usando la red ahora mismo.")
            } else {
                ForEach(rows) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: AppNetworkUsage) -> some View {
        HStack(spacing: 10) {
            icon(for: entry)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if mode == .now {
                Label(formatRate(entry.receivedBps ?? 0), systemImage: "arrow.down")
                    .frame(width: 110, alignment: .trailing)
                Label(formatRate(entry.sentBps ?? 0), systemImage: "arrow.up")
                    .frame(width: 110, alignment: .trailing)
            } else {
                Label(formatBytes(entry.totalReceivedBytes), systemImage: "arrow.down")
                    .frame(width: 110, alignment: .trailing)
                Label(formatBytes(entry.totalSentBytes), systemImage: "arrow.up")
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .font(.system(.callout, design: .rounded).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(entry.appPath ?? entry.name)
    }

    private func subtitle(_ entry: AppNetworkUsage) -> String {
        let kind = entry.appPath == nil ? "Proceso del sistema" : "Aplicación"
        return entry.processCount > 1 ? "\(kind) · \(entry.processCount) procesos" : kind
    }

    @ViewBuilder
    private func icon(for entry: AppNetworkUsage) -> some View {
        if let path = entry.appPath {
            Image(nsImage: Self.cachedIcon(path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "gearshape.2")
                .foregroundStyle(.secondary)
        }
    }

    private static func cachedIcon(_ path: String) -> NSImage {
        if let icon = iconCache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }
}

private struct VolumeUsageBar: View {
    let volume: VolumeSnapshot

    private var tint: Color {
        let free = 1 - volume.usedRatio
        return free < 0.05 ? .red : free < 0.12 ? .orange : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: volume.usedRatio, total: 1)
                .tint(tint)
            HStack {
                Text("\(formatBytes(volume.usedBytes)) usados")
                Spacer()
                Text("\(formatBytes(volume.availableBytes)) libres de \(formatBytes(volume.totalBytes))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct VolumeRowView: View {
    let volume: VolumeSnapshot
    let details: StorageDeviceDetails?
    let onEject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(volume.name)
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if volume.isEjectable && !volume.isRootVolume {
                    Button {
                        onEject()
                    } label: {
                        Label("Expulsar", systemImage: "eject")
                    }
                    .controlSize(.small)
                }
            }
            VolumeUsageBar(volume: volume)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var subtitle: String {
        var parts: [String] = [volume.isRootVolume ? "Arranque" : volume.isInternal ? "Interno" : "Externo"]
        if let format = volume.format { parts.append(format) }
        if let media = details?.mediaName { parts.append(media) }
        if let smart = details?.smartStatus, !volume.isRootVolume { parts.append("SMART \(localizedSMARTStatus(smart))") }
        if volume.isReadOnly && !volume.isRootVolume { parts.append("solo lectura") }
        parts.append(volume.path)
        return parts.joined(separator: " · ")
    }
}

private func localizedSMARTStatus(_ status: String) -> String {
    switch status {
    case "Verified": return "Correcto"
    case "Failing": return "Fallando"
    case "Not Supported": return "No disponible"
    default: return status
    }
}

private func latencyTint(_ milliseconds: Double?) -> Color {
    guard let milliseconds else { return .secondary }
    if milliseconds >= 150 { return .red }
    if milliseconds >= 60 { return .orange }
    return .green
}

private func wifiSignalSymbol(_ rssi: Int?) -> String {
    guard let rssi else { return "wifi" }
    return rssi >= -72 ? "wifi" : "wifi.exclamationmark"
}

private func wifiSignalTint(_ rssi: Int?) -> Color {
    guard let rssi else { return .secondary }
    if rssi >= -60 { return .green }
    if rssi >= -72 { return .yellow }
    return .orange
}

private struct GPUDemandListView: View {
    let entries: [GPUProcessDemandEntry]
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mayor demanda GPU", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if entries.isEmpty {
                EmptyStateView(message: isRefreshing ? "Calculando procesos GPU..." : "Sin procesos GPU activos detectados.")
            } else {
                ForEach(entries.prefix(8)) { entry in
                    HStack(spacing: 10) {
                        Text(entry.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Text(entry.detail)
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
}

private struct GlobalFanControlView: View {
    let fans: FanSnapshot
    let isWorking: Bool
    let onTurbo: () -> Void
    let onAuto: () -> Void

    private var averageActualRPM: Float {
        guard !fans.fans.isEmpty else {
            return 0
        }
        let total = fans.fans.reduce(Float(0)) { $0 + $1.actualRPM }
        return total / Float(fans.fans.count)
    }

    private var averageMaximumRPM: Float {
        guard !fans.fans.isEmpty else {
            return 1
        }
        let total = fans.fans.reduce(Float(0)) { $0 + max($1.maxRPM, 1) }
        return total / Float(fans.fans.count)
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Control global")
                    .font(.system(size: 15, weight: .semibold))
                Text("Media \(formatRPM(averageActualRPM)) | max \(formatRPM(averageMaximumRPM))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(averageActualRPM), total: Double(max(averageMaximumRPM, 1)))
                    .tint(.accentColor)
                    .animation(.easeInOut(duration: 0.55), value: averageActualRPM)
            }

            Spacer()

            Button(role: .destructive) {
                onTurbo()
            } label: {
                Label("Turbo", systemImage: "flame.fill")
            }
            .controlSize(.large)
            .disabled(isWorking)

            Button {
                onAuto()
            } label: {
                Label("Auto", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.large)
            .disabled(isWorking)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FanRowView: View {
    let reading: FanReading
    let isWorking: Bool
    let onSet: (Int, Float) -> Void
    let onAuto: (Int) -> Void

    @State private var rpm: Double

    init(
        reading: FanReading,
        isWorking: Bool,
        onSet: @escaping (Int, Float) -> Void,
        onAuto: @escaping (Int) -> Void
    ) {
        self.reading = reading
        self.isWorking = isWorking
        self.onSet = onSet
        self.onAuto = onAuto
        _rpm = State(initialValue: Double(reading.defaultTargetRPM))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(reading.displayName)
                    .font(.system(size: 15, weight: .semibold))

                ModeBadge(mode: reading.mode)

                Spacer()

                Text("\(formatRPM(reading.actualRPM)) actual")
                    .font(.system(.callout, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: Double(max(reading.actualRPM, 0)), total: Double(max(reading.maxRPM, 1)))
                .tint(.accentColor)
                .animation(.easeInOut(duration: 0.55), value: reading.actualRPM)

            HStack(spacing: 10) {
                Text(formatRPM(reading.minRPM))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Slider(
                    value: $rpm,
                    in: Double(reading.safeMinimumManualRPM)...Double(max(reading.maxRPM, reading.safeMinimumManualRPM)),
                    step: 25
                )
                .disabled(isWorking)

                TextField("", value: $rpm, formatter: NumberFormatter.rpm)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .rounded).monospacedDigit())
                    .frame(width: 78)
                    .disabled(isWorking)

                Text("RPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    onSet(reading.index, Float(rpm))
                } label: {
                    Label("Aplicar", systemImage: "checkmark.circle")
                }
                .disabled(isWorking)

                Button {
                    onAuto(reading.index)
                } label: {
                    Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isWorking)
            }

            Text("Rango permitido \(formatRPM(reading.minRPM))-\(formatRPM(reading.maxRPM))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ModeBadge: View {
    let mode: FanMode

    var body: some View {
        Text(mode.rawValue)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(mode == .manual ? Color.orange : Color.secondary)
            .background(
                (mode == .manual ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.12)),
                in: Capsule()
            )
    }
}

private struct SensorGroupView: View {
    let title: String
    let readings: [SensorReading]
    let formatter: (Float) -> String
    let ceiling: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(readings) { reading in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.sensor.name)
                            .font(.callout)
                        Text(reading.sensor.key)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 150, alignment: .leading)

                    ProgressView(value: Double(max(reading.value, 0)), total: Double(ceiling))
                        .tint(tint(for: reading))
                        .animation(.easeInOut(duration: 0.55), value: reading.value)

                    Text(formatter(reading.value))
                        .font(.system(.callout, design: .rounded).monospacedDigit())
                        .frame(width: 74, alignment: .trailing)
                }
            }
        }
    }

    private func tint(for reading: SensorReading) -> Color {
        guard reading.sensor.type == .temperature else {
            return .blue
        }

        if reading.value >= 90 {
            return .red
        }
        if reading.value >= 75 {
            return .orange
        }
        return .green
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer()
        }
        .font(.callout)
    }
}

private struct EmptyStateView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

extension Notification.Name {
    static let fanManualControlDidSucceed = Notification.Name("fanManualControlDidSucceed")
    static let cleanModeStartRequested = Notification.Name("cleanModeStartRequested")
    static let diagnosticsSectionRequested = Notification.Name("diagnosticsSectionRequested")
    static let fanAutomaticControlDidSucceed = Notification.Name("fanAutomaticControlDidSucceed")
    static let preferencesRequested = Notification.Name("preferencesRequested")
}

private struct OverviewVerdict {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    static func make(snapshot: DashboardSnapshot, cpuUsage: Double?) -> OverviewVerdict {
        let hottest = snapshot.sensors?.hottestTemperature.map { Double($0.value) }
        let pressure = snapshot.telemetry.memory.pressureLevel
        let thermal = ProcessInfo.processInfo.thermalState

        if thermal == .critical || (hottest ?? 0) >= AppPreferences.temperatureCriticalThreshold {
            let temperature = hottest.map { "\(Int($0.rounded())) °C" } ?? snapshot.system.thermalState
            return OverviewVerdict(
                title: "Temperatura crítica",
                detail: "El Mac está en \(temperature). Baja la carga o activa Turbo si los ventiladores no responden.",
                symbol: "thermometer",
                tint: .red
            )
        }

        if thermal == .serious || (hottest ?? 0) >= AppPreferences.temperatureWarningThreshold {
            let temperature = hottest.map { "\(Int($0.rounded())) °C" } ?? snapshot.system.thermalState
            return OverviewVerdict(
                title: "Va caliente",
                detail: "Temperatura máxima \(temperature). El sistema está pidiendo más refrigeración.",
                symbol: "flame.fill",
                tint: .orange
            )
        }

        if pressure >= 3 {
            return OverviewVerdict(
                title: "Memoria justa",
                detail: "La presión de RAM es alta (\(formatPercent(snapshot.telemetry.memory.usedRatio)) usada). Cierra apps pesadas si va lento.",
                symbol: "memorychip",
                tint: .orange
            )
        }

        if pressure >= 2 {
            return OverviewVerdict(
                title: "Presión de memoria moderada",
                detail: "Hay \(formatPercent(snapshot.telemetry.memory.usedRatio)) de RAM en uso. Vigila si empiezan a comprimirse procesos.",
                symbol: "memorychip",
                tint: .yellow
            )
        }

        if let cpuUsage, cpuUsage >= 0.85 {
            return OverviewVerdict(
                title: "CPU muy ocupada",
                detail: "Uso de CPU al \(formatPercent(cpuUsage)). Mira qué proceso está cargando más abajo.",
                symbol: "cpu",
                tint: .orange
            )
        }

        if !snapshot.sensorStatus.isCurrent || !snapshot.fanStatus.isCurrent || !snapshot.telemetry.memory.isAvailable || pressure < 0 {
            return OverviewVerdict(
                title: "Lecturas incompletas",
                detail: "Hay métricas del sistema sin lectura actual fiable.",
                symbol: "exclamationmark.triangle",
                tint: .orange
            )
        }

        return OverviewVerdict(
            title: "Todo bien",
            detail: "Sin alertas térmicas ni de memoria. Estado térmico \(snapshot.system.thermalState).",
            symbol: "checkmark.seal.fill",
            tint: .green
        )
    }
}

private struct SystemSnapshot {
    let model: String
    let processor: String
    let thermalState: String
    let lowPowerMode: String
    let uptime: String
    let thermalTint: Color

    static func current() -> SystemSnapshot {
        let thermal = ProcessInfo.processInfo.thermalState
        return SystemSnapshot(
            model: sysctlString("hw.model") ?? "desconocido",
            processor: sysctlString("machdep.cpu.brand_string") ?? "desconocido",
            thermalState: thermalStateDescription(thermal),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled ? "activado" : "desactivado",
            uptime: formattedUptime(ProcessInfo.processInfo.systemUptime),
            thermalTint: thermalTint(thermal)
        )
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "moderado"
        case .serious:
            return "alto"
        case .critical:
            return "crítico"
        @unknown default:
            return "desconocido"
        }
    }

    private static func thermalTint(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal:
            return .green
        case .fair:
            return .yellow
        case .serious:
            return .orange
        case .critical:
            return .red
        @unknown default:
            return .secondary
        }
    }

    private static func formattedUptime(_ uptime: TimeInterval) -> String {
        let totalMinutes = Int(uptime / 60)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }

        return "\(hours)h \(minutes)m"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }
}

private extension FanReading {
    var defaultTargetRPM: Float {
        if targetRPM >= safeMinimumManualRPM {
            return min(targetRPM, maxRPM)
        }
        return safeMinimumManualRPM
    }
}

private extension Result {
    var failureDescription: String? {
        if case .failure(let error) = self {
            return error.localizedDescription
        }
        return nil
    }
}

private extension Array where Element == SensorReading {
    func sortedBySensorNumber() -> [SensorReading] {
        sorted { lhs, rhs in
            let left = lhs.sensor.naturalSortParts
            let right = rhs.sensor.naturalSortParts

            if left.prefix == right.prefix {
                if left.number == right.number {
                    return lhs.sensor.key.localizedStandardCompare(rhs.sensor.key) == .orderedAscending
                }
                return left.number < right.number
            }

            return left.prefix.localizedStandardCompare(right.prefix) == .orderedAscending
        }
    }
}

private extension SensorKey {
    var naturalSortParts: (prefix: String, number: Int) {
        let source = name.isEmpty ? key : name
        let digits = source
            .reversed()
            .prefix { $0.isNumber }
            .reversed()
        let number = Int(String(digits)) ?? Int.max
        let prefix = source.replacingOccurrences(of: #"[\s-]*\d+$"#, with: "", options: .regularExpression)
        return (prefix, number)
    }
}

private extension NumberFormatter {
    static var rpm: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 0
        return formatter
    }
}

private func formatRPM(_ value: Float) -> String {
    "\(Int(value.rounded())) RPM"
}

private func formatTemperature(_ value: Float) -> String {
    String(format: "%.1f C", value)
}

private func formatTemperature(_ value: Double) -> String {
    String(format: "%.1f C", value)
}

private func formatTemperatureValue(_ value: Double) -> String {
    String(format: "%.1f", value)
}

private func temperatureTint(_ value: Double?) -> Color {
    guard let value else {
        return .secondary
    }
    if value >= 90 {
        return .red
    }
    if value >= 75 {
        return .orange
    }
    return .green
}

private func memoryPressureTint(_ level: Int) -> Color {
    if level < 0 { return .secondary }
    switch level {
    case 0...1:
        return .green
    case 2:
        return .orange
    default:
        return .red
    }
}

private func formatPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.storage.string(fromByteCount: Int64(bytes))
}

private func formatRate(_ bytesPerSecond: Double) -> String {
    "\(formatRateValue(bytesPerSecond)) \(rateUnit(bytesPerSecond))"
}

private func formatRateValue(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded()))"
}

private func rateUnit(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return "MB/s"
    }
    if bytesPerSecond >= 1_000 {
        return "KB/s"
    }
    return "B/s"
}

private func batterySummary(_ battery: BatterySnapshot) -> String {
    var parts = ["\(battery.percent)%"]

    if battery.isCharged {
        parts.append("cargada")
    } else if battery.isCharging {
        parts.append("cargando")
    } else if battery.externalConnected {
        parts.append("corriente")
    }

    if let cycles = battery.cycleCount {
        parts.append("\(cycles) ciclos")
    }

    if let health = battery.healthPercent {
        parts.append("salud \(health)%")
    }

    if let temperature = battery.temperatureCelsius {
        parts.append(String(format: "%.1f C", temperature))
    }

    return parts.joined(separator: " | ")
}

private func appResourceSummary(_ resources: AppResourceSnapshot) -> String {
    let cpu = resources.cpuRatio.map(formatPercent) ?? "calculando"
    return "CPU \(cpu) | RAM \(formatBytes(resources.residentMemoryBytes))"
}

private func networkSummary(_ network: NetworkSnapshot) -> String {
    guard !network.interfaces.isEmpty else {
        return "sin interfaces activas"
    }

    return network.interfaces
        .prefix(3)
        .map { $0.displayName }
        .joined(separator: ", ")
}

private extension ByteCountFormatter {
    static var storage: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }
}
