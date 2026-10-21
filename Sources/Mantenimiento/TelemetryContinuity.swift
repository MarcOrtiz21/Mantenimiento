import Foundation

enum TelemetryContinuity {
    // La frecuencia normal más lenta es 8 s; una pausa mayor no es una muestra continua.
    static let maximumSampleGap: TimeInterval = 20

    static func isContinuous(from earlier: Date?, to later: Date) -> Bool {
        guard let earlier else { return false }
        let interval = later.timeIntervalSince(earlier)
        return interval > 0 && interval <= maximumSampleGap
    }
}
