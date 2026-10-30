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

struct DiagnosticsRootView: View {
    @State var snapshot = DashboardSnapshot.placeholder()
    @State var statusMessage = "Listo"
    @State var isWorking = false
    @State var isRefreshing = false
    @State var accessibilityTrusted = InputBlocker.isAccessibilityTrusted(prompt: false)
    @State var inputMonitoringTrusted = InputBlocker.isInputMonitoringTrusted(prompt: false)
    @State var history = TelemetryHistory()
    @State var selectedSection: DashboardSection = .overview
    @State var refreshSequence = 0
    @State var gpuDemandEntries: [GPUProcessDemandEntry] = []
    @State var isRefreshingGPUDemand = false
    @State var topCPUDemand: MenuDemandEntry?
    @State var isRefreshingTopDemand = false
    @State var helperAvailable: Bool?
    @State var helperStatusText = "Comprobando..."
    @State var lastTelemetryDate: Date?
    @State var historyRange: TelemetryHistoryRange = .live
    @State var historyRows: [TelemetryHistoryRow] = []
    @State var isLoadingHistory = false
    @State var wifiDetails: WiFiDetails?
    @State var routeDetails: NetworkRouteDetails?
    @State var connectivity: ConnectivityDetails?
    @State var storageDetails: [String: StorageDeviceDetails] = [:]
    @State var hardwareDetails: HardwareDetails?
    @State var securityDetails: SecurityDetails?
    @State var osDetails = SystemDetailsProvider.shared.operatingSystemDetails()
    @State var events: [MaintenanceEvent] = []
    @State var lastLatencyCheck: Date?
    @State var appNetworkUsage: [AppNetworkUsage] = []
    @State var isSamplingAppNetwork = false
    @State var storageReport: StorageReport?
    @State var isAnalyzingStorage = false
    @State var appEnergyUsage: [AppEnergyUsage] = []
    @State var isSamplingEnergy = false
    @State var batteryHealthEntries: [BatteryHealthEntry] = []
    @State var launchItems: [LaunchItem]?
    @State var isScanningLaunchItems = false

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
    var selectedContent: some View {
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
        case .startup:
            LaunchItemsView(items: launchItems, isScanning: isScanningLaunchItems) {
                refreshSectionDetails(.startup, force: true)
            }
        case .system:
            systemSection
        }
    }

    var header: some View {
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

    var footer: some View {
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

    var isDiagnosticsWindowVisible: Bool {
        NSApp.windows.contains { window in
            window.title == "Mantenimiento" && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    func refresh() {
        reloadSnapshot(
            status: "Actualizado \(Date.now.formatted(date: .omitted, time: .shortened))",
            includeSMC: true,
            fullTelemetry: true,
            force: true
        )
    }

    func applySnapshot(_ nextSnapshot: DashboardSnapshot) {
        guard lastTelemetryDate.map({ nextSnapshot.date > $0 }) ?? true else { return }
        snapshot = nextSnapshot
        history.append(nextSnapshot)
        lastTelemetryDate = nextSnapshot.date
    }

    func reloadSnapshot(status: String?, includeSMC: Bool, fullTelemetry: Bool, force: Bool = false) {
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

    func refreshTopCPUDemand(force: Bool = false) {
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

    func refreshGPUDemand(force: Bool = false) {
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

    func refreshPermissionState() {
        accessibilityTrusted = InputBlocker.isAccessibilityTrusted(prompt: false)
        inputMonitoringTrusted = InputBlocker.isInputMonitoringTrusted(prompt: false)
    }

    func refreshHealthStatus() {
        Task.detached(priority: .utility) {
            let response = PrivilegedHelperInstaller.ping()
            let isAvailable = response == FanHelperProtocol.greeting
            await MainActor.run {
                helperAvailable = isAvailable
                helperStatusText = isAvailable ? "Activo v3" : response != nil ? "Actualización necesaria" : "No disponible"
            }
        }
    }

    func refreshSectionDetails(_ section: DashboardSection, force: Bool = false) {
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
        case .startup:
            guard force, !isScanningLaunchItems else { return }
            isScanningLaunchItems = true
            Task.detached(priority: .utility) {
                let items = LaunchItemsScanner.scan()
                await MainActor.run {
                    launchItems = items
                    isScanningLaunchItems = false
                }
            }
        case .energy:
            if force {
                Task.detached(priority: .utility) {
                    let entries = BatteryHealthLog.shared.entries()
                    await MainActor.run { batteryHealthEntries = entries }
                }
            }
            if !isSamplingEnergy {
                isSamplingEnergy = true
                Task.detached(priority: .utility) {
                    let usage = ProcessDemandSampler.shared.appEnergyUsage()
                    await MainActor.run {
                        appEnergyUsage = usage
                        isSamplingEnergy = false
                    }
                }
            }
        default:
            break
        }
    }

    func refreshEvents() {
        Task.detached(priority: .utility) {
            let loaded = EventLog.shared.events()
            await MainActor.run { events = loaded }
        }
    }

    func loadHistory() {
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

    func requestAccessibilityPermission() {
        PrivacySettings.requestAccessibilityPrompt()
        refreshPermissionState()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    func requestInputMonitoringPermission() {
        PrivacySettings.requestInputMonitoringPrompt()
        refreshPermissionState()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    func requestCleanMode(duration: TimeInterval) {
        NotificationCenter.default.post(
            name: .cleanModeStartRequested,
            object: nil,
            userInfo: ["duration": duration]
        )
        refreshPermissionState()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    func repairCleanPermissions() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento"
        resetTCC(service: "Accessibility", bundleIdentifier: bundleIdentifier)
        resetTCC(service: "ListenEvent", bundleIdentifier: bundleIdentifier)
        statusMessage = "Permisos de limpieza restablecidos. Actívalos de nuevo en Ajustes."
        requestAccessibilityPermission()
        refreshPermissionStateAfterSystemSettingsUpdate()
    }

    func resetTCC(service: String, bundleIdentifier: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        try? process.run()
        process.waitUntilExit()
    }

    func refreshPermissionStateAfterSystemSettingsUpdate() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshPermissionState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            refreshPermissionState()
        }
    }

    func copyDiagnosticSummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticSummary(), forType: .string)
        statusMessage = "Diagnóstico copiado al portapapeles."
    }

    func exportPersistentHistory() {
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

    func exportDiagnosticSummary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "mantenimiento-diagnostico.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticSummary().write(to: url, atomically: true, encoding: .utf8)
            statusMessage = "Diagnóstico exportado."
        } catch { statusMessage = "No se pudo exportar el diagnóstico." }
    }

    func diagnosticSummary() -> String {
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

    func setFan(_ index: Int, _ rpm: Float) {
        runFanAction("Aplicando velocidad al ventilador \(index + 1)...") {
            _ = try await Task.detached { try PrivilegedFanTool.setFanRPM(index: index, rpm: rpm) }.value
            NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
            return "Ventilador \(index + 1) en manual."
        }
    }

    func setFanAuto(_ index: Int) {
        runFanAction("Aplicando automático al ventilador \(index + 1)...") {
            _ = try await Task.detached { try PrivilegedFanTool.setFanAuto(index: index) }.value
            return "Ventilador \(index + 1) en automático."
        }
    }

    func setAllFansAuto() {
        runFanAction("Aplicando automático a los ventiladores...") {
            _ = try await Task.detached { try PrivilegedFanTool.setAllFansAuto() }.value
            NotificationCenter.default.post(name: .fanAutomaticControlDidSucceed, object: nil)
            return "Ventiladores en automático."
        }
    }

    func setAllFansTurbo() {
        runFanAction("Activando turbo en todos los ventiladores...") {
            _ = try await Task.detached { try PrivilegedFanTool.setAllFansTurbo() }.value
            NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
            return "Turbo activo: ventiladores al máximo."
        }
    }

    func runFanAction(_ pendingMessage: String, operation: @escaping () async throws -> String) {
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

struct DashboardSnapshot {
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

enum DashboardSection: String, CaseIterable, Identifiable {
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
    case startup
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
        case .startup:
            return "Arranque"
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
        case .startup:
            return "power.circle"
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

struct SidebarView: View {
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
