import Darwin
import Foundation
import IOKit

public struct SystemTelemetrySnapshot: Codable {
    public let cpu: CPUSnapshot
    public let gpu: GPUSnapshot?
    public let memory: MemorySnapshot
    public let swap: SwapSnapshot
    public let disk: DiskSnapshot
    public let diskIO: DiskIOSnapshot
    public let battery: BatterySnapshot?
    public let network: NetworkSnapshot
}

public struct CPUSnapshot: Codable {
    public let cores: [CPUCoreSnapshot]

    public var coreCount: Int {
        cores.count
    }

    public var totalActiveTicks: UInt64 {
        cores.reduce(UInt64(0)) { $0 + $1.activeTicks }
    }

    public var totalTicks: UInt64 {
        cores.reduce(UInt64(0)) { $0 + $1.totalTicks }
    }
}

public struct CPUCoreSnapshot: Codable, Identifiable {
    public var id: Int { index }

    public let index: Int
    public let userTicks: UInt64
    public let systemTicks: UInt64
    public let niceTicks: UInt64
    public let idleTicks: UInt64

    public var activeTicks: UInt64 {
        userTicks + systemTicks + niceTicks
    }

    public var totalTicks: UInt64 {
        activeTicks + idleTicks
    }
}

public struct GPUSnapshot: Codable {
    public let model: String
    public let coreCount: Int?
    public let utilizationPercent: Double?
    public let rendererUtilizationPercent: Double?
    public let tilerUtilizationPercent: Double?
    public let inUseMemoryBytes: UInt64?
    public let allocatedMemoryBytes: UInt64?

    public var utilizationRatio: Double? {
        utilizationPercent.map { min(max($0 / 100.0, 0), 1) }
    }
}

public struct MemorySnapshot: Codable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public let appBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let pressureLevel: Int

    public var usedRatio: Double {
        guard totalBytes > 0 else {
            return 0
        }
        return Double(usedBytes) / Double(totalBytes)
    }

    public var pressureDescription: String {
        switch pressureLevel {
        case 0...1:
            return "normal"
        case 2:
            return "moderada"
        default:
            return "alta"
        }
    }
}

public struct SwapSnapshot: Codable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
}

public struct DiskSnapshot: Codable {
    public let volumeName: String
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let availableBytes: UInt64

    public var usedBytes: UInt64 {
        totalBytes > freeBytes ? totalBytes - freeBytes : 0
    }

    public var usedRatio: Double {
        guard totalBytes > 0 else {
            return 0
        }
        return Double(usedBytes) / Double(totalBytes)
    }
}

public struct DiskIOSnapshot: Codable {
    public let readBytes: UInt64
    public let writtenBytes: UInt64
    public let readOperations: UInt64
    public let writeOperations: UInt64
}

public struct BatterySnapshot: Codable {
    public let percent: Int
    public let isCharging: Bool
    public let isCharged: Bool
    public let externalConnected: Bool
    public let cycleCount: Int?
    public let designCapacity: Int?
    public let maxCapacity: Int?
    public let temperatureCelsius: Double?

    public var healthPercent: Int? {
        guard let designCapacity, let maxCapacity, designCapacity > 0 else {
            return nil
        }
        return min(100, max(0, Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())))
    }
}

public struct NetworkSnapshot: Codable {
    public let interfaces: [NetworkInterfaceSnapshot]

    public var totalReceivedBytes: UInt64 {
        interfaces.reduce(UInt64(0)) { $0 + $1.receivedBytes }
    }

    public var totalSentBytes: UInt64 {
        interfaces.reduce(UInt64(0)) { $0 + $1.sentBytes }
    }

    public var primaryInterfaceName: String? {
        interfaces.first?.displayName
    }
}

public struct NetworkInterfaceSnapshot: Codable, Identifiable {
    public var id: String { name }

    public let name: String
    public let displayName: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
}

public enum SystemTelemetryService {
    public static func placeholderSnapshot() -> SystemTelemetrySnapshot {
        SystemTelemetrySnapshot(
            cpu: CPUSnapshot(cores: []),
            gpu: nil,
            memory: MemorySnapshot(
                totalBytes: 0,
                usedBytes: 0,
                freeBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedFilesBytes: 0,
                pressureLevel: 0
            ),
            swap: SwapSnapshot(totalBytes: 0, usedBytes: 0, freeBytes: 0),
            disk: DiskSnapshot(volumeName: "", totalBytes: 0, freeBytes: 0, availableBytes: 0),
            diskIO: DiskIOSnapshot(readBytes: 0, writtenBytes: 0, readOperations: 0, writeOperations: 0),
            battery: nil,
            network: NetworkSnapshot(interfaces: [])
        )
    }

    public static func snapshot() -> SystemTelemetrySnapshot {
        SystemTelemetrySnapshot(
            cpu: cpuSnapshot(),
            gpu: gpuSnapshot(),
            memory: memorySnapshot(),
            swap: swapSnapshot(),
            disk: diskSnapshot(),
            diskIO: diskIOSnapshot(),
            battery: batterySnapshot(),
            network: networkSnapshot()
        )
    }

    public static func statusSnapshot(previous: SystemTelemetrySnapshot? = nil) -> SystemTelemetrySnapshot {
        SystemTelemetrySnapshot(
            cpu: cpuSnapshot(),
            gpu: gpuSnapshot(),
            memory: memorySnapshot(),
            swap: previous?.swap ?? SwapSnapshot(totalBytes: 0, usedBytes: 0, freeBytes: 0),
            disk: previous?.disk ?? DiskSnapshot(volumeName: "", totalBytes: 0, freeBytes: 0, availableBytes: 0),
            diskIO: previous?.diskIO ?? DiskIOSnapshot(readBytes: 0, writtenBytes: 0, readOperations: 0, writeOperations: 0),
            battery: previous?.battery,
            network: networkSnapshot()
        )
    }

    private static func cpuSnapshot() -> CPUSnapshot {
        var cpuInfo: processor_info_array_t?
        var cpuCount: mach_msg_type_number_t = 0
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return CPUSnapshot(cores: [])
        }
        defer {
            let byteCount = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), byteCount)
        }

        let buffer = UnsafeBufferPointer(start: cpuInfo, count: Int(infoCount))
        var cores: [CPUCoreSnapshot] = []

        for index in 0..<Int(cpuCount) {
            let base = index * Int(CPU_STATE_MAX)
            guard base + Int(CPU_STATE_IDLE) < buffer.count else {
                continue
            }

            cores.append(CPUCoreSnapshot(
                index: index,
                userTicks: UInt64(max(0, buffer[base + Int(CPU_STATE_USER)])),
                systemTicks: UInt64(max(0, buffer[base + Int(CPU_STATE_SYSTEM)])),
                niceTicks: UInt64(max(0, buffer[base + Int(CPU_STATE_NICE)])),
                idleTicks: UInt64(max(0, buffer[base + Int(CPU_STATE_IDLE)]))
            ))
        }

        return CPUSnapshot(cores: cores)
    }

    private static func gpuSnapshot() -> GPUSnapshot? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var snapshots: [GPUSnapshot] = []

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer { IOObjectRelease(service) }

            guard let properties = serviceProperties(service) else {
                continue
            }

            let statistics = properties["PerformanceStatistics"] as? [String: Any]
            let model = (properties["model"] as? String) ?? "GPU"
            let utilization = doubleValue(statistics?["Device Utilization %"])
            let renderer = doubleValue(statistics?["Renderer Utilization %"])
            let tiler = doubleValue(statistics?["Tiler Utilization %"])

            guard utilization != nil || renderer != nil || tiler != nil else {
                continue
            }

            snapshots.append(GPUSnapshot(
                model: model,
                coreCount: intValue(properties["gpu-core-count"]),
                utilizationPercent: utilization.map { min(max($0, 0), 100) },
                rendererUtilizationPercent: renderer.map { min(max($0, 0), 100) },
                tilerUtilizationPercent: tiler.map { min(max($0, 0), 100) },
                inUseMemoryBytes: uint64Value(statistics?["In use system memory"]),
                allocatedMemoryBytes: uint64Value(statistics?["Alloc system memory"])
            ))
        }

        return snapshots.max {
            ($0.utilizationPercent ?? 0) < ($1.utilizationPercent ?? 0)
        }
    }

    private static func memorySnapshot() -> MemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        let pageSize = vmPageSize()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return MemorySnapshot(
                totalBytes: total,
                usedBytes: 0,
                freeBytes: total,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedFilesBytes: 0,
                pressureLevel: memoryPressureLevel()
            )
        }

        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = UInt64(stats.internal_page_count) > purgeablePages
            ? UInt64(stats.internal_page_count) - purgeablePages
            : 0
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let cachedPages = UInt64(stats.external_page_count) + purgeablePages
        let freePages = UInt64(stats.free_count + stats.speculative_count)

        let appBytes = min(total, appPages * pageSize)
        let wiredBytes = min(total, wiredPages * pageSize)
        let compressedBytes = min(total, compressedPages * pageSize)
        let cachedFilesBytes = min(total, cachedPages * pageSize)
        let usedBytes = min(total, appBytes + wiredBytes + compressedBytes)
        let freeBytes = min(total, freePages * pageSize)

        return MemorySnapshot(
            totalBytes: total,
            usedBytes: usedBytes,
            freeBytes: freeBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            pressureLevel: memoryPressureLevel()
        )
    }

    private static func swapSnapshot() -> SwapSnapshot {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride

        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else {
            return SwapSnapshot(totalBytes: 0, usedBytes: 0, freeBytes: 0)
        }

        return SwapSnapshot(
            totalBytes: UInt64(usage.xsu_total),
            usedBytes: UInt64(usage.xsu_used),
            freeBytes: UInt64(usage.xsu_avail)
        )
    }

    private static func diskSnapshot() -> DiskSnapshot {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])

        let total = UInt64(max(values?.volumeTotalCapacity ?? 0, 0))
        let free = UInt64(max(values?.volumeAvailableCapacity ?? 0, 0))
        let important = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? Int64(free))

        return DiskSnapshot(
            volumeName: values?.volumeName ?? "Macintosh HD",
            totalBytes: total,
            freeBytes: free,
            availableBytes: important
        )
    }

    private static func diskIOSnapshot() -> DiskIOSnapshot {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            return DiskIOSnapshot(readBytes: 0, writtenBytes: 0, readOperations: 0, writeOperations: 0)
        }
        defer { IOObjectRelease(iterator) }

        var readBytes: UInt64 = 0
        var writtenBytes: UInt64 = 0
        var readOperations: UInt64 = 0
        var writeOperations: UInt64 = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer { IOObjectRelease(service) }

            guard let properties = serviceProperties(service),
                  let statistics = properties["Statistics"] as? [String: Any] else {
                continue
            }

            readBytes += uint64Value(statistics["Bytes (Read)"]) ?? 0
            writtenBytes += uint64Value(statistics["Bytes (Write)"]) ?? 0
            readOperations += uint64Value(statistics["Operations (Read)"]) ?? 0
            writeOperations += uint64Value(statistics["Operations (Write)"]) ?? 0
        }

        return DiskIOSnapshot(
            readBytes: readBytes,
            writtenBytes: writtenBytes,
            readOperations: readOperations,
            writeOperations: writeOperations
        )
    }

    private static func batterySnapshot() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return nil
        }
        defer { IOObjectRelease(service) }

        guard let properties = serviceProperties(service) else {
            return nil
        }

        let currentCapacity = intValue(properties["CurrentCapacity"])
        let maxCapacityPercent = intValue(properties["MaxCapacity"])
        let rawCurrentCapacity = intValue(properties["AppleRawCurrentCapacity"])
        let rawMaxCapacity = intValue(properties["AppleRawMaxCapacity"])
            ?? intValue(properties["NominalChargeCapacity"])
        let designCapacity = intValue(properties["DesignCapacity"])
        let percent: Int
        if let currentCapacity, (0...100).contains(currentCapacity) {
            percent = currentCapacity
        } else if let rawCurrentCapacity, let rawMaxCapacity, rawMaxCapacity > 0 {
            percent = Int((Double(rawCurrentCapacity) / Double(rawMaxCapacity) * 100).rounded())
        } else if let currentCapacity, let maxCapacityPercent, maxCapacityPercent > 0 {
            percent = Int((Double(currentCapacity) / Double(maxCapacityPercent) * 100).rounded())
        } else {
            percent = currentCapacity ?? 0
        }

        return BatterySnapshot(
            percent: min(max(percent, 0), 100),
            isCharging: boolValue(properties["IsCharging"]),
            isCharged: boolValue(properties["FullyCharged"]),
            externalConnected: boolValue(properties["ExternalConnected"]),
            cycleCount: intValue(properties["CycleCount"]),
            designCapacity: designCapacity,
            maxCapacity: rawMaxCapacity,
            temperatureCelsius: intValue(properties["Temperature"]).map { Double($0) / 100.0 }
        )
    }

    private static func networkSnapshot() -> NetworkSnapshot {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return NetworkSnapshot(interfaces: [])
        }
        defer { freeifaddrs(pointer) }

        var interfaces: [NetworkInterfaceSnapshot] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let item = current {
            defer { current = item.pointee.ifa_next }

            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = item.pointee.ifa_data else {
                continue
            }

            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }

            let name = String(cString: item.pointee.ifa_name)
            guard shouldIncludeNetworkInterface(name) else {
                continue
            }

            let ifData = data.assumingMemoryBound(to: if_data.self).pointee
            let received = UInt64(ifData.ifi_ibytes)
            let sent = UInt64(ifData.ifi_obytes)
            guard received > 0 || sent > 0 else {
                continue
            }

            interfaces.append(NetworkInterfaceSnapshot(
                name: name,
                displayName: networkDisplayName(name),
                receivedBytes: received,
                sentBytes: sent
            ))
        }

        return NetworkSnapshot(
            interfaces: interfaces.sorted {
                ($0.receivedBytes + $0.sentBytes) > ($1.receivedBytes + $1.sentBytes)
            }
        )
    }

    private static func vmPageSize() -> UInt64 {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return UInt64(vm_kernel_page_size)
        }
        return UInt64(pageSize)
    }

    private static func memoryPressureLevel() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.stride
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 0
        }
        return Int(level)
    }

    private static func serviceProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return nil
        }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? UInt {
            return UInt64(value)
        }
        if let value = value as? Int {
            return value >= 0 ? UInt64(value) : nil
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Float {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? UInt64 {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private static func shouldIncludeNetworkInterface(_ name: String) -> Bool {
        if name.hasPrefix("en") {
            return true
        }

        if name.hasPrefix("utun") {
            return true
        }

        return false
    }

    private static func networkDisplayName(_ name: String) -> String {
        if name == "en0" {
            return "Wi-Fi"
        }
        if name.hasPrefix("utun") {
            return "VPN \(name.dropFirst(4))"
        }
        return name
    }
}
