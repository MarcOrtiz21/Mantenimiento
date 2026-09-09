import Foundation
import IOKit

public enum SMCCommand: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

public enum SMCResultCode: UInt8, CustomStringConvertible {
    case success = 0x00
    case error = 0x01
    case commCollision = 0x80
    case spuriousData = 0x81
    case badCommand = 0x82
    case badParameter = 0x83
    case notFound = 0x84
    case notReadable = 0x85
    case notWritable = 0x86
    case keySizeMismatch = 0x87
    case framingError = 0x88
    case badArgumentError = 0x89

    public var description: String {
        switch self {
        case .success:
            return "success"
        case .error:
            return "error"
        case .commCollision:
            return "communication collision"
        case .spuriousData:
            return "spurious data"
        case .badCommand:
            return "bad command"
        case .badParameter:
            return "bad parameter"
        case .notFound:
            return "not found"
        case .notReadable:
            return "not readable"
        case .notWritable:
            return "not writable"
        case .keySizeMismatch:
            return "key size mismatch"
        case .framingError:
            return "framing error"
        case .badArgumentError:
            return "bad argument"
        }
    }
}

public enum SMCError: LocalizedError {
    case connectionFailed
    case invalidKey(String)
    case ioKit(kern_return_t)
    case firmware(SMCResultCode)
    case timeout
    case noFans

    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "No se pudo abrir AppleSMC."
        case .invalidKey(let key):
            return "La clave SMC '\(key)' no es valida."
        case .ioKit(let code):
            if code == kIOReturnNotPrivileged {
                return "macOS bloqueo la escritura SMC por privilegios. Hace falta helper privilegiado."
            }
            return "IOKit devolvio 0x\(String(code, radix: 16))."
        case .firmware(let code):
            return "SMC rechazó la operación: \(code)."
        case .timeout:
            return "Se agoto el tiempo esperando control manual del ventilador."
        case .noFans:
            return "No se encontraron ventiladores SMC en este Mac."
        }
    }

    public var requiresPrivileges: Bool {
        if case .ioKit(let code) = self {
            return code == kIOReturnNotPrivileged
        }
        return false
    }
}

public struct SMCParamStruct {
    public typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    public struct Version {
        public var major: UInt8 = 0
        public var minor: UInt8 = 0
        public var build: UInt8 = 0
        public var reserved: UInt8 = 0
        public var release: UInt16 = 0
    }

    public struct PLimitData {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
    }

    public struct KeyInfo {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
    }

    public var key: UInt32 = 0
    public var vers = Version()
    public var pLimitData = PLimitData()
    public var keyInfo = KeyInfo()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: Bytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}
