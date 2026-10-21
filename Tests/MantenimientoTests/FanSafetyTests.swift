import Foundation
import Testing
@testable import MantenimientoCore

final class SimulatedSMC: SMCTransport {
    var values: [String: [UInt8]] = ["FNum": [2], "Ftst": [0], "F0md": [0], "F1md": [0]]
    var rejectedTarget: String?
    var rejectManual = false
    var rejectAuto = false
    var autoReadDelays: [String: Int] = [:]
    var ignoredWrites: Set<String> = []
    var systemModeAfterAuto = false
    private var pendingValues: [String: (value: [UInt8], remainingReads: Int)] = [:]
    var writes: [String] = []

    init() {
        for index in 0..<2 {
            for (suffix, value) in [("Ac", Float(2000)), ("Tg", 2000), ("Mn", 1200), ("Mx", 6000)] {
                values["F\(index)\(suffix)"] = SMCDataFormat.bytes(from: value, size: 4)
            }
        }
    }

    func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
        if let pending = pendingValues[key] {
            if pending.remainingReads == 0 {
                values[key] = pending.value
                pendingValues.removeValue(forKey: key)
            } else {
                pendingValues[key] = (pending.value, pending.remainingReads - 1)
            }
        }
        guard let value = values[key] else { throw SMCError.firmware(.notFound) }
        return (value, UInt32(value.count))
    }

    func writeKey(_ key: String, bytes: [UInt8]) throws {
        writes.append(key)
        if key == rejectedTarget || (key.hasSuffix("md") && ((rejectManual && bytes == [1]) || (rejectAuto && bytes == [0]))) {
            throw SMCError.firmware(.notWritable)
        }
        guard !ignoredWrites.contains(key) else { return }
        let value = systemModeAfterAuto && key.hasSuffix("md") && bytes == [0] ? [UInt8(3)] : bytes
        if bytes == [0], let delay = autoReadDelays[key] {
            pendingValues[key] = (value, delay)
        } else {
            values[key] = value
        }
    }

    func fetchKeyInfo(_ key: String) throws -> (param: SMCParamStruct, output: SMCParamStruct) {
        let value = try readKey(key)
        var output = SMCParamStruct()
        output.keyInfo.dataSize = value.size
        return (SMCParamStruct(), output)
    }
}

struct FanSafetyTests {
    @Test func partialTurboFailureRestoresEveryFan() {
        let smc = SimulatedSMC()
        smc.rejectedTarget = "F1Tg"
        #expect(throws: (any Error).self) { try FanService(connection: smc).setAllFansToMaximum() }
        #expect(smc.values["F0md"] == [0])
        #expect(smc.values["F1md"] == [0])
        #expect(smc.values["Ftst"] == [0])
    }

    @Test func manualModeTimeoutClearsForceTest() {
        let smc = SimulatedSMC()
        smc.rejectManual = true
        var time: TimeInterval = 100
        let service = FanService(connection: smc, clock: { time }, sleep: { time += $0 })
        #expect(throws: (any Error).self) { try service.setFanRPM(index: 0, rpm: 3000) }
        #expect(smc.values["Ftst"] == [0])
        #expect(time >= 110)
    }

    @Test func successfulForceTestWriteDoesNotHideFailedAutoWrite() {
        let smc = SimulatedSMC()
        smc.values["F0md"] = [1]
        smc.rejectAuto = true
        var time: TimeInterval = 0
        let service = FanService(connection: smc, clock: { time }, sleep: { time += $0 })
        #expect(throws: (any Error).self) { try service.setAllFansAuto() }
        #expect(smc.values["F0md"] == [1])
        #expect(time == 5)
    }

    @Test func turboToAutoWaitsForFirmwareWithoutRepeatingWrites() throws {
        let smc = SimulatedSMC()
        smc.values["Ftst"] = [1]
        smc.systemModeAfterAuto = true
        smc.autoReadDelays = ["F0md": 12, "F1md": 20, "Ftst": 28]
        let service = FanService(connection: smc)
        try service.setAllFansToMaximum()
        smc.writes.removeAll()
        var time: TimeInterval = 0
        let recovery = FanService(connection: smc, clock: { time }, sleep: { time += $0 })
        try recovery.setAllFansAuto()
        #expect(time > 2 && time < 5)
        #expect(smc.values["F0md"] == [3])
        #expect(smc.values["F1md"] == [3])
        #expect(smc.values["Ftst"] == [0])
        #expect(smc.writes == ["F0md", "F1md", "Ftst"])
    }

    @Test func stuckForceTestIsNotMistakenForAutomaticControl() {
        let smc = SimulatedSMC()
        smc.values["Ftst"] = [1]
        smc.ignoredWrites = ["Ftst"]
        var time: TimeInterval = 0
        let service = FanService(connection: smc, clock: { time }, sleep: { time += $0 })
        do {
            try service.setAllFansAuto()
            Issue.record("Ftst activo no debe confirmarse como Auto")
        } catch {
            #expect(error.localizedDescription.contains("Ftst=1"))
            #expect(time == 5)
            #expect(smc.writes == ["Ftst"])
        }
    }

    @Test func emptyForceTestReadingCannotConfirmAuto() {
        let smc = SimulatedSMC()
        smc.values["Ftst"] = []
        smc.ignoredWrites = ["Ftst"]
        var time: TimeInterval = 0
        let service = FanService(connection: smc, clock: { time }, sleep: { time += $0 })
        #expect(throws: (any Error).self) { try service.setAllFansAuto() }
        #expect(time == 5)
    }

    @Test func alreadySystemControlledFansNeedNoWritesOrWait() throws {
        let smc = SimulatedSMC()
        smc.values["F0md"] = [3]
        smc.values["F1md"] = [3]
        try FanService(connection: smc, sleep: { _ in Issue.record("Auto ya confirmado no debe esperar") }).setAllFansAuto()
        #expect(smc.writes.isEmpty)
    }

    @Test func systemModesAloneCannotClearManualSupervision() throws {
        let smc = SimulatedSMC()
        smc.values["F0md"] = [3]
        smc.values["F1md"] = [3]
        smc.values["Ftst"] = [1]
        let service = FanService(connection: smc)
        #expect(try !service.snapshot().isAutomaticControlConfirmed)
        smc.values["Ftst"] = []
        #expect(try !service.snapshot().isAutomaticControlConfirmed)
        smc.values["Ftst"] = [0]
        #expect(try service.snapshot().isAutomaticControlConfirmed)
    }

    @Test func singleFanAutoKeepsForceTestForOtherManualFan() throws {
        let smc = SimulatedSMC()
        smc.values["F0md"] = [1]
        smc.values["F1md"] = [1]
        smc.values["Ftst"] = [1]
        smc.autoReadDelays = ["F0md": 10]
        var time: TimeInterval = 0
        try FanService(connection: smc, clock: { time }, sleep: { time += $0 }).setFanAuto(index: 0)
        #expect(smc.values["F0md"] == [0])
        #expect(smc.values["F1md"] == [1])
        #expect(smc.values["Ftst"] == [1])
        #expect(smc.writes == ["F0md"])
    }

    @Test func autoDoesNotDependOnRPMReadings() throws {
        let smc = SimulatedSMC()
        smc.values.removeValue(forKey: "F0Ac")
        smc.values["F0md"] = [1]
        try FanService(connection: smc).setAllFansAuto()
        #expect(smc.values["F0md"] == [0])
    }

    @Test func rejectsNonFiniteRPMWithoutWrites() {
        let smc = SimulatedSMC()
        #expect(throws: (any Error).self) { try FanService(connection: smc).setFanRPM(index: 0, rpm: .nan) }
        #expect(smc.writes.isEmpty)
    }

    @Test func malformedRPMReadingIsRejectedBeforeItReachesTheUI() {
        let smc = SimulatedSMC()
        smc.values["F0Ac"] = SMCDataFormat.bytes(from: .nan, size: 4)
        #expect(throws: FanControlError.self) { try FanService(connection: smc).snapshot() }
        #expect(smc.writes.isEmpty)
    }

    @Test func clampsRequestedRPMToHardwareLimit() throws {
        let smc = SimulatedSMC()
        _ = try FanService(connection: smc).setFanRPM(index: 0, rpm: 9000)
        let result = try smc.readKey("F0Tg")
        #expect(SMCDataFormat.float(from: result.bytes, size: result.size) == 6000)
    }

    @Test func leaseExpiresAndCannotBeRenewedByDifferentProcess() {
        var lease = ManualFanLease()
        lease.begin(pid: 42, now: 100)
        let wrongOwner = lease.renew(pid: 43, now: 105)
        let renewed = lease.renew(pid: 42, now: 108)
        #expect(!wrongOwner)
        #expect(renewed)
        #expect(!lease.needsRecovery(now: 120, ownerIsAlive: true))
        #expect(lease.needsRecovery(now: 120, ownerIsAlive: false))
        #expect(lease.needsRecovery(now: 138, ownerIsAlive: true))
        let expiredRenewal = lease.renew(pid: 42, now: 139)
        #expect(!expiredRenewal)
        lease.clear()
        #expect(!lease.needsRecovery(now: 140, ownerIsAlive: false))
    }

    @Test func manualRequestsRequireIDsAndExactArguments() throws {
        #expect(throws: (any Error).self) { try FanHelperRequest.parse("turbo") }
        #expect(throws: (any Error).self) { try FanHelperRequest.parse("ping extra") }
        #expect(throws: (any Error).self) { try FanHelperRequest.parse("request \(UUID()) set 0 nan") }
        #expect(throws: (any Error).self) { try FanHelperRequest.parse("request \(UUID()) set -1 3000") }
        #expect(throws: (any Error).self) { try FanHelperRequest.parse("request \(UUID()) auto-all\nturbo") }
        let id = UUID()
        let request = try FanHelperRequest.parse("request \(id) set 0 3000")
        #expect(request.id == id)
        #expect(request.command == .set(0, 3000))
        #expect(try FanHelperRequest.parse("ping").command == .ping)
    }

    @Test func sensorFailureIsNotAnEmptySuccessfulSnapshot() {
        let smc = SimulatedSMC()
        #expect(throws: SensorReadError.self) { try SensorService(connection: smc).snapshot() }
    }
}
