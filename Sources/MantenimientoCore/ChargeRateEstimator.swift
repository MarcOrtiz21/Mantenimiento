import Foundation

/// Estima el tiempo hasta la carga completa a partir del ritmo real con el que sube el nivel.
/// El nivel puede ser un porcentaje o, mejor, una capacidad con más resolución (mAh, unidades del gauge).
/// Solo cuenta desde el primer cambio observado para no medir una fracción de unidad ya empezada.
public final class ChargeRateEstimator {
    private struct Point {
        let date: Date
        let level: Int
    }

    private struct Track {
        var full: Int
        var lastLevel: Int
        var changes: [Point] = []
    }

    public static let maxChanges = 20
    private var tracks: [String: Track] = [:]

    public init() {}

    public func record(id: String, level: Int, full: Int, isCharging: Bool, at date: Date = Date()) {
        guard isCharging, full > 0, level < full else {
            tracks[id] = nil
            return
        }
        guard var track = tracks[id], track.full == full, level >= track.lastLevel else {
            tracks[id] = Track(full: full, lastLevel: level)
            return
        }
        if level > track.lastLevel {
            track.changes.append(Point(date: date, level: level))
            if track.changes.count > Self.maxChanges {
                track.changes.removeFirst(track.changes.count - Self.maxChanges)
            }
            track.lastLevel = level
        }
        tracks[id] = track
    }

    public func forget(idsNotIn ids: Set<String>) {
        tracks = tracks.filter { ids.contains($0.key) }
    }

    public func minutesToFull(id: String) -> Int? {
        guard let track = tracks[id],
              let first = track.changes.first,
              let last = track.changes.last,
              last.level > first.level else {
            return nil
        }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed > 0 else { return nil }
        let levelPerSecond = Double(last.level - first.level) / elapsed
        let remaining = Double(max(track.full - track.lastLevel, 0))
        return Int((remaining / levelPerSecond / 60).rounded(.up))
    }
}
