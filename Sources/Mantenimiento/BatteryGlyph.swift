import AppKit
import MantenimientoCore
import SwiftUI

/// Icono de batería con el nivel real y el rayo de carga, como el de la barra de menús del sistema.
struct BatteryGlyph: View {
    let percent: Int
    let isCharging: Bool
    let isPluggedIn: Bool
    var height: CGFloat = 14

    init(percent: Int, isCharging: Bool, isPluggedIn: Bool, height: CGFloat = 14) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.height = height
    }

    init(battery: BatterySnapshot, height: CGFloat = 14) {
        self.init(
            percent: battery.percent,
            isCharging: battery.isCharging,
            isPluggedIn: battery.externalConnected,
            height: height
        )
    }

    private var level: CGFloat {
        CGFloat(min(max(percent, 0), 100)) / 100
    }

    private var fillColor: Color {
        if isCharging || (isPluggedIn && percent >= 100) {
            return .green
        }
        if percent <= 10 {
            return .red
        }
        if percent <= 20 {
            return .orange
        }
        return .primary
    }

    var body: some View {
        let bodyWidth = height * 2.05
        let stroke = max(1, height * 0.085)
        let inset = stroke + max(1, height * 0.07)

        HStack(spacing: height * 0.06) {
            ZStack {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: stroke)

                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: height * 0.16, style: .continuous)
                        .fill(fillColor)
                        .frame(width: max(level > 0 ? height * 0.12 : 0, (bodyWidth - inset * 2) * level))
                    Spacer(minLength: 0)
                }
                .padding(inset)

                if isCharging || isPluggedIn {
                    Image(systemName: isCharging ? "bolt.fill" : "powerplug.fill")
                        .font(.system(size: height * 0.78, weight: .black))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 0.6)
                        .shadow(color: .black.opacity(0.35), radius: 1.2)
                }
            }
            .frame(width: bodyWidth, height: height)

            RoundedRectangle(cornerRadius: height * 0.06, style: .continuous)
                .fill(Color.primary.opacity(0.55))
                .frame(width: max(1.5, height * 0.12), height: height * 0.38)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Batería \(percent)%\(isCharging ? ", cargando" : isPluggedIn ? ", conectada" : "")")
    }
}

func formatBatteryMinutes(_ minutes: Int) -> String {
    let hours = minutes / 60
    let remainder = minutes % 60
    if hours == 0 {
        return "\(remainder) min"
    }
    return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
}

/// Nombre de SF Symbol equivalente para sitios que solo aceptan símbolos (barra lateral, menús).
func batterySymbolName(_ battery: BatterySnapshot?) -> String {
    guard let battery else { return "bolt" }
    if battery.isCharging || (battery.externalConnected && battery.isCharged) {
        return "battery.100percent.bolt"
    }
    switch battery.percent {
    case ..<13: return "battery.0percent"
    case ..<38: return "battery.25percent"
    case ..<63: return "battery.50percent"
    case ..<88: return "battery.75percent"
    default: return "battery.100percent"
    }
}

/// Icono real de la app (el de `AppIcon.icns`), con el dibujo vectorial como respaldo en `swift run`.
struct AppIconView: View {
    let size: CGFloat

    private static let bundleIcon: NSImage? = {
        guard Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil else { return nil }
        return NSApp.applicationIconImage
    }()

    var body: some View {
        Group {
            if let icon = Self.bundleIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "fanblades.fill")
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
    }
}
