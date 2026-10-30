import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var storageSection: some View {
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

            SectionPanel(title: "Qué ocupa espacio", symbol: "chart.pie") {
                StorageUsageView(report: storageReport, isAnalyzing: isAnalyzingStorage) {
                    analyzeStorage()
                }
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

    func diskFreeTint(_ volume: VolumeSnapshot?) -> Color {
        guard let volume, volume.totalBytes > 0 else { return .secondary }
        let free = 1 - volume.usedRatio
        return free < 0.05 ? .red : free < 0.12 ? .orange : .secondary
    }

    func analyzeStorage() {
        guard !isAnalyzingStorage else { return }
        isAnalyzingStorage = true
        Task.detached(priority: .utility) {
            let report = StorageAnalyzer.analyze()
            await MainActor.run {
                storageReport = report
                isAnalyzingStorage = false
            }
        }
    }

    func ejectVolume(_ volume: VolumeSnapshot) {
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
}
