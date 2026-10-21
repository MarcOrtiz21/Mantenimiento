import Foundation
import MantenimientoCore

enum PerformanceProfile: String, CaseIterable, Identifiable {
    case silent
    case balanced
    case turbo

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .silent:
            return "Silencioso"
        case .balanced:
            return "Equilibrado"
        case .turbo:
            return "Turbo"
        }
    }

    var symbol: String {
        switch self {
        case .silent:
            return "leaf"
        case .balanced:
            return "scale.3d"
        case .turbo:
            return "fanblades.fill"
        }
    }

    var refreshInterval: TimeInterval {
        switch self {
        case .silent:
            return 5
        case .balanced, .turbo:
            return 1.5
        }
    }
}

enum PerformanceProfileService {
    static func apply(_ profile: PerformanceProfile) async throws {
        switch profile {
        case .silent, .balanced:
            try await setFansAuto()
        case .turbo:
            try await setFansTurbo()
        }
    }

    private static func setFansAuto() async throws {
        _ = try await Task.detached(priority: .userInitiated) { try PrivilegedFanTool.setAllFansAuto() }.value
    }

    private static func setFansTurbo() async throws {
        _ = try await Task.detached(priority: .userInitiated) { try PrivilegedFanTool.setAllFansTurbo() }.value
    }
}
