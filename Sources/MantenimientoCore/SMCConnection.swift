import Foundation
import IOKit

public final class SMCConnection {
    private let connection: io_connect_t

    public init() throws {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }

        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
            &iterator
        )

        guard result == kIOReturnSuccess else {
            throw SMCError.ioKit(result)
        }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            throw SMCError.connectionFailed
        }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        guard openResult == kIOReturnSuccess else {
            throw SMCError.ioKit(openResult)
        }

        connection = openedConnection
    }

    deinit {
        IOServiceClose(connection)
    }

    public func readKey(_ key: String) throws -> (bytes: [UInt8], size: UInt32) {
        let (param, output) = try fetchKeyInfo(key)

        var readParam = param
        readParam.keyInfo.dataSize = output.keyInfo.dataSize
        readParam.data8 = SMCCommand.readBytes.rawValue

        let readOutput = try callSMC(input: readParam)
        try validateFirmwareResult(readOutput.result)

        let bytes = withUnsafeBytes(of: readOutput.bytes) {
            Array($0.prefix(Int(output.keyInfo.dataSize)))
        }

        return (bytes, output.keyInfo.dataSize)
    }

    public func writeKey(_ key: String, bytes: [UInt8]) throws {
        let (param, output) = try fetchKeyInfo(key)

        var writeParam = param
        writeParam.data8 = SMCCommand.writeBytes.rawValue
        writeParam.keyInfo.dataSize = output.keyInfo.dataSize
        writeParam.bytes = bytesToTuple(bytes)

        let writeOutput = try callSMC(input: writeParam)
        try validateFirmwareResult(writeOutput.result)
    }

    public func fetchKeyInfo(_ key: String) throws -> (param: SMCParamStruct, output: SMCParamStruct) {
        var param = SMCParamStruct()
        param.key = try fourCharCode(from: key)
        param.data8 = SMCCommand.readKeyInfo.rawValue

        let output = try callSMC(input: param)
        try validateFirmwareResult(output.result)
        return (param, output)
    }

    private func callSMC(input: SMCParamStruct) throws -> SMCParamStruct {
        var input = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCCommand.kernelIndex.rawValue),
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess else {
            throw SMCError.ioKit(result)
        }

        return output
    }

    private func validateFirmwareResult(_ result: UInt8) throws {
        guard result != SMCResultCode.success.rawValue else {
            return
        }

        throw SMCError.firmware(SMCResultCode(rawValue: result) ?? .error)
    }

    private func fourCharCode(from string: String) throws -> UInt32 {
        guard string.utf8.count == 4 else {
            throw SMCError.invalidKey(string)
        }

        return string.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func bytesToTuple(_ array: [UInt8]) -> SMCParamStruct.Bytes32 {
        var padded = array + Array(repeating: 0, count: max(0, 32 - array.count))
        if padded.count > 32 {
            padded = Array(padded.prefix(32))
        }

        return (
            padded[0], padded[1], padded[2], padded[3],
            padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11],
            padded[12], padded[13], padded[14], padded[15],
            padded[16], padded[17], padded[18], padded[19],
            padded[20], padded[21], padded[22], padded[23],
            padded[24], padded[25], padded[26], padded[27],
            padded[28], padded[29], padded[30], padded[31]
        )
    }
}
