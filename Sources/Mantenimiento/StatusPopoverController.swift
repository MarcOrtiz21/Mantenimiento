import AppKit
import Combine
import MantenimientoCore
import SwiftUI

final class StatusPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let model = StatusPopoverModel()
    private let actions: StatusPopoverActions
    private let onClose: () -> Void
    private var measuredHeight: CGFloat = 540
    private var maximumHeight: CGFloat = 540

    var isShown: Bool {
        popover.isShown
    }

    init(actions: StatusPopoverActions, onClose: @escaping () -> Void) {
        self.actions = actions
        self.onClose = onClose
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: StatusPopoverLayout.width, height: 540)
        popover.delegate = self
        let hostingController = NSHostingController(
            rootView: StatusPopoverView(model: model, actions: actions) { [weak self] height in
                self?.resizeToContent(height)
            }
        )
        // El tamaño lo fija solo `resizeToContent`; si SwiftUI también lo propone, el popover tiembla al cambiar de sección.
        hostingController.sizingOptions = []
        popover.contentViewController = hostingController
    }

    func show(relativeTo button: NSButton, initialSection: MenuBarSection) {
        select(initialSection)
        if let window = button.window, let screen = window.screen {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            maximumHeight = max(1, min(screen.visibleFrame.height, anchor.minY - screen.visibleFrame.minY) - 16)
        } else {
            maximumHeight = max(1, (NSScreen.main?.visibleFrame.height ?? 556) - 16)
        }
        resizeToContent(measuredHeight)
        if popover.isShown {
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Sin esto AppKit enfoca el primer botón y lo rodea con el anillo azul al abrir.
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private func resizeToContent(_ height: CGFloat) {
        measuredHeight = height
        let preferredHeight = StatusPopoverLayout.height(contentHeight: height, availableHeight: maximumHeight)
        let needsScroll = ceil(height) > preferredHeight + 1
        if model.needsScroll != needsScroll {
            model.needsScroll = needsScroll
        }
        guard abs(model.preferredHeight - preferredHeight) >= 1 else { return }
        model.preferredHeight = preferredHeight
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = NSSize(width: StatusPopoverLayout.width, height: preferredHeight)
        popover.animates = animates
    }

    func close() {
        popover.performClose(nil)
    }

    func select(_ section: MenuBarSection) {
        model.selectedSection = section
    }

    func update(
        snapshot: MenuBarSnapshot?,
        selectedSection: MenuBarSection,
        detailRows: [MenuInfoLine],
        demandRows: [MenuInfoLine],
        isDemandHidden: Bool,
        isDemandLoading: Bool,
        isRefreshing: Bool,
        isCleaning: Bool,
        activeProfile: PerformanceProfile,
        isApplyingProfile: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        model.snapshot = snapshot
        model.selectedSection = selectedSection
        model.detailRows = detailRows
        model.demandRows = demandRows
        model.isDemandHidden = isDemandHidden
        model.isDemandLoading = isDemandLoading
        model.isRefreshing = isRefreshing
        model.isCleaning = isCleaning
        model.activeProfile = activeProfile
        model.isApplyingProfile = isApplyingProfile
        model.enabledSections = AppPreferences.enabledMenuBarSections
    }

    func popoverDidClose(_ notification: Notification) {
        onClose()
    }
}

struct StatusPopoverActions {
    let selectSection: (MenuBarSection) -> Void
    let refresh: () -> Void
    let openPanel: (MenuBarSection) -> Void
    let openPreferences: () -> Void
    let applyProfile: (PerformanceProfile) -> Void
    let startClean: (TimeInterval) -> Void
    let stopClean: () -> Void
    let turboFans: () -> Void
    let autoFans: () -> Void
    let quit: () -> Void
}

final class StatusPopoverModel: ObservableObject {
    @Published var preferredHeight: CGFloat = 540
    @Published var needsScroll = false
    @Published var snapshot: MenuBarSnapshot?
    @Published var selectedSection: MenuBarSection = .overview
    @Published var detailRows: [MenuInfoLine] = [MenuInfoLine(title: "Estado", value: "Calculando...")]
    @Published var demandRows: [MenuInfoLine] = []
    @Published var isDemandHidden = true
    @Published var isDemandLoading = false
    @Published var isRefreshing = false
    @Published var isCleaning = false
    @Published var activeProfile: PerformanceProfile = .balanced
    @Published var isApplyingProfile = false
    @Published var enabledSections: [MenuBarSection] = AppPreferences.enabledMenuBarSections
}

private struct StatusPopoverView: View {
    @ObservedObject var model: StatusPopoverModel
    let actions: StatusPopoverActions
    let onContentHeightChange: (CGFloat) -> Void
    @Namespace private var selectorNamespace

    private var history: MenuBarSparklineHistory { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(heightMeasurement)

            ScrollView {
                VStack(spacing: 10) {
                    summaryGrid
                    if let battery = model.snapshot?.telemetry.battery {
                        PopoverEnergyTile(
                            battery: battery,
                            devices: model.snapshot?.telemetry.usbDevices ?? [],
                            wattsHistory: history.values(\.systemWatts)
                        )
                    }
                    if let snapshot = model.snapshot {
                        if !snapshot.sensorStatus.isCurrent {
                            Label("Sensores: \(snapshot.sensorStatus.description)", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help(snapshot.sensorStatus.error ?? "")
                        }
                        if !snapshot.fanStatus.isCurrent {
                            Label("Ventiladores: \(snapshot.fanStatus.description)", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .help(snapshot.fanStatus.error ?? "")
                        }
                    }
                    warningsSection
                    sectionSelector
                    detailSection
                    demandSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightMeasurement)
            }
            .scrollIndicators(model.needsScroll ? .automatic : .never)
            .scrollDisabled(!model.needsScroll)

            footer
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .popoverBarBackground()
                .background(heightMeasurement)
        }
        .frame(width: StatusPopoverLayout.width, height: model.preferredHeight)
        .popoverRootBackground()
        .popoverFocusEffectDisabled()
        .onPreferenceChange(PopoverContentHeightKey.self, perform: onContentHeightChange)
    }

    private var heightMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PopoverContentHeightKey.self, value: geometry.size.height)
        }
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(spacing: 10) {
            PopoverAppMark(size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isCleaning ? "Modo Limpieza activo" : "Mantenimiento")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                actions.refresh()
            } label: {
                Image(systemName: model.isRefreshing ? "clock.arrow.circlepath" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .popoverIconButtonStyle()
            .focusable(false)
            .help("Actualizar ahora")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .popoverBarBackground()
    }

    private var headerSubtitle: String {
        guard let snapshot = model.snapshot else {
            return "Calculando telemetria..."
        }

        let appCost = snapshot.appResources.cpuRatio.map(popoverPercent) ?? "..."
        return "\(snapshot.thermalState) | App \(appCost), \(popoverBytes(snapshot.appResources.residentMemoryBytes))"
    }

    // MARK: Tarjetas

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            PopoverMetricTile(
                title: "CPU",
                value: model.snapshot?.cpuUsage.map(popoverPercent) ?? "--",
                detail: popoverTemperature(model.snapshot?.cpuTemperature),
                symbol: "cpu",
                tint: .blue,
                series: [history.values(\.cpu)],
                range: 0...1
            )
            PopoverMetricTile(
                title: "GPU",
                value: model.snapshot?.telemetry.gpu?.utilizationRatio.map(popoverPercent) ?? "--",
                detail: popoverTemperature(model.snapshot?.gpuTemperature),
                symbol: "square.stack.3d.up.fill",
                tint: .purple,
                series: [history.values(\.gpu)],
                range: 0...1
            )
            PopoverMetricTile(
                title: "RAM",
                value: model.snapshot.flatMap { $0.telemetry.memory.isAvailable ? popoverPercent($0.telemetry.memory.usedRatio) : nil } ?? "--",
                detail: model.snapshot?.telemetry.memory.pressureDescription ?? "sin datos",
                symbol: "memorychip",
                tint: .green,
                series: [history.values(\.memory)],
                range: 0...1
            )
            PopoverNetworkTile(
                up: model.snapshot?.networkUpBps,
                down: model.snapshot?.networkDownBps,
                upHistory: history.values(\.networkUp),
                downHistory: history.values(\.networkDown)
            )
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if let snapshot = model.snapshot {
            let warnings = MaintenanceAlertEvaluator.alerts(for: snapshot)
            if !warnings.isEmpty {
                PopoverPanel(title: "Avisos", symbol: "exclamationmark.triangle") {
                    VStack(spacing: 0) {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(warning.severity.popoverTint)
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(warning.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(warning.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 30)

                            if index < warnings.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Secciones

    private var sectionSelector: some View {
        HStack(spacing: 2) {
            ForEach([MenuBarSection.overview] + model.enabledSections) { section in
                let isSelected = model.selectedSection == section
                Button {
                    actions.selectSection(section)
                } label: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.2))
                                    .matchedGeometryEffect(id: "selection", in: selectorNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(section.title)
            }
        }
        .padding(3)
        .popoverSelectorBackground()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.selectedSection)
    }

    private var detailSection: some View {
        PopoverPanel(title: model.selectedSection.title, symbol: model.selectedSection.symbol) {
            VStack(spacing: 0) {
                ForEach(Array(model.detailRows.prefix(8).enumerated()), id: \.offset) { index, row in
                    PopoverInfoRow(row: row)
                    if index < min(model.detailRows.count, 8) - 1 {
                        Divider()
                            .padding(.leading, 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var demandSection: some View {
        if !model.isDemandHidden {
            PopoverPanel(title: demandTitle, symbol: "list.bullet.rectangle") {
                VStack(spacing: 6) {
                    ForEach(Array(model.demandRows.prefix(6).enumerated()), id: \.offset) { _, row in
                        if row.fraction == nil {
                            PopoverInfoRow(row: row)
                        } else {
                            PopoverDemandRow(row: row, tint: demandTint)
                        }
                    }
                }
            }
        }
    }

    private var demandTint: Color {
        switch model.selectedSection {
        case .cpu: return .blue
        case .gpu: return .purple
        case .memory: return .green
        case .network: return .cyan
        case .overview, .battery: return .accentColor
        }
    }

    private var demandTitle: String {
        let title: String
        switch model.selectedSection {
        case .network: title = "Mayor demanda · TCP"
        case .gpu: title = "Mayor demanda · estimación GPU"
        default: title = "Mayor demanda"
        }
        return model.isDemandLoading ? title + " · actualizando" : title
    }

    // MARK: Acciones

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "fanblades")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Refrigeración")

                Picker("Perfil", selection: Binding(
                    get: { model.activeProfile },
                    set: { actions.applyProfile($0) }
                )) {
                    ForEach(PerformanceProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(model.isApplyingProfile)
                .focusable(false)

                if model.isApplyingProfile {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    actions.autoFans()
                } label: {
                    Text("Auto")
                }
                .popoverActionButtonStyle()
                .focusable(false)
                .help("Devolver los ventiladores a automático")

                Button {
                    actions.turboFans()
                } label: {
                    Label("Turbo", systemImage: "wind")
                }
                .popoverActionButtonStyle()
                .focusable(false)
                .help("Ventiladores al máximo")
            }

            HStack(spacing: 8) {
                if model.isCleaning {
                    Button {
                        actions.stopClean()
                    } label: {
                        Label("Desbloquear", systemImage: "lock.open")
                    }
                    .popoverActionButtonStyle()
                    .focusable(false)
                } else {
                    Menu {
                        ForEach(cleanDurations, id: \.seconds) { duration in
                            Button(duration.title) {
                                actions.startClean(duration.seconds)
                            }
                        }
                    } label: {
                        Label("Limpieza", systemImage: "hand.raised")
                    }
                    .menuStyle(.button)
                    .popoverActionButtonStyle()
                    .fixedSize()
                    .focusable(false)
                    .help("Bloquear teclado y trackpad para limpiar el Mac")
                }

                Spacer(minLength: 0)

                Button {
                    actions.openPanel(model.selectedSection)
                } label: {
                    Label("Abrir panel", systemImage: "macwindow")
                }
                .popoverActionButtonStyle()
                .focusable(false)

                Button {
                    actions.openPreferences()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 16)
                }
                .popoverActionButtonStyle()
                .focusable(false)
                .help("Preferencias")

                Button {
                    actions.quit()
                } label: {
                    Image(systemName: "power")
                        .frame(width: 16)
                }
                .popoverActionButtonStyle()
                .focusable(false)
                .help("Salir")
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Tarjetas

private struct PopoverMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    let series: [[Double]]
    let range: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
            PopoverSparkline(series: series, colors: [tint], range: range)
                .frame(height: 20)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .popoverCard()
    }
}

private struct PopoverNetworkTile: View {
    let up: Double?
    let down: Double?
    let upHistory: [Double]
    let downHistory: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "network")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("Red")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                NetworkLine(color: .red, symbol: "arrow.down", value: down.map(popoverRate) ?? "--")
                NetworkLine(color: .green, symbol: "arrow.up", value: up.map(popoverRate) ?? "--")
            }
            .frame(minHeight: 23)
            PopoverSparkline(series: [downHistory, upHistory], colors: [.red, .green], range: nil)
                .frame(height: 20)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .popoverCard()
    }
}

private struct NetworkLine: View {
    let color: Color
    let symbol: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct PopoverEnergyTile: View {
    let battery: BatterySnapshot
    let devices: [USBPowerDevice]
    let wattsHistory: [Double]

    private struct PoweredDevice: Identifiable {
        let id: Int
        let name: String
        let percent: Int?
        let minutesToFull: Int?
    }

    private var poweredDevices: [PoweredDevice] {
        var remaining = devices
        return battery.ports.filter { $0.role == .poweringDevice }.map { port in
            let match = remaining.firstIndex { $0.vendorID != nil && $0.vendorID == port.deviceVendorID }
            let device = match.map { remaining.remove(at: $0) }
            return PoweredDevice(
                id: port.index,
                name: device?.name ?? "Dispositivo USB-C",
                percent: port.deviceBatteryPercent,
                minutesToFull: ChargeRateEstimator.shared.minutesToFull(id: ChargeRateEstimator.portID(port.index))
            )
        }
    }

    private var status: String {
        if battery.isCharged || (battery.externalConnected && battery.percent >= 100) {
            return "Cargada"
        }
        if battery.isCharging {
            let minutes = battery.timeToFullMinutes ?? ChargeRateEstimator.shared.minutesToFull(id: ChargeRateEstimator.macID)
            return minutes.map { "Cargando · llena en \(formatBatteryMinutes($0))" } ?? "Cargando"
        }
        if battery.externalConnected {
            return "Conectada · carga en pausa"
        }
        return battery.timeToEmptyMinutes.map { "Quedan \(formatBatteryMinutes($0))" } ?? "Con batería"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                BatteryGlyph(battery: battery, height: 15)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(battery.percent)%")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                PopoverSparkline(series: [wattsHistory], colors: [.orange], range: nil)
                    .frame(width: 96, height: 26)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(battery.systemLoadWatts.map { String(format: "%.1f W", $0) } ?? "--")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(battery.adapter?.watts.map { "cargador \($0) W" } ?? "consumo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 62, alignment: .trailing)
            }

            ForEach(poweredDevices) { device in
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: deviceSymbol(device.name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 16)
                    Text(device.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let minutes = device.minutesToFull, (device.percent ?? 0) < 100 {
                        Text("≈ \(formatBatteryMinutes(minutes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let percent = device.percent {
                        BatteryGlyph(percent: percent, isCharging: percent < 100, isPluggedIn: true, height: 10)
                        Text("\(percent)%")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .popoverCard()
    }

    private func deviceSymbol(_ name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("ipad") { return "ipad" }
        if lowered.contains("iphone") { return "iphone" }
        if lowered.contains("watch") { return "applewatch" }
        if lowered.contains("airpods") { return "airpodspro" }
        return "cable.connector"
    }
}

/// Mini gráfica de los últimos minutos; la primera serie lleva relleno degradado.
private struct PopoverSparkline: View {
    let series: [[Double]]
    let colors: [Color]
    let range: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let bounds = valueBounds
            ZStack {
                if let first = series.first, first.count > 1 {
                    areaPath(first, in: geometry.size, bounds: bounds)
                        .fill(LinearGradient(
                            colors: [color(0).opacity(0.28), color(0).opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                }
                ForEach(Array(series.enumerated()), id: \.offset) { index, values in
                    if values.count > 1 {
                        linePath(values, in: geometry.size, bounds: bounds)
                            .stroke(color(index), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    }
                }
                if series.allSatisfy({ $0.count < 2 }) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geometry.size.height - 1))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height - 1))
                    }
                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func color(_ index: Int) -> Color {
        colors.isEmpty ? .accentColor : colors[min(index, colors.count - 1)]
    }

    private var valueBounds: ClosedRange<Double> {
        if let range { return range }
        let peak = series.flatMap { $0 }.max() ?? 0
        return 0...max(peak * 1.1, 0.000_1)
    }

    private func points(_ values: [Double], in size: CGSize, bounds: ClosedRange<Double>) -> [CGPoint] {
        let span = max(bounds.upperBound - bounds.lowerBound, 0.000_1)
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            let normalized = min(max((value - bounds.lowerBound) / span, 0), 1)
            return CGPoint(x: CGFloat(index) * step, y: 1 + (size.height - 2) * (1 - CGFloat(normalized)))
        }
    }

    private func linePath(_ values: [Double], in size: CGSize, bounds: ClosedRange<Double>) -> Path {
        Path { path in
            path.addLines(points(values, in: size, bounds: bounds))
        }
    }

    private func areaPath(_ values: [Double], in size: CGSize, bounds: ClosedRange<Double>) -> Path {
        Path { path in
            let line = points(values, in: size, bounds: bounds)
            guard let first = line.first, let last = line.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            path.addLines(line)
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}

// MARK: - Paneles y filas

private struct PopoverPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .popoverCard()
    }
}

private struct PopoverInfoRow: View {
    let row: MenuInfoLine

    var body: some View {
        HStack(spacing: 12) {
            Text(row.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(row.title)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .help(row.value)
        }
        .frame(minHeight: 25)
    }
}

private struct PopoverDemandRow: View {
    let row: MenuInfoLine
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.title)
                    Spacer(minLength: 6)
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule()
                            .fill(tint.gradient)
                            .frame(width: max(3, geometry.size.width * CGFloat(row.fraction ?? 0)))
                    }
                }
                .frame(height: 3)
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = row.appPath {
            Image(nsImage: AppNetworkUsageList.cachedIcon(path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Estilo (Liquid Glass en macOS 26 o posterior)

private extension View {
    @ViewBuilder
    func popoverRootBackground() -> some View {
        if #available(macOS 26, *) {
            self
        } else {
            self.background(.regularMaterial)
        }
    }

    @ViewBuilder
    func popoverBarBackground() -> some View {
        if #available(macOS 26, *) {
            self
        } else {
            self.background(.bar)
        }
    }

    @ViewBuilder
    func popoverCard() -> some View {
        if #available(macOS 26, *) {
            self.background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            self
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    func popoverSelectorBackground() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            self
                .background(.thinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1))
        }
    }

    @ViewBuilder
    func popoverActionButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func popoverIconButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            self.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func popoverFocusEffectDisabled() -> some View {
        if #available(macOS 14, *) {
            self.focusEffectDisabled()
        } else {
            self
        }
    }
}

enum StatusPopoverLayout {
    static let width: CGFloat = 430

    static func height(contentHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(ceil(max(180, contentHeight)), max(1, availableHeight))
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

struct PopoverAppMark: View {
    let size: CGFloat

    var body: some View {
        AppIconView(size: size)
    }
}

private let cleanDurations: [(title: String, seconds: TimeInterval)] = [
    ("1 minuto", 60),
    ("2 minutos", 120),
    ("5 minutos", 300)
]

private extension MaintenanceAlertSeverity {
    var popoverTint: Color {
        switch self {
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

private func popoverPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func popoverTemperature(_ value: Double?) -> String {
    guard let value else {
        return "sin temp"
    }
    return "\(Int(value.rounded())) °C"
}

private func popoverBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.popoverStorage.string(fromByteCount: Int64(bytes))
}

private func popoverRate(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded())) B/s"
}

private extension ByteCountFormatter {
    static var popoverStorage: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }
}
