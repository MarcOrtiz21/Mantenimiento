import Darwin
import Foundation

struct AppResourceSnapshot {
    let date: Date
    let cpuRatio: Double?
    let residentMemoryBytes: UInt64
}

final class AppResourceMonitor {
    static let shared = AppResourceMonitor()

    private let lock = NSLock()
    private var previousDate: Date?
    private var previousCPUTime: TimeInterval?

    private init() {}

    func snapshot() -> AppResourceSnapshot {
        let date = Date()
        let cpuTime = cumulativeCPUTime()
        let memory = residentMemoryBytes()

        lock.lock()
        let oldDate = previousDate
        let oldCPUTime = previousCPUTime
        previousDate = date
        previousCPUTime = cpuTime
        lock.unlock()

        let cpuRatio: Double?
        if let oldDate, let oldCPUTime {
            let interval = max(date.timeIntervalSince(oldDate), 0.1)
            cpuRatio = max(0, (cpuTime - oldCPUTime) / interval)
        } else {
            cpuRatio = nil
        }

        return AppResourceSnapshot(
            date: date,
            cpuRatio: cpuRatio,
            residentMemoryBytes: memory
        )
    }

    private func cumulativeCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }

        return timeInterval(usage.ru_utime) + timeInterval(usage.ru_stime)
    }

    private func timeInterval(_ timeval: timeval) -> TimeInterval {
        TimeInterval(timeval.tv_sec) + TimeInterval(timeval.tv_usec) / 1_000_000
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return UInt64(info.resident_size)
    }
}
