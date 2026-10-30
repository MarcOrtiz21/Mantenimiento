import MantenimientoCore

extension ChargeRateEstimator {
    static let shared = ChargeRateEstimator()
    static let macID = "mac"

    static func portID(_ index: Int) -> String {
        "port-\(index)"
    }
}
