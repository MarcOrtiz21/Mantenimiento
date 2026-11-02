import SwiftUI

/// Superficies del panel: Liquid Glass en macOS 26 o posterior y materiales clásicos en versiones anteriores.
/// El vidrio se reserva para la navegación y los controles; el contenido usa rellenos suaves.
extension View {
    /// Tarjeta principal (secciones, métricas).
    @ViewBuilder
    func panelSurface() -> some View {
        if #available(macOS 26, *) {
            self.background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Fila o bloque dentro de una tarjeta.
    @ViewBuilder
    func panelTile() -> some View {
        if #available(macOS 26, *) {
            self.background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            self.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// Botón solo con icono (actualizar, etc.).
    @ViewBuilder
    func glassIconButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}
