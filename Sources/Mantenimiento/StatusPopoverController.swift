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
        popover.contentSize = NSSize(width: 430, height: 540)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(model: model, actions: actions) { [weak self] height in
                self?.resizeToContent(height)
            }
        )
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
    }

    private func resizeToContent(_ height: CGFloat) {
        measuredHeight = height
        let preferredHeight = StatusPopoverLayout.height(contentHeight: height, availableHeight: maximumHeight)
        guard abs(model.preferredHeight - preferredHeight) >= 1 else { return }
        model.preferredHeight = preferredHeight
        popover.contentSize = NSSize(width: 430, height: preferredHeight)
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

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(heightMeasurement)

            ScrollView {
                VStack(spacing: 12) {
                    summaryGrid
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
                .padding(14)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightMeasurement)
            }
            .scrollIndicators(.visible)
            quickActions
                .padding(14)
                .background(.bar)
                .background(heightMeasurement)
        }
        .frame(width: 430, height: model.preferredHeight)
        .background(.regularMaterial)
        .onPreferenceChange(PopoverContentHeightKey.self, perform: onContentHeightChange)
    }

    private var heightMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PopoverContentHeightKey.self, value: geometry.size.height)
        }
    }

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
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Actualizar ahora")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            PopoverMetricTile(
                title: "CPU",
                value: model.snapshot?.cpuUsage.map(popoverPercent) ?? "--",
                detail: popoverTemperature(model.snapshot?.cpuTemperature),
                symbol: "cpu",
                tint: .blue
            )
            PopoverMetricTile(
                title: "GPU",
                value: model.snapshot?.telemetry.gpu?.utilizationRatio.map(popoverPercent) ?? "--",
                detail: popoverTemperature(model.snapshot?.gpuTemperature),
                symbol: "square.stack.3d.up.fill",
                tint: .purple
            )
            PopoverMetricTile(
                title: "RAM",
                value: model.snapshot.flatMap { $0.telemetry.memory.isAvailable ? popoverPercent($0.telemetry.memory.usedRatio) : nil } ?? "--",
                detail: model.snapshot?.telemetry.memory.pressureDescription ?? "sin datos",
                symbol: "memorychip",
                tint: .green
            )
            PopoverNetworkTile(
                up: model.snapshot?.networkUpBps,
                down: model.snapshot?.networkDownBps
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

    private var sectionSelector: some View {
        HStack(spacing: 6) {
            ForEach([MenuBarSection.overview] + model.enabledSections) { section in
                Button {
                    actions.selectSection(section)
                } label: {
                    Label(section.title, systemImage: section.symbol)
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(PopoverSectionButtonStyle(isSelected: model.selectedSection == section))
                .help(section.title)
            }
        }
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
            PopoverPanel(
                title: demandTitle,
                symbol: "list.bullet.rectangle"
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(model.demandRows.prefix(6).enumerated()), id: \.offset) { index, row in
                        PopoverInfoRow(row: row)
                        if index < min(model.demandRows.count, 6) - 1 {
                            Divider()
                                .padding(.leading, 2)
                        }
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Perfil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

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

                if model.isApplyingProfile {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Button {
                    actions.openPanel(model.selectedSection)
                } label: {
                    Label("Panel", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    actions.openPreferences()
                } label: {
                    Label("Prefs", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    actions.turboFans()
                } label: {
                    Label("Turbo", systemImage: "fanblades")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    actions.autoFans()
                } label: {
                    Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
            }

            HStack(spacing: 8) {
                if model.isCleaning {
                    Button {
                        actions.stopClean()
                    } label: {
                        Label("Desbloquear", systemImage: "lock.open")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(cleanDurations, id: \.seconds) { duration in
                        Button {
                            actions.startClean(duration.seconds)
                        } label: {
                            Label(duration.title, systemImage: "lock")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Button(role: .destructive) {
                    actions.quit()
                } label: {
                    Image(systemName: "power")
                        .frame(width: 30)
                }
                .help("Salir")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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

    private var headerSubtitle: String {
        guard let snapshot = model.snapshot else {
            return "Calculando telemetria..."
        }

        let appCost = snapshot.appResources.cpuRatio.map(popoverPercent) ?? "..."
        return "\(snapshot.thermalState) | App \(appCost), \(popoverBytes(snapshot.appResources.residentMemoryBytes))"
    }
}

private struct PopoverMetricTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}

private struct PopoverNetworkTile: View {
    let up: Double?
    let down: Double?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "network")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text("Red")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    NetworkLine(color: .green, title: "Up", value: up.map(popoverRate) ?? "--")
                    NetworkLine(color: .red, title: "Down", value: down.map(popoverRate) ?? "--")
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}

private struct NetworkLine: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct PopoverPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
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

enum StatusPopoverLayout {
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

private struct PopoverSectionButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.25), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct PopoverAppMark: View {
    let size: CGFloat

    var body: some View {
        AppIconView(size: size)
    }
}

private let cleanDurations: [(title: String, seconds: TimeInterval)] = [
    ("1 min", 60),
    ("2 min", 120),
    ("5 min", 300)
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
    return "\(Int(value.rounded())) C"
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
