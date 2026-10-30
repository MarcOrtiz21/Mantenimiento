import Foundation

/// Estima el tiempo hasta la carga completa a partir del ritmo real con el que sube el porcentaje.
/// Solo cuenta desde el primer cambio observado para no medir una fracción de punto ya empezada.
public final class ChargeRateEstimator {
    private struct Point {
        let date: Date
        let percent: Int
    }

    private struct Track {
        var lastPercent: Int
        var changes: [Point] = []
    }

    public static let maxChanges = 12
    private var tracks: [String: Track] = [:]

    public init() {}

    public func record(id: String, percent: Int, isCharging: Bool, at date: Date = Date()) {
        guard isCharging, percent < 100 else {
            tracks[id] = nil
            return
        }
        guard var track = tracks[id], percent >= track.lastPercent else {
            tracks[id] = Track(lastPercent: percent)
            return
        }
        if percent > track.lastPercent {
            track.changes.append(Point(date: date, percent: percent))
            if track.changes.count > Self.maxChanges {
                track.changes.removeFirst(track.changes.count - Self.maxChanges)
            }
            track.lastPercent = percent
        }
        tracks[id] = track
    }

    public func forget(idsNotIn ids: Set<String>) {
        tracks = tracks.filter { ids.contains($0.key) }
    }

    public func minutesToFull(id: String, target: Int = 100) -> Int? {
        guard let track = tracks[id],
              let first = track.changes.first,
              let last = track.changes.last,
              last.percent > first.percent else {
            return nil
        }
        let elapsed = last.date.timeIntervalSince(first.date)
        guard elapsed > 0 else { return nil }
        let percentPerSecond = Double(last.percent - first.percent) / elapsed
        let remaining = Double(max(target - track.lastPercent, 0))
        return Int((remaining / percentPerSecond / 60).rounded(.up))
    }
}
