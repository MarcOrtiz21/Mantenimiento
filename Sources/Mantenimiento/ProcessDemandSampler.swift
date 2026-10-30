import Foundation

struct AppNetworkUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let appPath: String?
    let receivedBps: Double?
    let sentBps: Double?
    let totalReceivedBytes: UInt64
    let totalSentBytes: UInt64
    let processCount: Int

    var currentBps: Double { (receivedBps ?? 0) + (sentBps ?? 0) }
    var totalBytes: UInt64 { totalReceivedBytes + totalSentBytes }
}

struct AppEnergyUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let appPath: String?
    let energyImpact: Double
    let processCount: Int
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

final class ProcessDemandSampler {
    static let shared = ProcessDemandSampler()

    private struct NetworkCounters {
        let received: UInt64
        let sent: UInt64
    }

    private let networkLock = NSLock()
    private let gpuLock = NSLock()
    private var previousNetworkCounters: [String: NetworkCounters] = [:]
    private var previousNetworkDate: Date?
    private var previousGPUTimes: [String: UInt64] = [:]
    private var previousGPUDate: Date?
    private let appNetworkLock = NSLock()
    private var previousAppNetworkCounters: [String: NetworkCounters] = [:]
    private var previousAppNetworkDate: Date?
    private var ownerCache: [Int32: ProcessOwner] = [:]

    private init() {}

    func cpuEntries() -> [MenuDemandEntry] {
        parsePSOutput(
            ExternalCommandRunner.capture(
                executable: "/bin/ps",
                arguments: ["-arcwwwxo", "pid=,%cpu=,rss=,command="],
                timeout: 0.6
            ),
            valueFormatter: { String(format: "%.1f%%", $0) }
        )
    }

    func memoryEntries() -> [MenuDemandEntry] {
        parsePSOutput(
            ExternalCommandRunner.capture(
                executable: "/bin/ps",
                arguments: ["-amcwwwxo", "pid=,%mem=,rss=,command="],
                timeout: 0.6
            ),
            valueFormatter: { _, rssKB in
                ByteCountFormatter.string(fromByteCount: Int64(max(rssKB, 0)) * 1024, countStyle: .file)
            }
        )
    }

    func networkEntries() -> [MenuDemandEntry] {
        networkLock.lock()
        defer { networkLock.unlock() }

        let output = ExternalCommandRunner.capture(
            executable: "/usr/bin/nettop",
            arguments: ["-P", "-L", "1", "-x", "-n", "-m", "tcp"],
            timeout: 1.2
        )
        let currentDate = Date()
        guard !output.isEmpty else { return [MenuDemandEntry(name: "Estado", detail: "Lectura TCP no disponible")] }
        let current = parseNetworkCounters(output)
        defer {
            previousNetworkCounters = current
            previousNetworkDate = currentDate
        }

        guard let previousNetworkDate else {
            return current
                .filter { $0.value.received > 0 || $0.value.sent > 0 }
                .map { key, counters in
                    MenuDemandEntry(
                        name: processDisplayName(key),
                        detail: "midiendo...",
                        sortValue: Double(counters.received + counters.sent)
                    )
                }
                .sorted { $0.sortValue > $1.sortValue }
        }

        let interval = max(currentDate.timeIntervalSince(previousNetworkDate), 0.1)
        return current.compactMap { key, counters in
            guard let old = previousNetworkCounters[key],
                  counters.received >= old.received,
                  counters.sent >= old.sent else {
                return nil
            }

            let receivedRate = Double(counters.received - old.received) / interval
            let sentRate = Double(counters.sent - old.sent) / interval
            guard receivedRate > 0 || sentRate > 0 else {
                return nil
            }

            return MenuDemandEntry(
                name: processDisplayName(key),
                detail: "Down \(demandRate(receivedRate)) | Up \(demandRate(sentRate))",
                sortValue: receivedRate + sentRate
            )
        }
        .sorted { $0.sortValue > $1.sortValue }
    }

    /// Tráfico TCP y UDP agrupado por aplicación; los helpers se suman a la app que los contiene.
    func appNetworkUsage() -> [AppNetworkUsage] {
        appNetworkLock.lock()
        defer { appNetworkLock.unlock() }

        let output = ExternalCommandRunner.capture(
            executable: "/usr/bin/nettop",
            arguments: ["-P", "-L", "1", "-x", "-n"],
            timeout: 1.5
        )
        let currentDate = Date()
        let current = parseNetworkCounters(output)
        guard !current.isEmpty else { return [] }
        let interval = previousAppNetworkDate.map { max(currentDate.timeIntervalSince($0), 0.1) }

        struct Accumulator {
            var name: String
            var appPath: String?
            var receivedRate: Double = 0
            var sentRate: Double = 0
            var totalReceived: UInt64 = 0
            var totalSent: UInt64 = 0
            var processes = 0
            var hasRate = false
        }
        var groups: [String: Accumulator] = [:]
        for (key, counters) in current where counters.received > 0 || counters.sent > 0 {
            let owner = processOwner(forNettopKey: key)
            var group = groups[owner.id] ?? Accumulator(name: owner.name, appPath: owner.appPath)
            group.totalReceived += counters.received
            group.totalSent += counters.sent
            group.processes += 1
            if let interval, let old = previousAppNetworkCounters[key] {
                group.hasRate = true
                group.receivedRate += Double(counters.received.subtractingClamped(old.received)) / interval
                group.sentRate += Double(counters.sent.subtractingClamped(old.sent)) / interval
            }
            groups[owner.id] = group
        }

        previousAppNetworkCounters = current
        previousAppNetworkDate = currentDate
        let livePIDs = Set(current.keys.compactMap(Self.pid(fromNettopKey:)))
        ownerCache = ownerCache.filter { livePIDs.contains($0.key) }

        return groups.map { id, group in
            AppNetworkUsage(
                id: id,
                name: group.name,
                appPath: group.appPath,
                receivedBps: group.hasRate ? group.receivedRate : nil,
                sentBps: group.hasRate ? group.sentRate : nil,
                totalReceivedBytes: group.totalReceived,
                totalSentBytes: group.totalSent,
                processCount: group.processes
            )
        }
    }

    private struct ProcessOwner {
        let id: String
        let name: String
        let appPath: String?
    }

    /// Impacto energético (la columna de Monitor de Actividad) agrupado por aplicación.
    func appEnergyUsage() -> [AppEnergyUsage] {
        let output = ExternalCommandRunner.capture(
            executable: "/usr/bin/top",
            arguments: ["-l", "2", "-s", "1", "-o", "power", "-n", "40", "-stats", "pid,command,power"],
            timeout: 4
        )
        let samples = Self.parseTopPower(output)
        guard !samples.isEmpty else { return [] }

        appNetworkLock.lock()
        defer { appNetworkLock.unlock() }
        var groups: [String: AppEnergyUsage] = [:]
        for sample in samples where sample.power > 0 && sample.command != "top" {
            let owner = processOwner(pid: sample.pid, fallbackName: sample.command)
            let current = groups[owner.id]
            groups[owner.id] = AppEnergyUsage(
                id: owner.id,
                name: owner.name,
                appPath: owner.appPath,
                energyImpact: (current?.energyImpact ?? 0) + sample.power,
                processCount: (current?.processCount ?? 0) + 1
            )
        }
        return groups.values.sorted { $0.energyImpact > $1.energyImpact }
    }

    /// Usa solo la última muestra de `top`; la primera no tiene intervalo y sale a cero.
    static func parseTopPower(_ output: String) -> [(pid: Int32, command: String, power: Double)] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.lastIndex(where: { $0.hasPrefix("PID") && $0.contains("POWER") }) else { return [] }
        return lines[(header + 1)...].compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3,
                  let pid = Int32(fields[0]),
                  let power = Double(fields[fields.count - 1]) else {
                return nil
            }
            let command = fields[1..<(fields.count - 1)].joined(separator: " ")
            return (pid, command, power)
        }
    }

    private func processOwner(forNettopKey key: String) -> ProcessOwner {
        let fallbackName = processDisplayName(key)
        guard let pid = Self.pid(fromNettopKey: key) else {
            return ProcessOwner(id: fallbackName, name: fallbackName, appPath: nil)
        }
        return processOwner(pid: pid, fallbackName: fallbackName)
    }

    private func processOwner(pid: Int32, fallbackName: String) -> ProcessOwner {
        if let cached = ownerCache[pid] {
            return cached
        }

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let owner: ProcessOwner
        if length > 0 {
            let path = String(cString: buffer)
            if let range = path.range(of: ".app/") {
                let appPath = String(path[..<range.lowerBound]) + ".app"
                let name = (FileManager.default.displayName(atPath: appPath) as NSString).deletingPathExtension
                owner = ProcessOwner(id: appPath, name: name, appPath: appPath)
            } else {
                let name = URL(fileURLWithPath: path).lastPathComponent
                owner = ProcessOwner(id: name, name: name, appPath: nil)
            }
        } else {
            owner = ProcessOwner(id: fallbackName, name: fallbackName, appPath: nil)
        }
        ownerCache[pid] = owner
        return owner
    }

    private static func pid(fromNettopKey key: String) -> Int32? {
        guard let dot = key.lastIndex(of: ".") else { return nil }
        return Int32(key[key.index(after: dot)...])
    }

    func gpuEntries() -> [MenuDemandEntry] {
        gpuLock.lock()
        defer { gpuLock.unlock() }

        let output = ExternalCommandRunner.capture(
            executable: "/usr/sbin/ioreg",
            arguments: ["-r", "-c", "AGXDeviceUserClient", "-d", "1"],
            timeout: 1.0
        )
        let currentDate = Date()
        let current = parseGPUTimes(output)
        defer {
            previousGPUTimes = current
            previousGPUDate = currentDate
        }

        guard let previousGPUDate else {
            return current
                .map { name, time in
                    MenuDemandEntry(name: name, detail: "midiendo...", sortValue: Double(time))
                }
                .sorted { $0.sortValue > $1.sortValue }
        }

        let interval = max(currentDate.timeIntervalSince(previousGPUDate), 0.1)
        return current.compactMap { name, time in
            guard let old = previousGPUTimes[name], time >= old else {
                return nil
            }
            let delta = time - old
            guard delta > 0 else {
                return nil
            }

            let ratio = min(max(Double(delta) / 1_000_000_000 / interval, 0), 1)
            return MenuDemandEntry(
                name: name,
                detail: String(format: "≈ %.1f%% GPU", ratio * 100),
                sortValue: ratio
            )
        }
        .sorted { $0.sortValue > $1.sortValue }
    }

    private func parseNetworkCounters(_ output: String) -> [String: NetworkCounters] {
        var counters: [String: NetworkCounters] = [:]

        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 5 else {
                continue
            }

            let process = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !process.isEmpty else {
                continue
            }

            let received = UInt64(fields[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let sent = UInt64(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let old = counters[process] ?? NetworkCounters(received: 0, sent: 0)
            counters[process] = NetworkCounters(received: old.received + received, sent: old.sent + sent)
        }

        return counters
    }

    private func parseGPUTimes(_ output: String) -> [String: UInt64] {
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
            if line.contains("IOUserClientCreator") {
                flush()
                if let match = firstDemandMatch(in: line, pattern: #"pid\s+(\d+),\s*([^\"]+)"#),
                   match.count == 3 {
                    currentPID = match[1]
                    currentName = match[2].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }

            for value in allDemandMatches(in: line, pattern: #""accumulatedGPUTime"=(\d+)"#) {
                if value.count == 2, let time = UInt64(value[1]) {
                    currentTime += time
                }
            }
        }
        flush()
        return totals
    }

    private func parsePSOutput(
        _ output: String,
        valueFormatter: (Double, Int64) -> String
    ) -> [MenuDemandEntry] {
        output
            .split(separator: "\n")
            .compactMap { line -> MenuDemandEntry? in
                let parts = line.split(
                    maxSplits: 3,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0 == " " || $0 == "\t" }
                )
                guard parts.count == 4,
                      let value = Double(parts[1]),
                      let rss = Int64(parts[2]) else {
                    return nil
                }

                let name = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    return nil
                }

                return MenuDemandEntry(name: name, detail: valueFormatter(value, rss), sortValue: value)
            }
    }

    private func parsePSOutput(
        _ output: String,
        valueFormatter: (Double) -> String
    ) -> [MenuDemandEntry] {
        parsePSOutput(output) { value, _ in valueFormatter(value) }
    }

    private func processDisplayName(_ process: String) -> String {
        guard let dot = process.lastIndex(of: "."),
              process[process.index(after: dot)...].allSatisfy(\.isNumber) else {
            return process
        }
        return String(process[..<dot])
    }
}

private func firstDemandMatch(in text: String, pattern: String) -> [String]? {
    allDemandMatches(in: text, pattern: pattern).first
}

private func allDemandMatches(in text: String, pattern: String) -> [[String]] {
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

private func demandRate(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded())) B/s"
}
