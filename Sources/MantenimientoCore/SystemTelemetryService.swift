import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

public struct SystemTelemetrySnapshot: Codable {
    public let cpu: CPUSnapshot
    public let gpu: GPUSnapshot?
    public let memory: MemorySnapshot
    public let swap: SwapSnapshot
    public let disk: DiskSnapshot
    public let diskIO: DiskIOSnapshot
    public let battery: BatterySnapshot?
    public let network: NetworkSnapshot
    public var volumes: [VolumeSnapshot] = []
}

public struct CPUSnapshot: Codable {
    public let cores: [CPUCoreSnapshot]
    public var performanceCoreCount: Int?
    public var efficiencyCoreCount: Int?
    public var loadAverage: [Double] = []
    public var processCount: Int?

    public var coreCount: Int {
        cores.count
    }

    public var totalUserTicks: UInt64 {
        cores.reduce(UInt64(0)) { $0 + $1.userTicks + $1.niceTicks }
    }

    public var totalSystemTicks: UInt64 {
        cores.reduce(UInt64(0)) { $0 + $1.systemTicks }
    }

    /// Apple Silicon numera primero los núcleos de eficiencia.
    public func coreKind(at index: Int) -> CPUCoreKind? {
        guard let efficiencyCoreCount, let performanceCoreCount,
              efficiencyCoreCount + performanceCoreCount == coreCount else {
            return nil
        }
        return index < efficiencyCoreCount ? .efficiency : .performance
    }

    public var totalActiveTicks: UInt64 {
        cores.reduce(UInt64(0)) { $0 + $1.activeTicks }
    }

    public var totalTicks: UInt64 {
        cores.reduce(UInt64(0)) { $0 + $1.totalTicks }
    }
}

public enum CPUCoreKind: String, Codable {
    case performance
    case efficiency
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
    public var pageInBytes: UInt64 = 0
    public var pageOutBytes: UInt64 = 0
    public var swapInBytes: UInt64 = 0
    public var swapOutBytes: UInt64 = 0
    public var uncompressedInCompressorBytes: UInt64 = 0
    public var isAvailable: Bool { totalBytes > 0 }

    public var compressionRatio: Double? {
        guard compressedBytes > 0, uncompressedInCompressorBytes > compressedBytes else { return nil }
        return Double(uncompressedInCompressorBytes) / Double(compressedBytes)
    }

    public var usedRatio: Double {
        guard totalBytes > 0 else {
            return 0
        }
        return Double(usedBytes) / Double(totalBytes)
    }

    public var pressureDescription: String {
        switch pressureLevel {
        case ..<0: return "sin lectura"
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
    public var designCycleCount: Int?
    public var voltageMillivolts: Int?
    public var amperageMilliamps: Int?
    public var timeToFullMinutes: Int?
    public var timeToEmptyMinutes: Int?
    public var currentCapacityMah: Int?
    public var fullChargeCapacityMah: Int?
    public var adapter: PowerAdapterSnapshot?
    public var systemPowerInMilliwatts: Int?
    public var systemLoadMilliwatts: Int?
    public var notChargingReason: Int?
    public var condition: String?

    public var healthPercent: Int? {
        guard let designCapacity, let maxCapacity, designCapacity > 0 else {
            return nil
        }
        return min(100, max(0, Int((Double(maxCapacity) / Double(designCapacity) * 100).rounded())))
    }

    /// Positiva cuando entra energía en la batería y negativa cuando se descarga.
    public var batteryPowerWatts: Double? {
        guard let voltageMillivolts, let amperageMilliamps, voltageMillivolts > 0 else { return nil }
        return Double(voltageMillivolts) * Double(amperageMilliamps) / 1_000_000
    }

    public var systemPowerInWatts: Double? {
        systemPowerInMilliwatts.map { Double($0) / 1_000 }
    }

    public var systemLoadWatts: Double? {
        systemLoadMilliwatts.map { Double($0) / 1_000 }
    }

    /// Conectado pero sin cargar ni completa: suele ser carga optimizada o límite térmico.
    public var isChargingPaused: Bool {
        externalConnected && !isCharging && !isCharged
    }
}

public struct PowerAdapterSnapshot: Codable {
    public let name: String?
    public let watts: Int?
    public let voltageMillivolts: Int?
    public let currentMilliamps: Int?
    public let manufacturer: String?
    public let isWireless: Bool
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

public enum NetworkInterfaceKind: String, Codable {
    case wifi
    case ethernet
    case vpn
    case other
}

public struct NetworkInterfaceSnapshot: Codable, Identifiable {
    public var id: String { name }

    public let name: String
    public let displayName: String
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public var kind: NetworkInterfaceKind = .other
    public var ipv4Addresses: [String] = []
    public var ipv6Addresses: [String] = []
    public var macAddress: String?
    public var linkSpeedBitsPerSecond: UInt64?
    public var mtu: Int?
    public var receivedPackets: UInt64 = 0
    public var sentPackets: UInt64 = 0
    public var inputErrors: UInt64 = 0
    public var outputErrors: UInt64 = 0
}

public struct VolumeSnapshot: Codable, Identifiable {
    public var id: String { path }

    public let name: String
    public let path: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let format: String?
    public let isInternal: Bool
    public let isEjectable: Bool
    public let isRootVolume: Bool
    public let isReadOnly: Bool

    public var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }

    public var usedRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
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
            network: networkSnapshot(),
            volumes: volumeSnapshots()
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
            network: networkSnapshot(),
            volumes: previous?.volumes ?? []
        )
    }

    private static func cpuSnapshot() -> CPUSnapshot {
        var snapshot = CPUSnapshot(cores: coreSnapshots())
        snapshot.performanceCoreCount = sysctlInt("hw.perflevel0.logicalcpu")
        snapshot.efficiencyCoreCount = (sysctlInt("hw.nperflevels") ?? 1) > 1 ? sysctlInt("hw.perflevel1.logicalcpu") : nil
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 {
            snapshot.loadAverage = loads
        }
        let processCount = proc_listallpids(nil, 0)
        snapshot.processCount = processCount > 0 ? Int(processCount) : nil
        return snapshot
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func coreSnapshots() -> [CPUCoreSnapshot] {
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
            return []
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

        return cores
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
                totalBytes: 0,
                usedBytes: 0,
                freeBytes: 0,
                appBytes: 0,
                wiredBytes: 0,
                compressedBytes: 0,
                cachedFilesBytes: 0,
                pressureLevel: -1
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

        var snapshot = MemorySnapshot(
            totalBytes: total,
            usedBytes: usedBytes,
            freeBytes: freeBytes,
            appBytes: appBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            pressureLevel: memoryPressureLevel()
        )
        snapshot.pageInBytes = UInt64(stats.pageins) &* pageSize
        snapshot.pageOutBytes = UInt64(stats.pageouts) &* pageSize
        snapshot.swapInBytes = UInt64(stats.swapins) &* pageSize
        snapshot.swapOutBytes = UInt64(stats.swapouts) &* pageSize
        snapshot.uncompressedInCompressorBytes = UInt64(stats.total_uncompressed_pages_in_compressor) &* pageSize
        return snapshot
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

    private static func volumeSnapshots() -> [VolumeSnapshot] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsRootFileSystemKey,
            .volumeIsReadOnlyKey,
            .volumeIsBrowsableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        return urls.compactMap { url -> VolumeSnapshot? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else {
                return nil
            }
            let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
            let available = isRoot
                ? values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
                : nil
            return VolumeSnapshot(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                totalBytes: UInt64(total),
                availableBytes: available ?? UInt64(max(values.volumeAvailableCapacity ?? 0, 0)),
                format: values.volumeLocalizedFormatDescription,
                isInternal: values.volumeIsInternal ?? isRoot,
                isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
                isRootVolume: isRoot,
                isReadOnly: values.volumeIsReadOnly ?? false
            )
        }
        .sorted { lhs, rhs in
            if lhs.isRootVolume != rhs.isRootVolume { return lhs.isRootVolume }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
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

        let batteryData = properties["BatteryData"] as? [String: Any]
        func capacityValue(_ key: String) -> Int? {
            intValue(properties[key]) ?? intValue(batteryData?[key])
        }

        let currentCapacity = intValue(properties["CurrentCapacity"])
        let maxCapacityPercent = intValue(properties["MaxCapacity"])
        let rawCurrentCapacity = capacityValue("AppleRawCurrentCapacity")
        let rawMaxCapacity = capacityValue("AppleRawMaxCapacity")
            ?? capacityValue("FullChargeCapacity")
            ?? capacityValue("NominalChargeCapacity")
        let designCapacity = capacityValue("DesignCapacity")
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

        let isCharging = boolValue(properties["IsCharging"])
        let externalConnected = boolValue(properties["ExternalConnected"])
        let chargerData = properties["ChargerData"] as? [String: Any]
        let telemetry = properties["PowerTelemetryData"] as? [String: Any]

        var snapshot = BatterySnapshot(
            percent: min(max(percent, 0), 100),
            isCharging: isCharging,
            isCharged: boolValue(properties["FullyCharged"]),
            externalConnected: externalConnected,
            cycleCount: intValue(properties["CycleCount"]),
            designCapacity: designCapacity,
            maxCapacity: rawMaxCapacity,
            temperatureCelsius: intValue(properties["Temperature"]).map { Double($0) / 100.0 }
        )
        snapshot.designCycleCount = intValue(properties["DesignCycleCount9C"])
        snapshot.voltageMillivolts = intValue(properties["AppleRawBatteryVoltage"]) ?? intValue(properties["Voltage"])
        snapshot.amperageMilliamps = (intValue(properties["InstantAmperage"]) ?? intValue(properties["Amperage"])).map(signedMilliamps)
        snapshot.timeToFullMinutes = isCharging ? validMinutes(properties["AvgTimeToFull"]) : nil
        snapshot.timeToEmptyMinutes = externalConnected
            ? nil
            : validMinutes(properties["AvgTimeToEmpty"]) ?? validMinutes(properties["TimeRemaining"])
        snapshot.currentCapacityMah = rawCurrentCapacity ?? intValue(batteryData?["RemainingCapacity"])
        snapshot.fullChargeCapacityMah = intValue(batteryData?["FullChargeCapacity"]) ?? rawMaxCapacity
        snapshot.notChargingReason = intValue(chargerData?["NotChargingReason"]).flatMap { $0 == 0 ? nil : $0 }
        if externalConnected {
            snapshot.systemPowerInMilliwatts = positiveInt(telemetry?["SystemPowerIn"])
            snapshot.adapter = adapterSnapshot(properties["AdapterDetails"] as? [String: Any])
        }
        snapshot.systemLoadMilliwatts = positiveInt(telemetry?["SystemLoad"])
        snapshot.condition = batteryCondition()
        return snapshot
    }

    private static func adapterSnapshot(_ details: [String: Any]?) -> PowerAdapterSnapshot? {
        guard let details else { return nil }
        let name = (details["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (details["Description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let watts = positiveInt(details["Watts"])
        guard name != nil || watts != nil else { return nil }
        return PowerAdapterSnapshot(
            name: name,
            watts: watts,
            voltageMillivolts: positiveInt(details["AdapterVoltage"]),
            currentMilliamps: positiveInt(details["Current"]),
            manufacturer: details["Manufacturer"] as? String,
            isWireless: boolValue(details["IsWireless"])
        )
    }

    /// Condición que muestra Información del Sistema ("Normal", "Servicio recomendado"...).
    private static func batteryCondition() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
                continue
            }
            if let condition = description["BatteryHealthCondition"] as? String, !condition.isEmpty {
                return condition
            }
            return description[kIOPSBatteryHealthKey] as? String
        }
        return nil
    }

    private static func validMinutes(_ value: Any?) -> Int? {
        guard let minutes = intValue(value), minutes > 0, minutes < 65_535 else { return nil }
        return minutes
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = intValue(value), number > 0 else { return nil }
        return number
    }

    /// Algunos firmwares publican la corriente de descarga como entero sin signo de 32 bits.
    public static func signedMilliamps(_ value: Int) -> Int {
        if value > Int(Int32.max), value <= Int(UInt32.max) {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return value
    }

    private static func networkSnapshot() -> NetworkSnapshot {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return NetworkSnapshot(interfaces: [])
        }
        defer { freeifaddrs(pointer) }

        let counters64 = interfaceCounters64()
        let addresses = interfaceAddresses(first)
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
            let counters = counters64[name]
            let received = counters?.ifi_ibytes ?? UInt64(ifData.ifi_ibytes)
            let sent = counters?.ifi_obytes ?? UInt64(ifData.ifi_obytes)
            guard received > 0 || sent > 0 else {
                continue
            }

            let presentation = interfacePresentation(name)
            var interface = NetworkInterfaceSnapshot(
                name: name,
                displayName: presentation.displayName,
                receivedBytes: received,
                sentBytes: sent
            )
            interface.kind = presentation.kind
            interface.ipv4Addresses = addresses[name]?.ipv4 ?? []
            interface.ipv6Addresses = addresses[name]?.ipv6 ?? []
            interface.macAddress = linkAddress(address)
            let baudrate = counters?.ifi_baudrate ?? UInt64(ifData.ifi_baudrate)
            interface.linkSpeedBitsPerSecond = baudrate > 0 ? baudrate : nil
            interface.mtu = Int(counters?.ifi_mtu ?? ifData.ifi_mtu)
            interface.receivedPackets = counters?.ifi_ipackets ?? UInt64(ifData.ifi_ipackets)
            interface.sentPackets = counters?.ifi_opackets ?? UInt64(ifData.ifi_opackets)
            interface.inputErrors = counters?.ifi_ierrors ?? UInt64(ifData.ifi_ierrors)
            interface.outputErrors = counters?.ifi_oerrors ?? UInt64(ifData.ifi_oerrors)
            interfaces.append(interface)
        }

        return NetworkSnapshot(
            interfaces: interfaces.sorted {
                ($0.receivedBytes + $0.sentBytes) > ($1.receivedBytes + $1.sentBytes)
            }
        )
    }

    /// `if_data` de getifaddrs usa contadores de 32 bits que dan la vuelta cada 4 GB.
    private static func interfaceCounters64() -> [String: if_data64] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: if_data64] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                        result[String(cString: nameBuffer)] = message.ifm_data
                    }
                }
                offset += messageLength
            }
        }
        return result
    }

    private static func interfaceAddresses(_ first: UnsafeMutablePointer<ifaddrs>) -> [String: (ipv4: [String], ipv6: [String])] {
        var result: [String: (ipv4: [String], ipv6: [String])] = [:]
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let name = String(cString: item.pointee.ifa_name)
            var entry = result[name] ?? ([], [])
            if family == AF_INET {
                entry.ipv4.append(text)
            } else if !text.hasPrefix("fe80") {
                entry.ipv6.append(text)
            }
            result[name] = entry
        }
        return result
    }

    private static func linkAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { pointer -> String? in
            let link = pointer.pointee
            guard link.sdl_alen == 6 else { return nil }
            let bytes = withUnsafeBytes(of: link.sdl_data) { raw in
                Array(raw[Int(link.sdl_nlen)..<Int(link.sdl_nlen) + 6])
            }
            guard bytes.contains(where: { $0 != 0 }) else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    private static let interfaceNameLock = NSLock()
    private static var interfaceNames: [String: (displayName: String, kind: NetworkInterfaceKind)] = [:]
    private static var interfaceNamesDate: Date?

    private static func interfacePresentation(_ name: String) -> (displayName: String, kind: NetworkInterfaceKind) {
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
            return ("VPN \(name)", .vpn)
        }

        interfaceNameLock.lock()
        defer { interfaceNameLock.unlock() }
        let isStale = interfaceNamesDate.map { Date().timeIntervalSince($0) > 30 } ?? true
        if interfaceNamesDate == nil || (interfaceNames[name] == nil && isStale) {
            interfaceNames = systemConfigurationInterfaceNames()
            interfaceNamesDate = Date()
        }
        return interfaceNames[name] ?? (name, .other)
    }

    private static func systemConfigurationInterfaceNames() -> [String: (displayName: String, kind: NetworkInterfaceKind)] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: (displayName: String, kind: NetworkInterfaceKind)] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsdName
            let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
            let kind: NetworkInterfaceKind
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                kind = .wifi
            } else if type == (kSCNetworkInterfaceTypeEthernet as String) {
                kind = .ethernet
            } else {
                kind = .other
            }
            result[bsdName] = (displayName, kind)
        }
        return result
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
            return -1
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

        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
            return true
        }

        return false
    }
}
