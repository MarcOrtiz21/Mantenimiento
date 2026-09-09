import Foundation

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
                detail: String(format: "%.1f%% GPU", ratio * 100),
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
