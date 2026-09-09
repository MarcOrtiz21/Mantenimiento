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

        guard !clientCertificateSHA1.isEmpty else {
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

    init(config: HelperConfig) {
        self.config = config
    }

    func run() throws {
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

        chown(config.socketPath, config.ownerUID, gid_t.max)
        chmod(config.socketPath, S_IRUSR | S_IWUSR)

        guard listen(serverFD, 8) == 0 else {
            throw HelperError.posix("listen")
        }

        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async {
                self.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }

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
            let command = try readCommand(from: clientFD)
            let response = try execute(command)
            writeLine("OK \(response)", to: clientFD)
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

    private func execute(_ command: String) throws -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let name = parts.first else {
            throw HelperError.invalidCommand
        }

        let service = try FanService.make()

        switch name {
        case "ping":
            return "pong"

        case "turbo":
            try service.setAllFansToMaximum()
            return "turbo"

        case "auto-all":
            try service.setAllFansAuto()
            return "auto-all"

        case "set" where parts.count == 3:
            guard let index = Int(parts[1]), index >= 0,
                  let rpm = Float(parts[2]), rpm.isFinite, rpm > 0
            else {
                throw HelperError.invalidCommand
            }
            _ = try service.setFanRPM(index: index, rpm: rpm)
            return "set \(index) \(Int(rpm))"

        case "auto" where parts.count == 2:
            guard let index = Int(parts[1]), index >= 0 else {
                throw HelperError.invalidCommand
            }
            try service.setFanAuto(index: index)
            return "auto \(index)"

        default:
            throw HelperError.invalidCommand
        }
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
    case invalidCommand
    case missingClientRequirement
    case pathTooLong
    case readFailed
    case requestTooLarge
    case posix(String)

    var errorDescription: String? {
        switch self {
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
