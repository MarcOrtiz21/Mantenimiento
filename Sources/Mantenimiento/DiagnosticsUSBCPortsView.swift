import SwiftUI
import MantenimientoCore

struct USBCPortsView: View {
    let ports: [USBCPortSnapshot]
    let devices: [USBPowerDevice]
    let adapter: PowerAdapterSnapshot?

    private struct PoweredRow: Identifiable {
        let id: String
        let name: String
        let allocatedWatts: Double?
        let batteryPercent: Int?
    }

    private var chargers: [USBCPortSnapshot] { ports.filter { $0.role == .charger } }

    /// Empareja los puertos que alimentan algo con los dispositivos USB del mismo fabricante.
    private var poweredRows: [PoweredRow] {
        var remaining = devices
        var rows: [PoweredRow] = []
        for port in ports where port.role == .poweringDevice {
            let match = remaining.firstIndex { $0.vendorID != nil && $0.vendorID == port.deviceVendorID }
            let device = match.map { remaining.remove(at: $0) }
            rows.append(PoweredRow(
                id: "port-\(port.index)",
                name: device?.name ?? "Dispositivo en el puerto \(port.index + 1)",
                allocatedWatts: device?.allocatedWatts,
                batteryPercent: port.deviceBatteryPercent
            ))
        }
        for device in remaining where device.allocatedMilliamps >= 500 {
            rows.append(PoweredRow(id: "usb-\(device.locationID)", name: device.name, allocatedWatts: device.allocatedWatts, batteryPercent: nil))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if chargers.isEmpty && poweredRows.isEmpty {
                EmptyStateView(message: "No hay cargadores ni dispositivos recibiendo corriente.")
            }
            ForEach(chargers) { port in
                chargerRow(port)
            }
            ForEach(poweredRows) { row in
                poweredRow(row)
            }
        }
    }

    private func chargerRow(_ port: USBCPortSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "powerplug.fill")
                .foregroundStyle(.green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(adapter?.name ?? "Cargador del Mac")
                    .font(.callout.weight(.medium))
                Text(offeredDescription(port))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let voltage = port.contractVoltageMillivolts ?? adapter?.voltageMillivolts,
               let current = port.contractCurrentMilliamps ?? adapter?.currentMilliamps {
                Text("\(volts(voltage)) × \(String(format: "%.2f", Double(current) / 1_000)) A")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f W", Double(voltage) * Double(current) / 1_000_000))
                    .fontWeight(.semibold)
                    .frame(minWidth: 64, alignment: .trailing)
            } else if let maxPower = port.maxPowerMilliwatts {
                Text(String(format: "%.1f W", Double(maxPower) / 1_000))
                    .fontWeight(.semibold)
            }
        }
        .font(.system(.callout, design: .rounded).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Contrato USB Power Delivery negociado entre el Mac y el cargador")
    }

    private func poweredRow(_ row: PoweredRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: row.name))
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                Text("El Mac le da corriente")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let percent = row.batteryPercent {
                Label("\(percent)%", systemImage: "battery.100percent.bolt")
                    .foregroundStyle(.secondary)
            }
            if let watts = row.allocatedWatts {
                Text(String(format: "hasta %.0f W", watts))
                    .fontWeight(.semibold)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
        .font(.system(.callout, design: .rounded).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Potencia reservada por el Mac a 5 V; el consumo real por puerto no está disponible")
    }

    private func offeredDescription(_ port: USBCPortSnapshot) -> String {
        let voltages = port.offeredVoltagesMillivolts.map(volts)
        return voltages.isEmpty ? "Conectado" : "Ofrece " + voltages.joined(separator: " · ")
    }

    private func volts(_ millivolts: Int) -> String {
        millivolts % 1_000 == 0 ? "\(millivolts / 1_000) V" : String(format: "%.1f V", Double(millivolts) / 1_000)
    }

    private func symbol(for name: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("ipad") { return "ipad" }
        if lowered.contains("iphone") { return "iphone" }
        if lowered.contains("watch") { return "applewatch" }
        if lowered.contains("airpods") { return "airpodspro" }
        return "cable.connector"
    }
}
