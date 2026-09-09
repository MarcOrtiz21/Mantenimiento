import Foundation

public enum SMCDataFormat {
    public static func float(from bytes: [UInt8], size: UInt32) -> Float {
        if size == 4, bytes.count >= 4 {
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }

        if bytes.count >= 2 {
            return Float(uint16(from: bytes)) / 4.0
        }

        return 0
    }

    public static func bytes(from value: Float, size: UInt32) -> [UInt8] {
        if size == 4 {
            return withUnsafeBytes(of: value) { Array($0.prefix(4)) }
        }

        let raw = UInt16(max(0, value) * 4.0)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    public static func uint8(from bytes: [UInt8]) -> UInt8 {
        bytes.first ?? 0
    }

    public static func uint16(from bytes: [UInt8]) -> UInt16 {
        guard bytes.count >= 2 else {
            return 0
        }

        return bytes.withUnsafeBytes {
            UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
        }
    }

    public static func uint32(from bytes: [UInt8]) -> UInt32 {
        guard bytes.count >= 4 else {
            return 0
        }

        return bytes.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }
}
