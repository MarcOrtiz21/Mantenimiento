import AppKit
import SwiftUI
import MantenimientoCore

struct TelemetryHistory {
    private(set) var samples: [TelemetrySample] = []
    private let maxSampleCount = 80

    mutating func append(_ snapshot: DashboardSnapshot) {
        guard samples.last.map({ snapshot.date > $0.date }) ?? true else { return }
        samples.append(TelemetrySample(snapshot: snapshot, previous: samples.last))
        if samples.count > maxSampleCount {
            samples.removeFirst(samples.count - maxSampleCount)
        }
    }

    var temperaturePoints: TelemetryChartData {
        points(\.maxTemperature)
    }

    var cpuPoints: TelemetryChartData {
        points(\.cpuUsage)
    }

    var gpuPoints: TelemetryChartData {
        points(\.gpuUsage)
    }

    var gpuTemperaturePoints: TelemetryChartData {
        points(\.gpuTemperature)
    }

    var rpmPoints: TelemetryChartData {
        points(\.averageRPM)
    }

    var powerPoints: TelemetryChartData {
        points(\.systemPower)
    }

    var memoryPoints: TelemetryChartData {
        points(\.memoryUsedRatio)
    }

    var networkDownPoints: TelemetryChartData {
        points(\.networkDownBps)
    }

    var networkUpPoints: TelemetryChartData {
        points(\.networkUpBps)
    }

    var diskReadPoints: TelemetryChartData {
        points(\.diskReadBps, date: \.diskDate)
    }

    var diskWritePoints: TelemetryChartData {
        points(\.diskWriteBps, date: \.diskDate)
    }

    var batteryPowerPoints: TelemetryChartData {
        points(\.batteryPower)
    }

    var systemLoadPowerPoints: TelemetryChartData {
        points(\.systemLoadPower)
    }

    var latest: TelemetrySample? {
        samples.last
    }

    private func points(_ value: KeyPath<TelemetrySample, Double?>, date: KeyPath<TelemetrySample, Date> = \.date) -> TelemetryChartData {
        TelemetryChartSeries.make(samples.map { ($0[keyPath: date], $0[keyPath: value], $0.samplingEpoch) })
    }

    var latestMaxTemperature: Double? {
        samples.last?.maxTemperature
    }

    var latestCPUUsage: Double? {
        samples.last?.cpuUsage
    }

    var latestGPUUsage: Double? {
        samples.last?.gpuUsage
    }

    var latestGPUTemperature: Double? {
        samples.last?.gpuTemperature
    }

    var latestCoreUsages: [CPUCoreUsage] {
        samples.last?.coreUsages ?? []
    }

    var latestAverageRPM: Double? {
        samples.last?.averageRPM
    }

    var latestSystemPower: Double? {
        samples.last?.systemPower
    }

    var latestMemoryRatio: Double? {
        memoryPoints.points.last?.value
    }

    var latestNetworkDownBps: Double? {
        samples.last?.networkDownBps
    }

    var latestNetworkUpBps: Double? {
        samples.last?.networkUpBps
    }

    var latestNetworkInterfaceRates: [NetworkInterfaceRate] {
        samples.last?.networkInterfaceRates ?? []
    }

    var latestDiskReadBps: Double? {
        samples.last?.diskReadBps
    }

    var latestDiskWriteBps: Double? {
        samples.last?.diskWriteBps
    }
}

struct TelemetrySample: Identifiable {
    let id = UUID()
    let date: Date
    let samplingEpoch: UInt64
    let diskDate: Date
    let maxTemperature: Double?
    let averageRPM: Double?
    let systemPower: Double?
    let memoryUsedRatio: Double?
    let gpuUsage: Double?
    let gpuTemperature: Double?
    let cpuCores: [CPUCoreSnapshot]
    let cpuUsage: Double?
    let coreUsages: [CPUCoreUsage]
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let diskReadBps: Double?
    let diskWriteBps: Double?
    let networkReceivedBytes: UInt64
    let networkSentBytes: UInt64
    let networkInterfaces: [NetworkInterfaceSnapshot]
    let networkDownBps: Double?
    let networkUpBps: Double?
    let networkInterfaceRates: [NetworkInterfaceRate]
    let memory: MemorySnapshot
    let cpuUserRatio: Double?
    let cpuSystemRatio: Double?
    let pageInBps: Double?
    let pageOutBps: Double?
    let swapInBps: Double?
    let swapOutBps: Double?
    let batteryPower: Double?
    let systemLoadPower: Double?
    let systemPowerIn: Double?

    init(snapshot: DashboardSnapshot, previous: TelemetrySample?) {
        memory = snapshot.telemetry.memory
        batteryPower = snapshot.telemetry.battery?.batteryPowerWatts
        systemLoadPower = snapshot.telemetry.battery?.systemLoadWatts
        systemPowerIn = snapshot.telemetry.battery?.systemPowerInWatts
        date = snapshot.date
        samplingEpoch = snapshot.samplingEpoch
        diskDate = snapshot.diskDate
        maxTemperature = snapshot.sensors?.hottestTemperature.map { Double($0.value) }

        if let fans = snapshot.fans?.fans, !fans.isEmpty {
            let total = fans.reduce(Double(0)) { $0 + Double(max($1.actualRPM, 0)) }
            averageRPM = total / Double(fans.count)
        } else {
            averageRPM = nil
        }

        systemPower = snapshot.sensors?.readings.first(where: { $0.sensor.key == "PSTR" }).map {
            Double($0.value)
        }
        memoryUsedRatio = snapshot.telemetry.memory.isAvailable ? snapshot.telemetry.memory.usedRatio : nil
        gpuUsage = snapshot.telemetry.gpu?.utilizationRatio
        gpuTemperature = snapshot.sensors?.readings(type: .temperature, group: .gpu).map { Double($0.value) }.max()
        cpuCores = snapshot.telemetry.cpu.cores
        diskReadBytes = snapshot.telemetry.diskIO.readBytes
        diskWrittenBytes = snapshot.telemetry.diskIO.writtenBytes
        networkReceivedBytes = snapshot.telemetry.network.totalReceivedBytes
        networkSentBytes = snapshot.telemetry.network.totalSentBytes
        networkInterfaces = snapshot.telemetry.network.interfaces

        if let previous, previous.samplingEpoch == samplingEpoch,
           TelemetryContinuity.isContinuous(from: previous.date, to: date) {
            let interval = max(date.timeIntervalSince(previous.date), 0.1)
            let cpu = computeCPUUsage(current: cpuCores, previous: previous.cpuCores)
            cpuUsage = cpu.total
            coreUsages = cpu.cores
            let split = computeCPUSplit(current: snapshot.telemetry.cpu, previous: previous.cpuCores)
            cpuUserRatio = split?.user
            cpuSystemRatio = split?.system
            let pageRate = { (current: UInt64, old: UInt64) -> Double? in
                current >= old ? Double(current - old) / interval : nil
            }
            let currentMemory = snapshot.telemetry.memory
            pageInBps = pageRate(currentMemory.pageInBytes, previous.memory.pageInBytes)
            pageOutBps = pageRate(currentMemory.pageOutBytes, previous.memory.pageOutBytes)
            swapInBps = pageRate(currentMemory.swapInBytes, previous.memory.swapInBytes)
            swapOutBps = pageRate(currentMemory.swapOutBytes, previous.memory.swapOutBytes)

            diskReadBps = snapshot.diskReadBps
            diskWriteBps = snapshot.diskWriteBps

            if networkReceivedBytes >= previous.networkReceivedBytes {
                networkDownBps = Double(networkReceivedBytes - previous.networkReceivedBytes) / interval
            } else {
                networkDownBps = nil
            }

            if networkSentBytes >= previous.networkSentBytes {
                networkUpBps = Double(networkSentBytes - previous.networkSentBytes) / interval
            } else {
                networkUpBps = nil
            }

            networkInterfaceRates = computeNetworkInterfaceRates(
                current: networkInterfaces,
                previous: previous.networkInterfaces,
                interval: interval
            )
        } else {
            cpuUsage = nil
            coreUsages = []
            cpuUserRatio = nil
            cpuSystemRatio = nil
            pageInBps = nil
            pageOutBps = nil
            swapInBps = nil
            swapOutBps = nil
            diskReadBps = snapshot.diskReadBps
            diskWriteBps = snapshot.diskWriteBps
            networkDownBps = nil
            networkUpBps = nil
            networkInterfaceRates = []
        }
    }
}

struct CPUCoreUsage: Identifiable {
    let id: Int
    let index: Int
    let usage: Double
}

struct NetworkInterfaceRate: Identifiable {
    let id: String
    let name: String
    let displayName: String
    let receivedBps: Double
    let sentBps: Double
}

struct GPUProcessDemandEntry: Identifiable {
    let id: String
    let name: String
    let detail: String
    let sortValue: Double
}

func computeCPUUsage(
    current: [CPUCoreSnapshot],
    previous: [CPUCoreSnapshot]
) -> (total: Double?, cores: [CPUCoreUsage]) {
    let previousByIndex = Dictionary(uniqueKeysWithValues: previous.map { ($0.index, $0) })
    var activeDeltaTotal: UInt64 = 0
    var totalDeltaTotal: UInt64 = 0
    var usages: [CPUCoreUsage] = []

    for core in current.sorted(by: { $0.index < $1.index }) {
        guard let old = previousByIndex[core.index],
              core.totalTicks >= old.totalTicks,
              core.activeTicks >= old.activeTicks else {
            continue
        }

        let totalDelta = core.totalTicks - old.totalTicks
        let activeDelta = core.activeTicks - old.activeTicks
        guard totalDelta > 0 else {
            continue
        }

        activeDeltaTotal += activeDelta
        totalDeltaTotal += totalDelta
        usages.append(CPUCoreUsage(
            id: core.index,
            index: core.index,
            usage: min(max(Double(activeDelta) / Double(totalDelta), 0), 1)
        ))
    }

    let total = totalDeltaTotal > 0 ? min(max(Double(activeDeltaTotal) / Double(totalDeltaTotal), 0), 1) : nil
    return (total, usages)
}

func computeCPUSplit(current: CPUSnapshot, previous: [CPUCoreSnapshot]) -> (user: Double, system: Double)? {
    let previousUser = previous.reduce(UInt64(0)) { $0 + $1.userTicks + $1.niceTicks }
    let previousSystem = previous.reduce(UInt64(0)) { $0 + $1.systemTicks }
    let previousTotal = previous.reduce(UInt64(0)) { $0 + $1.totalTicks }
    guard current.totalUserTicks >= previousUser,
          current.totalSystemTicks >= previousSystem,
          current.totalTicks > previousTotal else {
        return nil
    }
    let total = Double(current.totalTicks - previousTotal)
    return (
        min(max(Double(current.totalUserTicks - previousUser) / total, 0), 1),
        min(max(Double(current.totalSystemTicks - previousSystem) / total, 0), 1)
    )
}

func computeNetworkInterfaceRates(
    current: [NetworkInterfaceSnapshot],
    previous: [NetworkInterfaceSnapshot],
    interval: TimeInterval
) -> [NetworkInterfaceRate] {
    let previousByName = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, $0) })

    return current.compactMap { interface in
        guard let old = previousByName[interface.name],
              interface.receivedBytes >= old.receivedBytes,
              interface.sentBytes >= old.sentBytes else {
            return nil
        }

        return NetworkInterfaceRate(
            id: interface.name,
            name: interface.name,
            displayName: interface.displayName,
            receivedBps: Double(interface.receivedBytes - old.receivedBytes) / interval,
            sentBps: Double(interface.sentBytes - old.sentBytes) / interval
        )
    }
    .sorted {
        ($0.receivedBps + $0.sentBps) > ($1.receivedBps + $1.sentBps)
    }
}

func loadGPUProcessDemand() -> [GPUProcessDemandEntry] {
    let output = runDiagnosticCommand("/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXDeviceUserClient", "-d", "1"])
    var currentName: String?
    var currentPID: String?
    var currentTime: UInt64 = 0
    var totals: [String: UInt64] = [:]

    func flush() {
        guard let name = currentName, currentTime > 0 else {
            currentName = nil
            currentPID = nil
            currentTime = 0
            return
        }

        let key = currentPID.map { "\(name) (\($0))" } ?? name
        totals[key, default: 0] += currentTime
        currentName = nil
        currentPID = nil
        currentTime = 0
    }

    for line in output.split(separator: "\n").map(String.init) {
        if line.contains("AGXDeviceUserClient") {
            flush()
            continue
        }

        if line.contains("IOUserClientCreator"),
           let match = firstDiagnosticMatch(in: line, pattern: #"pid\s+(\d+),\s*([^"]+)"#),
           match.count == 3 {
            currentPID = match[1]
            currentName = match[2].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for value in allDiagnosticMatches(in: line, pattern: #""accumulatedGPUTime"=(\d+)"#) {
            if value.count == 2, let time = UInt64(value[1]) {
                currentTime += time
            }
        }
    }
    flush()

    return totals
        .sorted { $0.value > $1.value }
        .map { name, nanoseconds in
            GPUProcessDemandEntry(
                id: name,
                name: name,
                detail: gpuTime(nanoseconds),
                sortValue: Double(nanoseconds)
            )
        }
}

func runDiagnosticCommand(_ executable: String, arguments: [String]) -> String {
    ExternalCommandRunner.capture(
        executable: executable,
        arguments: arguments,
        timeout: 0.9
    )
}

func firstDiagnosticMatch(in text: String, pattern: String) -> [String]? {
    allDiagnosticMatches(in: text, pattern: pattern).first
}

func allDiagnosticMatches(in text: String, pattern: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).map { match in
        (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

func gpuTime(_ nanoseconds: UInt64) -> String {
    let seconds = Double(nanoseconds) / 1_000_000_000
    if seconds >= 60 {
        return String(format: "%.1f min GPU", seconds / 60)
    }
    return String(format: "%.1f s GPU", seconds)
}
