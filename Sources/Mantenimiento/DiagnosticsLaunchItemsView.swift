import AppKit
import SwiftUI

struct LaunchItemsView: View {
    let items: [LaunchItem]?
    let isScanning: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            SectionPanel(title: "Arranque y segundo plano", symbol: "power.circle") {
                HStack(spacing: 10) {
                    if let items {
                        let running = items.filter(\.isRunning).count
                        let orphaned = items.filter(\.isOrphaned).count
                        Text("\(items.count) elementos · \(running) en ejecución" + (orphaned > 0 ? " · \(orphaned) sin programa" : ""))
                            .font(.callout)
                    } else {
                        Text(isScanning ? "Buscando…" : "Sin datos")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isScanning)
                    .help("Volver a buscar")
                    Button("Ítems de inicio…") {
                        LaunchAtLogin.openSystemSettings()
                    }
                    .help("Activar o desactivar en Ajustes del Sistema")
                }
            }

            if let items {
                ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                    let scoped = items.filter { $0.scope == scope }
                    if !scoped.isEmpty {
                        SectionPanel(title: scope.title, symbol: symbol(for: scope)) {
                            ForEach(scoped) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func symbol(for scope: LaunchItem.Scope) -> String {
        switch scope {
        case .userAgent: return "person"
        case .globalAgent: return "person.2"
        case .daemon: return "gearshape.2"
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isOrphaned ? Color.orange : item.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.vendor)
                        .font(.callout.weight(.medium))
                    ForEach(badges(item), id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(badgeColor(badge).opacity(0.18), in: Capsule())
                    }
                }
                Text(item.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.plistURL])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Mostrar el archivo en el Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(item.isOrphaned ? "El programa \(item.programPath ?? "") ya no existe; probablemente es un resto de una app desinstalada." : item.programPath ?? item.label)
    }

    private func badges(_ item: LaunchItem) -> [String] {
        var badges: [String] = []
        if item.isOrphaned { badges.append("sin programa") }
        if item.isDisabled { badges.append("desactivado") }
        if item.isRunning { badges.append("en ejecución") }
        if item.keepsAlive { badges.append("siempre activo") } else if item.runsAtLoad { badges.append("al arrancar") }
        return badges
    }

    private func badgeColor(_ badge: String) -> Color {
        switch badge {
        case "sin programa": return .orange
        case "en ejecución": return .green
        case "desactivado": return .secondary
        default: return .accentColor
        }
    }
}
