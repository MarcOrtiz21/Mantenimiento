import Darwin
import Foundation
import MantenimientoCore
import Security

@main
struct MantenimientoHelper {
    static func main() {
        do {
            let config = try HelperConfig.parse()
            try HelperServer(config: config).run()
        } catch {
            fputs("mantenimiento-helper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct HelperConfig {
    let socketPath: String
    let ownerUID: uid_t
    let clientPath: String
    let clientIdentifier: String
    let clientCertificateSHA1: String

    static func parse() throws -> HelperConfig {
        let args = Array(CommandLine.arguments.dropFirst())
        var socketPath = "/var/run/local.marc.mantenimiento.helper.sock"
        var ownerUID = getuid()
        var clientPath = "/Applications/Mantenimiento.app/Contents/MacOS/Mantenimiento"
        var clientIdentifier = "local.marc.mantenimiento"
        var clientCertificateSHA1 = ""
        var index = 0

        while index < args.count {
            switch args[index] {
            case "--socket" where index + 1 < args.count:
                socketPath = args[index + 1]
                index += 2
            case "--owner-uid" where index + 1 < args.count:
                ownerUID = uid_t(Int(args[index + 1]) ?? Int(getuid()))
                index += 2
            case "--client-path" where index + 1 < args.count:
                clientPath = args[index + 1]
                index += 2
            case "--client-identifier" where index + 1 < args.count:
                clientIdentifier = args[index + 1]
                index += 2
            case "--client-cert-sha1" where index + 1 < args.count:
                clientCertificateSHA1 = args[index + 1]
                index += 2
            default:
                index += 1
            }
        }

        guard clientCertificateSHA1.count == 40, clientCertificateSHA1.allSatisfy({ $0.isHexDigit }),
              clientIdentifier == "local.marc.mantenimiento" else {
            throw HelperError.missingClientRequirement
        }
        return HelperConfig(
            socketPath: socketPath,
            ownerUID: ownerUID,
            clientPath: clientPath,
            clientIdentifier: clientIdentifier,
            clientCertificateSHA1: clientCertificateSHA1
        )
    }
}

private final class HelperServer {
    private let config: HelperConfig
    private let controlQueue = DispatchQueue(label: "local.marc.mantenimiento.helper.control")
    private let clients = DispatchSemaphore(value: 8)
    private var watchdog: DispatchSourceTimer?
    private var lease = ManualFanLease()
    private let recoveryPath = "/var/run/local.marc.mantenimiento.helper.manual"
    private var recoveryPending = false
    private var responses: [UUID: (FanHelperRequest.Command, String)] = [:]
    private var responseOrder: [UUID] = []

    init(config: HelperConfig) {
        self.config = config
    }

    func run() throws {
        guard geteuid() == 0 else { throw HelperError.posix("root required") }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.setEventHandler { [weak self] in self?.checkLease() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        watchdog = timer
        recoveryPending = FileManager.default.fileExists(atPath: recoveryPath)
        if recoveryPending { controlQueue.async { self.recoverControl() } }
        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw HelperError.posix("socket")
        }
        defer { close(serverFD) }

        unlink(config.socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try copyPath(config.socketPath, into: &address)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw HelperError.posix("bind")
        }

        guard chown(config.socketPath, config.ownerUID, gid_t.max) == 0,
              chmod(config.socketPath, S_IRUSR | S_IWUSR) == 0 else { throw HelperError.posix("socket permissions") }

        guard listen(serverFD, 8) == 0 else {
            throw HelperError.posix("listen")
        }

        while true {
            clients.wait()
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                clients.signal()
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async {
                self.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD); clients.signal() }
        var noSIGPIPE: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == config.ownerUID else {
            writeLine("ERR unauthorized", to: clientFD)
            return
        }

        guard let peerPID = peerPID(for: clientFD), validateClient(pid: peerPID) else {
            writeLine("ERR invalid client", to: clientFD)
            return
        }

        do {
            let request = try FanHelperRequest.parse(readCommand(from: clientFD))
            let response = controlQueue.sync { process(request, pid: peerPID) }
            writeLine(response, to: clientFD)
        } catch {
            writeLine("ERR \(error.localizedDescription)", to: clientFD)
        }
    }

    private func peerPID(for fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
            return nil
        }
        return pid
    }

    private func validateClient(pid: pid_t) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
              String(cString: pathBuffer) == config.clientPath else {
            return false
        }

        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return false
        }

        let requirementText = "identifier \"\(config.clientIdentifier)\" and certificate leaf = H\"\(config.clientCertificateSHA1)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func readCommand(from fd: Int32) throws -> String {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let maximumSize = 256
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 128)

        while bytes.count <= maximumSize {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 {
                break
            }
            guard count > 0 else {
                throw HelperError.readFailed
            }
            bytes.append(contentsOf: buffer.prefix(count))
            if bytes.contains(10) {
                break
            }
        }

        guard bytes.count <= maximumSize else {
            throw HelperError.requestTooLarge
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw HelperError.invalidCommand
        }

        let lines = text.split(whereSeparator: \Character.isNewline)
        guard lines.count == 1 else {
            throw HelperError.invalidCommand
        }
        let command = String(lines[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw HelperError.invalidCommand
        }
        return command
    }

    private func process(_ request: FanHelperRequest, pid: pid_t) -> String {
        if let id = request.id, let cached = responses[id] {
            return cached.0 == request.command ? cached.1 : "ERR request ID reused"
        }
        let response: String
        do { response = "OK \(try execute(request.command, pid: pid))" }
        catch { response = "ERR \(error.localizedDescription)" }
        if let id = request.id {
            responses[id] = (request.command, response)
            responseOrder.append(id)
            if responseOrder.count > 64 { responses.removeValue(forKey: responseOrder.removeFirst()) }
        }
        return response
    }

    private func execute(_ command: FanHelperRequest.Command, pid: pid_t) throws -> String {
        switch command {
        case .ping: return FanHelperProtocol.greeting
        case .heartbeat:
            guard lease.renew(pid: pid, now: ProcessInfo.processInfo.systemUptime) else {
                throw HelperError.invalidCommand
            }
            return "heartbeat"
        default: break
        }
        if command.changesManualControl {
            guard !recoveryPending, lease.ownerPID == nil || lease.ownerPID == pid else {
                throw HelperError.controlBusy
            }
            // El marcador persiste si el helper cae antes de confirmar Auto.
            try Data("manual\n".utf8).write(to: URL(fileURLWithPath: recoveryPath), options: .atomic)
            guard chmod(recoveryPath, S_IRUSR | S_IWUSR) == 0 else { throw HelperError.posix("recovery marker") }
            lease.begin(pid: pid, now: ProcessInfo.processInfo.systemUptime)
            armWatchdog()
        }
        do {
            let service = try FanService.make()
            switch command {
            case .turbo: try service.setAllFansToMaximum()
            case .set(let index, let rpm): _ = try service.setFanRPM(index: index, rpm: rpm)
            case .autoAll:
                try service.setAllFansAuto()
                try clearRecoveryMarker()
            case .auto(let index):
                try service.setFanAuto(index: index)
                if try service.snapshot().isAutomaticControlConfirmed {
                    try clearRecoveryMarker()
                }
            default: break
            }
            if command.changesManualControl { lease.begin(pid: pid, now: ProcessInfo.processInfo.systemUptime) }
            return "applied"
        } catch {
            recoveryPending = true
            recoverControl()
            throw error
        }
    }

    private func armWatchdog() {
        watchdog?.schedule(deadline: .now() + 3, repeating: 3, leeway: .seconds(1))
    }

    private func checkLease() {
        let isAlive = lease.ownerPID.map { kill($0, 0) == 0 } ?? false
        if recoveryPending || lease.needsRecovery(now: ProcessInfo.processInfo.systemUptime, ownerIsAlive: isAlive) {
            recoverControl()
        }
    }

    private func recoverControl() {
        do {
            try FanService.make().setAllFansAuto()
            try clearRecoveryMarker()
        } catch {
            recoveryPending = true
            watchdog?.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
            fputs("Auto recovery pending: \(error.localizedDescription)\n", stderr)
        }
    }

    private func clearRecoveryMarker() throws {
        if FileManager.default.fileExists(atPath: recoveryPath) {
            try FileManager.default.removeItem(atPath: recoveryPath)
        }
        recoveryPending = false
        lease.clear()
        watchdog?.schedule(deadline: .distantFuture)
    }

    private func writeLine(_ line: String, to fd: Int32) {
        let data = Array((line + "\n").utf8)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < data.count {
                let count = write(fd, baseAddress.advanced(by: offset), data.count - offset)
                guard count > 0 else {
                    return
                }
                offset += count
            }
        }
    }

    private func copyPath(_ path: String, into address: inout sockaddr_un) throws {
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw HelperError.pathTooLong
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            path.withCString {
                strncpy(pointer, $0, maxLength)
            }
        }
    }
}

private enum HelperError: LocalizedError {
    case controlBusy
    case invalidCommand
    case missingClientRequirement
    case pathTooLong
    case readFailed
    case requestTooLarge
    case posix(String)

    var errorDescription: String? {
        switch self {
        case .controlBusy: return "Control ocupado o pendiente de recuperación a Auto."
        case .invalidCommand:
            return "Comando invalido."
        case .missingClientRequirement:
            return "Falta el requisito de firma del cliente."
        case .pathTooLong:
            return "La ruta del socket es demasiado larga."
        case .readFailed:
            return "No se pudo leer la peticion."
        case .requestTooLarge:
            return "Peticion demasiado grande."
        case .posix(let operation):
            return "\(operation) fallo: \(String(cString: strerror(errno)))."
        }
    }
}
