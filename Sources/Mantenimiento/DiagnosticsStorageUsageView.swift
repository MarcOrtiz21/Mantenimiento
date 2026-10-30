import AppKit
import SwiftUI

struct StorageUsageView: View {
    let report: StorageReport?
    let isAnalyzing: Bool
    let onAnalyze: () -> Void

    private static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    onAnalyze()
                } label: {
                    Label(report == nil ? "Analizar" : "Volver a analizar", systemImage: "magnifyingglass")
                }
                .disabled(isAnalyzing)
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analizando carpetas…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let report {
                    Text("\(formatBytes(report.measuredBytes)) en estas carpetas · \(report.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if report == nil && !isAnalyzing {
                Text("Solo mide; nunca borra nada. macOS puede pedir permiso para leer Descargas u otras carpetas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let report {
                ForEach(report.categories.filter { $0.access != .missing }.sorted { $0.sizeBytes > $1.sizeBytes }) { category in
                    categoryRow(category)
                }

                if let snapshots = report.localSnapshotCount, snapshots > 0 {
                    infoLine(
                        symbol: "clock.arrow.circlepath",
                        title: "Instantáneas locales de Time Machine",
                        detail: "\(snapshots) guardadas. macOS las elimina solo cuando necesita espacio."
                    )
                }

                if !report.largeFiles.isEmpty {
                    Text("Archivos grandes en Descargas")
                        .font(.callout.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(report.largeFiles) { file in
                        largeFileRow(file)
                    }
                }

                if report.categories.contains(where: { $0.access == .denied }) {
                    HStack {
                        Text("Algunas carpetas requieren Acceso total al disco.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Abrir Privacidad") {
                            if let url = Self.fullDiskAccessURL {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func categoryRow(_ category: StorageCategory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: category.symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .font(.callout.weight(.medium))
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(sizeText(category))
                .font(.system(.callout, design: .rounded).monospacedDigit())
                .foregroundStyle(category.access == .denied ? .secondary : .primary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([category.url])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Mostrar en el Finder")
            .disabled(category.access == .denied)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func largeFileRow(_ file: LargeFile) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let modified = file.modified {
                    Text("Modificado \(modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(formatBytes(file.sizeBytes))
                .font(.system(.callout, design: .rounded).monospacedDigit())
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.borderless)
            .help("Mostrar en el Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func infoLine(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sizeText(_ category: StorageCategory) -> String {
        switch category.access {
        case .denied: return "sin permiso"
        case .partial: return "≥ \(formatBytes(category.sizeBytes))"
        case .measured, .missing: return formatBytes(category.sizeBytes)
        }
    }
}
