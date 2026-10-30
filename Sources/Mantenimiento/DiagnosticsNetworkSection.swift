import AppKit
import SwiftUI
import MantenimientoCore

extension DiagnosticsRootView {
    var networkSection: some View {
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

    func wifiPanel(_ wifi: WiFiDetails) -> some View {
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
}
