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
    @State private var lastTelemetryDate: Date?

    var body: some View {
        ZStack {
            VisualEffect(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(selection: $selectedSection)
                    .frame(width: 168)
                    .padding(.vertical, 16)
                    .padding(.leading, 12)
                    .padding(.trailing, 10)

                Divider()

                VStack(spacing: 12) {
                    header

                    ScrollView {
                        VStack(spacing: 14) {
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
                reloadSnapshot(status: nil, includeSMC: true, fullTelemetry: true, force: true)
            }
            refreshTopCPUDemand(force: true)
            refreshHealthStatus()
        }
        .task {
            await refreshLoop()
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
            memorySection
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
                    symbol: "gpu",
                    tint: .accentColor
                )
                MetricView(
                    title: "Memoria",
                    value: formatPercent(snapshot.telemetry.memory.usedRatio),
                    symbol: "memorychip",
                    tint: snapshot.telemetry.memory.pressureLevel >= 2 ? .orange : .secondary
                )
                MetricView(
                    title: "Red",
                    value: "↓ \(history.latestNetworkDownBps.map(formatRate) ?? "--")  ↑ \(history.latestNetworkUpBps.map(formatRate) ?? "--")",
                    symbol: "network",
                    tint: .accentColor
                )
                MetricView(
                    title: "Temp. máx.",
                    value: snapshot.sensors?.hottestTemperature.map { formatTemperature($0.value) } ?? "sin datos",
                    symbol: "flame",
                    tint: snapshot.system.thermalTint
                )
                if let battery = snapshot.telemetry.battery {
                    MetricView(
                        title: "Batería",
                        value: "\(battery.percent)%",
                        symbol: "battery.100percent",
                        tint: battery.isCharging || battery.isCharged ? .green : .secondary
                    )
                }
            }

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

    private var graphSection: some View {
        SectionPanel(title: "Gráficas", symbol: "chart.xyaxis.line") {
            HStack {
                Button {
                    exportPersistentHistory()
                } label: {
                    Label("Exportar CSV", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                SparklineChartView(
                    title: "CPU total",
                    value: history.latestCPUUsage.map(formatPercent) ?? "sin datos",
                    unit: "",
                    symbol: "cpu",
                    points: history.cpuPoints
                )

                SparklineChartView(
                    title: "GPU",
                    value: history.latestGPUUsage.map(formatPercent) ?? "sin datos",
                    unit: "",
                    symbol: "gpu",
                    points: history.gpuPoints
                )

                SparklineChartView(
                    title: "Temperatura max",
                    value: history.latestMaxTemperature.map(formatTemperatureValue) ?? "sin datos",
                    unit: "C",
                    symbol: "thermometer.medium",
                    points: history.temperaturePoints
                )

                SparklineChartView(
                    title: "Temperatura GPU",
                    value: history.latestGPUTemperature.map(formatTemperatureValue) ?? "sin datos",
                    unit: "C",
                    symbol: "thermometer.medium",
                    points: history.gpuTemperaturePoints
                )

                SparklineChartView(
                    title: "RPM media",
                    value: history.latestAverageRPM.map { "\(Int($0.rounded()))" } ?? "sin datos",
                    unit: "RPM",
                    symbol: "fanblades",
                    points: history.rpmPoints
                )

                SparklineChartView(
                    title: "Potencia sistema",
                    value: history.latestSystemPower.map { String(format: "%.1f", $0) } ?? "sin datos",
                    unit: "W",
                    symbol: "bolt",
                    points: history.powerPoints
                )

                SparklineChartView(
                    title: "Memoria usada",
                    value: history.latestMemoryRatio.map(formatPercent) ?? "sin datos",
                    unit: "",
                    symbol: "memorychip",
                    points: history.memoryPoints
                )

                SparklineChartView(
                    title: "Red bajada",
                    value: history.latestNetworkDownBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestNetworkDownBps.map(rateUnit) ?? "",
                    symbol: "arrow.down.circle",
                    points: history.networkDownPoints
                )

                SparklineChartView(
                    title: "Red subida",
                    value: history.latestNetworkUpBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestNetworkUpBps.map(rateUnit) ?? "",
                    symbol: "arrow.up.circle",
                    points: history.networkUpPoints
                )

                SparklineChartView(
                    title: "Disco lectura",
                    value: history.latestDiskReadBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestDiskReadBps.map(rateUnit) ?? "",
                    symbol: "arrow.down.doc",
                    points: history.diskReadPoints
                )

                SparklineChartView(
                    title: "Disco escritura",
                    value: history.latestDiskWriteBps.map(formatRateValue) ?? "sin datos",
                    unit: history.latestDiskWriteBps.map(rateUnit) ?? "",
                    symbol: "arrow.up.doc",
                    points: history.diskWritePoints
                )
            }
        }
    }

    private var macTelemetrySection: some View {
        SectionPanel(title: "Mac", symbol: "desktopcomputer") {
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

    private var cpuSection: some View {
        SectionPanel(title: "CPU", symbol: "cpu") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Uso total",
                    value: history.latestCPUUsage.map(formatPercent) ?? "calculando",
                    symbol: "cpu",
                    tint: .accentColor
                )
                MetricView(
                    title: "Núcleos",
                    value: "\(snapshot.telemetry.cpu.coreCount)",
                    symbol: "circle.grid.3x3",
                    tint: .secondary
                )
                MetricView(
                    title: "Memoria",
                    value: formatPercent(snapshot.telemetry.memory.usedRatio),
                    symbol: "memorychip",
                    tint: .secondary
                )
            }

            if history.latestCoreUsages.isEmpty {
                EmptyStateView(message: "Calculando uso por núcleo...")
            } else {
                CPUCoreUsageGridView(usages: history.latestCoreUsages)
            }
        }
    }

    private var gpuSection: some View {
        SectionPanel(title: "GPU", symbol: "gpu") {
            let gpu = snapshot.telemetry.gpu
            let gpuTemperatures = snapshot.sensors?.readings(type: .temperature, group: .gpu).sortedBySensorNumber() ?? []
            let gpuPower = snapshot.sensors?.readings(type: .power, group: .gpu).first
            let gpuVoltage = snapshot.sensors?.readings(type: .voltage, group: .gpu).first

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Uso GPU",
                    value: history.latestGPUUsage.map(formatPercent) ?? "sin datos",
                    symbol: "gpu",
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
        SectionPanel(title: "Red", symbol: "network") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Bajada total",
                    value: history.latestNetworkDownBps.map(formatRate) ?? "0 B/s",
                    symbol: "arrow.down.circle",
                    tint: .accentColor
                )
                MetricView(
                    title: "Subida total",
                    value: history.latestNetworkUpBps.map(formatRate) ?? "0 B/s",
                    symbol: "arrow.up.circle",
                    tint: .accentColor
                )
                MetricView(
                    title: "Interfaces",
                    value: "\(snapshot.telemetry.network.interfaces.count)",
                    symbol: "network",
                    tint: .secondary
                )
            }

            NetworkInterfaceRateView(rates: history.latestNetworkInterfaceRates)
        }
    }

    private var storageSection: some View {
        SectionPanel(title: "Disco", symbol: "internaldrive") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricView(
                    title: "Libre",
                    value: formatBytes(snapshot.telemetry.disk.availableBytes),
                    symbol: "internaldrive",
                    tint: .secondary
                )
                MetricView(
                    title: "Usado",
                    value: formatPercent(snapshot.telemetry.disk.usedRatio),
                    symbol: "chart.pie",
                    tint: .secondary
                )
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
            }

            InfoRow(title: "Volumen", value: snapshot.telemetry.disk.volumeName)
            InfoRow(title: "Capacidad", value: "\(formatBytes(snapshot.telemetry.disk.usedBytes)) usado de \(formatBytes(snapshot.telemetry.disk.totalBytes))")
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
                    Text("Modo \(fans.modeKeyFormat ?? "desconocido")")
                    Text(fans.forceTestAvailable ? "Ftst disponible" : "Ftst no disponible")
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
        SectionPanel(title: "Energía", symbol: "bolt") {
            let power = snapshot.sensors?.readings(type: .power) ?? []

            if power.isEmpty {
                EmptyStateView(message: "Sin lecturas de potencia por ahora.")
            } else {
                SensorGroupView(
                    title: "Potencia",
                    readings: power,
                    formatter: { String(format: "%.1f W", $0) },
                    ceiling: 120
                )
            }
        }
    }

    private var systemSection: some View {
        VStack(spacing: 14) {
            SectionPanel(title: "Estado del sistema", symbol: "checkmark.shield") {
                HealthStatusRow(title: "Accesibilidad", value: accessibilityTrusted ? "Activa" : "Falta permiso", isHealthy: accessibilityTrusted)
                HealthStatusRow(title: "Monitorización de entrada", value: inputMonitoringTrusted ? "Activa" : "Falta permiso", isHealthy: inputMonitoringTrusted)
                HealthStatusRow(title: "Helper de ventiladores", value: helperAvailable == true ? "Activo" : helperAvailable == false ? "No disponible" : "Comprobando...", isHealthy: helperAvailable == true)
                HealthStatusRow(title: "Sensores SMC", value: snapshot.sensors == nil ? "Sin lecturas" : "Disponibles", isHealthy: snapshot.sensors != nil)
                HealthStatusRow(title: "Última lectura", value: lastTelemetryDate?.formatted(date: .omitted, time: .standard) ?? "Esperando...", isHealthy: lastTelemetryDate != nil)
            }

            SectionPanel(title: "Sistema", symbol: "macbook") {
            InfoRow(title: "Modelo", value: snapshot.system.model)
            InfoRow(title: "Procesador", value: snapshot.system.processor)
            InfoRow(title: "Uptime", value: snapshot.system.uptime)
            InfoRow(title: "Mantenimiento", value: appResourceSummary(snapshot.appResources))

            HStack {
                Button {
                    copyDiagnosticSummary()
                } label: {
                    Label("Copiar diagnóstico", systemImage: "doc.on.doc")
                }
                Spacer()
            }
            }
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
            window.title == "Mantenimiento" && window.isVisible
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            if isDiagnosticsWindowVisible {
                refreshSilently()
                if selectedSection == .cleaning {
                    refreshPermissionState()
                }
            }

            let interval: TimeInterval = isDiagnosticsWindowVisible ? 1.5 : 8
            try? await Task.sleep(for: .seconds(interval))
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

    private func refreshSilently() {
        guard !isWorking, !isRefreshing else {
            return
        }

        refreshSequence += 1
        let periodicFullRefresh = refreshSequence.isMultiple(of: 3)
        if selectedSection == .gpu, refreshSequence.isMultiple(of: 3) {
            refreshGPUDemand()
        }
        if selectedSection == .overview, refreshSequence.isMultiple(of: 3) {
            refreshTopCPUDemand()
        }
        reloadSnapshot(
            status: nil,
            includeSMC: selectedSection.needsSMCRefresh || periodicFullRefresh,
            fullTelemetry: selectedSection.needsFullTelemetry || periodicFullRefresh
        )
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
                if status == nil {
                    snapshot = nextSnapshot
                    history.append(nextSnapshot)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        snapshot = nextSnapshot
                        history.append(nextSnapshot)
                    }
                }
                lastTelemetryDate = Date()
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
            let isAvailable = PrivilegedHelperInstaller.ping() != nil
            await MainActor.run {
                helperAvailable = isAvailable
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

    private func diagnosticSummary() -> String {
        var lines: [String] = [
            "Mantenimiento - diagnóstico rápido",
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
        }

        return lines.joined(separator: "\n")
    }

    private func setFan(_ index: Int, _ rpm: Float) {
        runFanAction("Aplicando \(Int(rpm)) RPM al ventilador \(index + 1)...") {
            do {
                let strategy = try FanService.make().setFanRPM(index: index, rpm: rpm)
                NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
                return "Ventilador \(index + 1) en manual (\(strategy.rawValue))."
            } catch {
                guard PrivilegedFanTool.shouldRetryPrivileged(error) else {
                    throw error
                }

                _ = try await Task.detached {
                    try PrivilegedFanTool.setFanRPM(index: index, rpm: rpm)
                }.value
                NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
                return "Ventilador \(index + 1) en manual con autorización."
            }
        }
    }

    private func setFanAuto(_ index: Int) {
        runFanAction("Aplicando automático al ventilador \(index + 1)...") {
            do {
                try FanService.make().setFanAuto(index: index)
            } catch {
                guard PrivilegedFanTool.shouldRetryPrivileged(error) else {
                    throw error
                }

                _ = try await Task.detached {
                    try PrivilegedFanTool.setFanAuto(index: index)
                }.value
            }
            return "Ventilador \(index + 1) en automatico."
        }
    }

    private func setAllFansAuto() {
        runFanAction("Aplicando automático a los ventiladores...") {
            do {
                try FanService.make().setAllFansAuto()
            } catch {
                guard PrivilegedFanTool.shouldRetryPrivileged(error) else {
                    throw error
                }

                _ = try await Task.detached {
                    try PrivilegedFanTool.setAllFansAuto()
                }.value
            }
            return "Ventiladores en automático."
        }
    }

    private func setAllFansTurbo() {
        runFanAction("Activando turbo en todos los ventiladores...") {
            do {
                try FanService.make().setAllFansToMaximum()
                NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
            } catch {
                guard PrivilegedFanTool.shouldRetryPrivileged(error) else {
                    throw error
                }

                _ = try await Task.detached {
                    try PrivilegedFanTool.setAllFansTurbo()
                }.value
                NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
            }
            return "Turbo activo: ventiladores al maximo."
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
                withAnimation(.easeInOut(duration: 0.55)) {
                    snapshot = nextSnapshot
                    history.append(nextSnapshot)
                }
            }
        }
    }
}

private struct DashboardSnapshot {
    let system: SystemSnapshot
    let fans: FanSnapshot?
    let sensors: SensorSnapshot?
    let telemetry: SystemTelemetrySnapshot
    let appResources: AppResourceSnapshot
    let fanError: String?
    let sensorError: String?

    static func placeholder() -> DashboardSnapshot {
        DashboardSnapshot(
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

        return DashboardSnapshot(
            system: .current(),
            fans: shared.fans ?? previous?.fans,
            sensors: shared.sensors ?? previous?.sensors,
            telemetry: shared.telemetry,
            appResources: shared.appResources,
            fanError: shared.fanError ?? previous?.fanError,
            sensorError: shared.sensorError ?? previous?.sensorError
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
        case .system:
            return "macbook"
        }
    }

    var needsSMCRefresh: Bool {
        switch self {
        case .graphs, .gpu, .memory, .fans, .temperatures, .energy, .overview:
            return true
        case .mac, .cpu, .network, .storage, .cleaning, .system:
            return false
        }
    }

    var needsFullTelemetry: Bool {
        switch self {
        case .graphs, .mac, .memory, .storage, .system, .overview:
            return true
        case .cpu, .gpu, .network, .cleaning, .fans, .temperatures, .energy:
            return false
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: DashboardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DashboardSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 8) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.callout)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == section ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .background(
                    selection == section ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer()
        }
    }
}

private struct TelemetryHistory {
    private(set) var samples: [TelemetrySample] = []
    private let maxSampleCount = 80

    mutating func append(_ snapshot: DashboardSnapshot) {
        samples.append(TelemetrySample(snapshot: snapshot, previous: samples.last))
        if samples.count > maxSampleCount {
            samples.removeFirst(samples.count - maxSampleCount)
        }
    }

    var temperaturePoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.maxTemperature.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var cpuPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.cpuUsage.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var gpuPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.gpuUsage.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var gpuTemperaturePoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.gpuTemperature.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var rpmPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.averageRPM.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var powerPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.systemPower.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var memoryPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.memoryUsedRatio.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var networkDownPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.networkDownBps.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var networkUpPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.networkUpBps.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var diskReadPoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.diskReadBps.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var diskWritePoints: [TelemetryChartPoint] {
        samples.compactMap { sample in
            sample.diskWriteBps.map { TelemetryChartPoint(date: sample.date, value: $0) }
        }
    }

    var latestMaxTemperature: Double? {
        temperaturePoints.last?.value
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
        rpmPoints.last?.value
    }

    var latestSystemPower: Double? {
        powerPoints.last?.value
    }

    var latestMemoryRatio: Double? {
        memoryPoints.last?.value
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
    let date = Date()
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

    init(snapshot: DashboardSnapshot) {
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
        memoryUsedRatio = snapshot.telemetry.memory.usedRatio
        gpuUsage = snapshot.telemetry.gpu?.utilizationRatio
        gpuTemperature = snapshot.sensors?.readings(type: .temperature, group: .gpu).map { Double($0.value) }.max()
        cpuCores = snapshot.telemetry.cpu.cores
        cpuUsage = nil
        coreUsages = []
        diskReadBytes = snapshot.telemetry.diskIO.readBytes
        diskWrittenBytes = snapshot.telemetry.diskIO.writtenBytes
        diskReadBps = nil
        diskWriteBps = nil
        networkReceivedBytes = snapshot.telemetry.network.totalReceivedBytes
        networkSentBytes = snapshot.telemetry.network.totalSentBytes
        networkInterfaces = snapshot.telemetry.network.interfaces
        networkDownBps = nil
        networkUpBps = nil
        networkInterfaceRates = []
    }

    init(snapshot: DashboardSnapshot, previous: TelemetrySample?) {
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
        memoryUsedRatio = snapshot.telemetry.memory.usedRatio
        gpuUsage = snapshot.telemetry.gpu?.utilizationRatio
        gpuTemperature = snapshot.sensors?.readings(type: .temperature, group: .gpu).map { Double($0.value) }.max()
        cpuCores = snapshot.telemetry.cpu.cores
        diskReadBytes = snapshot.telemetry.diskIO.readBytes
        diskWrittenBytes = snapshot.telemetry.diskIO.writtenBytes
        networkReceivedBytes = snapshot.telemetry.network.totalReceivedBytes
        networkSentBytes = snapshot.telemetry.network.totalSentBytes
        networkInterfaces = snapshot.telemetry.network.interfaces

        if let previous {
            let interval = max(date.timeIntervalSince(previous.date), 0.1)
            let cpu = computeCPUUsage(current: cpuCores, previous: previous.cpuCores)
            cpuUsage = cpu.total
            coreUsages = cpu.cores

            if diskReadBytes >= previous.diskReadBytes {
                diskReadBps = Double(diskReadBytes - previous.diskReadBytes) / interval
            } else {
                diskReadBps = nil
            }

            if diskWrittenBytes >= previous.diskWrittenBytes {
                diskWriteBps = Double(diskWrittenBytes - previous.diskWrittenBytes) / interval
            } else {
                diskWriteBps = nil
            }

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
            diskReadBps = nil
            diskWriteBps = nil
            networkDownBps = nil
            networkUpBps = nil
            networkInterfaceRates = []
        }
    }
}

private struct TelemetryChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
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
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            Image(systemName: "fanblades.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.tint)
        }
        .frame(width: size, height: size)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    let points: [TelemetryChartPoint]

    private var domain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...1
        }

        let padding = max((maxValue - minValue) * 0.18, max(abs(maxValue) * 0.08, 1))
        return max(0, minValue - padding)...(maxValue + padding)
    }

    var body: some View {
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

            Chart(points) { point in
                LineMark(
                    x: .value("Tiempo", point.date),
                    y: .value(title, point.value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: domain)
            .frame(height: 74)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CPUCoreUsageGridView: View {
    let usages: [CPUCoreUsage]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            ForEach(usages.sorted { $0.index < $1.index }) { core in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Nucleo \(core.index + 1)")
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

private struct NetworkInterfaceRateView: View {
    let rates: [NetworkInterfaceRate]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rates.isEmpty {
                EmptyStateView(message: "Calculando velocidad por interfaz...")
            } else {
                ForEach(rates) { rate in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rate.displayName)
                                .font(.callout.weight(.medium))
                            Text(rate.name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: 100, alignment: .leading)

                        Spacer()

                        Label(formatRate(rate.receivedBps), systemImage: "arrow.down")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .frame(width: 120, alignment: .trailing)

                        Label(formatRate(rate.sentBps), systemImage: "arrow.up")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .frame(width: 120, alignment: .trailing)
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }
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
        .animation(.easeInOut(duration: 0.55), value: reading.actualRPM)
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
                .frame(width: 110, alignment: .leading)
            Text(value)
                .lineLimit(1)
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
