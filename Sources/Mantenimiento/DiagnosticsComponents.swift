import AppKit
import Charts
import SwiftUI
import MantenimientoCore

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        AppIconView(size: size)
    }
}

struct MetricView: View {
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

struct BatteryMetricView: View {
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

struct MaintenanceReviewPanel: View {
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

struct EventTimelineView: View {
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

struct NetworkMetricView: View {
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

struct PermissionBadge: View {
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

struct HealthStatusRow: View {
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

struct SectionPanel<Content: View>: View {
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

func shortProcessName(_ name: String) -> String {
    let token = name.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? name
    let last = URL(fileURLWithPath: token).lastPathComponent
    return last.isEmpty ? name : last
}

struct SparklineChartView: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let points: TelemetryChartData
    var footnote: String? = nil

    private var domain: ClosedRange<Double> {
        Self.domain(for: points.points.map(\.value))
    }

    static func domain(for rawValues: [Double]) -> ClosedRange<Double> {
        let values = rawValues.filter(\.isFinite)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...1
        }

        let padding = max((maxValue - minValue) * 0.18, max(max(abs(maxValue), abs(minValue)) * 0.08, 1))
        let lower = minValue >= 0 ? max(0, minValue - padding) : minValue - padding
        let upper = maxValue <= 0 && minValue < 0 ? min(0, maxValue + padding) : maxValue + padding
        return lower...max(upper, lower + 1)
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

struct ResponsiveChartGrid: View {
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

struct CPUCoreUsageGridView: View {
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

struct NetworkInterfaceDetailList: View {
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

struct AppNetworkUsageList: View {
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

    static func cachedIcon(_ path: String) -> NSImage {
        if let icon = iconCache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }
}

struct VolumeUsageBar: View {
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

struct VolumeRowView: View {
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

func localizedSMARTStatus(_ status: String) -> String {
    switch status {
    case "Verified": return "Correcto"
    case "Failing": return "Fallando"
    case "Not Supported": return "No disponible"
    default: return status
    }
}

func latencyTint(_ milliseconds: Double?) -> Color {
    guard let milliseconds else { return .secondary }
    if milliseconds >= 150 { return .red }
    if milliseconds >= 60 { return .orange }
    return .green
}

func wifiSignalSymbol(_ rssi: Int?) -> String {
    guard let rssi else { return "wifi" }
    return rssi >= -72 ? "wifi" : "wifi.exclamationmark"
}

func wifiSignalTint(_ rssi: Int?) -> Color {
    guard let rssi else { return .secondary }
    if rssi >= -60 { return .green }
    if rssi >= -72 { return .yellow }
    return .orange
}

struct GPUDemandListView: View {
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

struct GlobalFanControlView: View {
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

struct FanRowView: View {
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

struct ModeBadge: View {
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

struct SensorGroupView: View {
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

struct InfoRow: View {
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

struct EmptyStateView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }
}

struct VisualEffect: NSViewRepresentable {
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
