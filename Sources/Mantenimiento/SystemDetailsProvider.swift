import CoreWLAN
import Foundation
import Network
import SystemConfiguration

struct WiFiDetails: Equatable {
    let interfaceName: String
    let isPoweredOn: Bool
    let ssid: String?
    let rssi: Int?
    let noise: Int?
    let transmitRateMbps: Double?
    let channel: Int?
    let band: String?
    let channelWidth: String?
    let standard: String?
    let security: String?

    var signalToNoise: Int? {
        guard let rssi, let noise, rssi != 0, noise != 0 else { return nil }
        return rssi - noise
    }

    var signalQuality: String? {
        guard let rssi, rssi != 0 else { return nil }
        switch rssi {
        case (-55)...: return "Excelente"
        case (-67)...: return "Buena"
        case (-75)...: return "Regular"
        default: return "Débil"
        }
    }
}

struct NetworkRouteDetails: Equatable {
    let primaryInterface: String?
    let router: String?
    let dnsServers: [String]
}

struct ConnectivityDetails: Equatable {
    let isConnected: Bool
    let isExpensive: Bool
    let isConstrained: Bool
    let latencyMilliseconds: Double?
    let checkedAt: Date?
}

struct StorageDeviceDetails: Equatable {
    let mediaName: String?
    let busProtocol: String?
    let smartStatus: String?
    let isSolidState: Bool?
    let fileSystem: String?
    let isEncrypted: Bool?
    let deviceNode: String?
    let containerFreeBytes: UInt64?
    let physicalSizeBytes: UInt64?
}

struct HardwareDetails: Equatable {
    let modelName: String?
    let modelIdentifier: String?
    let modelNumber: String?
    let chip: String?
    let coreSummary: String?
    let memory: String?
    let firmware: String?
}

struct SecurityDetails: Equatable {
    let systemIntegrityProtection: Bool?
    let fileVault: Bool?
    let gatekeeper: Bool?
    let firewall: Bool?
}

struct OperatingSystemDetails: Equatable {
    let version: String
    let build: String?
    let bootDate: Date?
}

/// Lecturas lentas o que lanzan procesos externos; se cachean y nunca se ejecutan en el hilo principal.
final class SystemDetailsProvider {
    static let shared = SystemDetailsProvider()

    private let lock = NSLock()
    private var hardwareCache: HardwareDetails?
    private var securityCache: (value: SecurityDetails, date: Date)?
    private var storageCache: [String: (value: StorageDeviceDetails, date: Date)] = [:]
    private var connectivity = ConnectivityDetails(isConnected: true, isExpensive: false, isConstrained: false, latencyMilliseconds: nil, checkedAt: nil)
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "local.marc.mantenimiento.path", qos: .utility)
    private var isMeasuringLatency = false

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            connectivity = ConnectivityDetails(
                isConnected: path.status == .satisfied,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                latencyMilliseconds: path.status == .satisfied ? connectivity.latencyMilliseconds : nil,
                checkedAt: connectivity.checkedAt
            )
            lock.unlock()
        }
        pathMonitor.start(queue: monitorQueue)
    }

    // MARK: Red

    func wifiDetails() -> WiFiDetails? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let channel = interface.wlanChannel()
        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        let rate = interface.transmitRate()
        return WiFiDetails(
            interfaceName: interface.interfaceName ?? "en0",
            isPoweredOn: interface.powerOn(),
            ssid: interface.ssid(),
            rssi: rssi == 0 ? nil : rssi,
            noise: noise == 0 ? nil : noise,
            transmitRateMbps: rate > 0 ? rate : nil,
            channel: channel.map { $0.channelNumber },
            band: channel.flatMap { bandDescription($0.channelBand) },
            channelWidth: channel.flatMap { widthDescription($0.channelWidth) },
            standard: phyModeDescription(interface.activePHYMode()),
            security: securityDescription(interface.security())
        )
    }

    func routeDetails() -> NetworkRouteDetails {
        let store = SCDynamicStoreCreate(nil, "Mantenimiento" as CFString, nil, nil)
        let ipv4 = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) as? [String: Any] }
        return NetworkRouteDetails(
            primaryInterface: ipv4?["PrimaryInterface"] as? String,
            router: ipv4?["Router"] as? String,
            dnsServers: dns?["ServerAddresses"] as? [String] ?? []
        )
    }

    func currentConnectivity() -> ConnectivityDetails {
        lock.lock()
        defer { lock.unlock() }
        return connectivity
    }

    /// Tiempo de apertura TCP contra un resolvedor público; no envía datos.
    func measureLatency(completion: @escaping (ConnectivityDetails) -> Void) {
        lock.lock()
        guard !isMeasuringLatency else {
            let current = connectivity
            lock.unlock()
            completion(current)
            return
        }
        isMeasuringLatency = true
        lock.unlock()

        let connection = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        let start = DispatchTime.now()
        var finished = false
        let finish: (Double?) -> Void = { [weak self] latency in
            guard let self, !finished else { return }
            finished = true
            connection.cancel()
            lock.lock()
            connectivity = ConnectivityDetails(
                isConnected: connectivity.isConnected,
                isExpensive: connectivity.isExpensive,
                isConstrained: connectivity.isConstrained,
                latencyMilliseconds: latency,
                checkedAt: Date()
            )
            isMeasuringLatency = false
            let result = connectivity
            lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            case .failed, .waiting:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: monitorQueue)
        monitorQueue.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }

    // MARK: Disco

    func storageDetails(forVolumeAt path: String, maxAge: TimeInterval = 600) -> StorageDeviceDetails? {
        lock.lock()
        if let cached = storageCache[path], Date().timeIntervalSince(cached.date) < maxAge {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        guard let plist = diskutilInfo(path) else { return nil }

        // Un volumen APFS no tiene modelo propio: está en el disco físico que hay debajo del contenedor.
        var wholeDisk: [String: Any]?
        if (plist["MediaName"] as? String).map({ $0.isEmpty }) ?? true,
           let store = (plist["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String,
           let parent = diskutilInfo(store)?["ParentWholeDisk"] as? String {
            wholeDisk = diskutilInfo(parent)
        }
        let mediaName = [plist["MediaName"], wholeDisk?["MediaName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty }

        let details = StorageDeviceDetails(
            mediaName: mediaName,
            busProtocol: plist["BusProtocol"] as? String,
            smartStatus: plist["SMARTStatus"] as? String ?? wholeDisk?["SMARTStatus"] as? String,
            isSolidState: plist["SolidState"] as? Bool,
            fileSystem: plist["FilesystemName"] as? String ?? plist["FilesystemUserVisibleName"] as? String,
            isEncrypted: plist["FileVault"] as? Bool ?? plist["Encryption"] as? Bool,
            deviceNode: plist["DeviceNode"] as? String,
            containerFreeBytes: (plist["APFSContainerFree"] as? NSNumber)?.uint64Value,
            physicalSizeBytes: (wholeDisk?["TotalSize"] as? NSNumber)?.uint64Value
        )
        lock.lock()
        storageCache[path] = (details, Date())
        lock.unlock()
        return details
    }

    // MARK: Sistema

    func operatingSystemDetails() -> OperatingSystemDetails {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.stride
        let bootDate = sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0
            ? Date(timeIntervalSince1970: TimeInterval(bootTime.tv_sec))
            : nil
        return OperatingSystemDetails(
            version: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            build: sysctlString("kern.osversion"),
            bootDate: bootDate
        )
    }

    func hardwareDetails() -> HardwareDetails? {
        lock.lock()
        if let hardwareCache {
            lock.unlock()
            return hardwareCache
        }
        lock.unlock()

        let output = ExternalCommandRunner.capture(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPHardwareDataType", "-json", "-detailLevel", "mini"],
            timeout: 8
        )
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = (root["SPHardwareDataType"] as? [[String: Any]])?.first else {
            return nil
        }

        let details = HardwareDetails(
            modelName: item["machine_name"] as? String,
            modelIdentifier: item["machine_model"] as? String,
            modelNumber: item["model_number"] as? String,
            chip: item["chip_type"] as? String ?? item["cpu_type"] as? String,
            coreSummary: (item["number_processors"] as? String).map(coreSummary),
            memory: item["physical_memory"] as? String,
            firmware: item["boot_rom_version"] as? String
        )
        lock.lock()
        hardwareCache = details
        lock.unlock()
        return details
    }

    func securityDetails(maxAge: TimeInterval = 300) -> SecurityDetails {
        lock.lock()
        if let securityCache, Date().timeIntervalSince(securityCache.date) < maxAge {
            lock.unlock()
            return securityCache.value
        }
        lock.unlock()

        let sip = ExternalCommandRunner.capture(executable: "/usr/bin/csrutil", arguments: ["status"], timeout: 2).lowercased()
        let fileVault = ExternalCommandRunner.capture(executable: "/usr/bin/fdesetup", arguments: ["status"], timeout: 2).lowercased()
        let gatekeeper = ExternalCommandRunner.capture(executable: "/usr/sbin/spctl", arguments: ["--status"], timeout: 2).lowercased()
        let firewall = ExternalCommandRunner.capture(
            executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getglobalstate"],
            timeout: 2
        ).lowercased()

        let details = SecurityDetails(
            systemIntegrityProtection: sip.contains("enabled") ? true : sip.contains("disabled") ? false : nil,
            fileVault: fileVault.contains("is on") ? true : fileVault.contains("is off") ? false : nil,
            gatekeeper: gatekeeper.contains("assessments enabled") ? true : gatekeeper.contains("disabled") ? false : nil,
            firewall: firewall.contains("enabled") ? true : firewall.contains("disabled") ? false : nil
        )
        lock.lock()
        securityCache = (details, Date())
        lock.unlock()
        return details
    }

    // MARK: Utilidades

    private func diskutilInfo(_ target: String) -> [String: Any]? {
        let output = ExternalCommandRunner.capture(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", target], timeout: 3)
        guard let data = output.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// system_profiler publica "proc total:…:rendimiento:eficiencia".
    func coreSummary(_ raw: String) -> String {
        let parts = raw.replacingOccurrences(of: "proc ", with: "").split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 3, let total = parts.first else { return raw }
        let performance = parts[parts.count - 2]
        let efficiency = parts[parts.count - 1]
        return "\(total) (\(performance) de rendimiento y \(efficiency) de eficiencia)"
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private func bandDescription(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2,4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return nil
        }
    }

    private func widthDescription(_ width: CWChannelWidth) -> String? {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return nil
        }
    }

    private func phyModeDescription(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11ax: return "Wi-Fi 6 (802.11ax)"
        default:
            return mode.rawValue == 7 ? "Wi-Fi 7 (802.11be)" : nil
        }
    }

    private func securityDescription(_ security: CWSecurity) -> String? {
        switch security {
        case .none: return "Abierta"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .personal: return "WPA2/WPA3 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .enterprise: return "Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .OWE, .oweTransition: return "OWE"
        default: return nil
        }
    }
}
