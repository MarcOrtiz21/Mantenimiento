import Darwin
import Foundation

enum PrivilegedHelperClient {
    static let socketPath = "/var/run/local.marc.mantenimiento.helper.sock"

    static func run(arguments: [String]) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PrivilegedHelperClientError.unavailable
        }
        defer { close(fd) }

        applyTimeouts(to: fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try copyPath(socketPath, into: &address)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw PrivilegedHelperClientError.unavailable
        }

        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == 0 else {
            throw PrivilegedHelperClientError.unavailable
        }

        let command = arguments.joined(separator: " ") + "\n"
        let bytes = Array(command.utf8)
        try writeAll(bytes, to: fd)
        shutdown(fd, SHUT_WR)

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let response = String(data: handle.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if response.hasPrefix("OK ") {
            return String(response.dropFirst(3))
        }

        if response.hasPrefix("ERR ") {
            throw PrivilegedHelperClientError.rejected(String(response.dropFirst(4)))
        }

        throw PrivilegedHelperClientError.rejected(response)
    }

    private static func copyPath(_ path: String, into address: inout sockaddr_un) throws {
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw PrivilegedHelperClientError.unavailable
        }

        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            path.withCString {
                strncpy(pointer, $0, maxLength)
            }
        }
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw PrivilegedHelperClientError.unavailable
            }

            var offset = 0
            while offset < bytes.count {
                let result = write(fd, baseAddress.advanced(by: offset), bytes.count - offset)
                guard result > 0 else {
                    throw PrivilegedHelperClientError.unavailable
                }
                offset += result
            }
        }
    }

    private static func applyTimeouts(to fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafePointer(to: &timeout) { pointer in
            let rawPointer = UnsafeRawPointer(pointer)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rawPointer, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, rawPointer, socklen_t(MemoryLayout<timeval>.size))
        }
    }
}

enum PrivilegedHelperClientError: LocalizedError {
    case unavailable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Helper privilegiado no disponible."
        case .rejected(let message):
            return message.isEmpty ? "El helper rechazó la operación." : message
        }
    }
}
