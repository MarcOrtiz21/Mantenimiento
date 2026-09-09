import Foundation
import MantenimientoCore

@main
struct MantenimientoFanTool {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }

        let service = try FanService.make()

        switch command {
        case "list-json":
            let snapshot = try service.snapshot()
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))

        case "sensors-json":
            let snapshot = try SensorService.make().snapshot()
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))

        case "system-json":
            let snapshot = SystemTelemetryService.snapshot()
            let data = try JSONEncoder.pretty.encode(snapshot)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))

        case "set":
            guard args.count == 3, let fan = Int(args[1]), let rpm = Float(args[2]) else {
                throw ToolError.invalidArguments
            }
            let strategy = try service.setFanRPM(index: fan, rpm: rpm)
            print("fan \(fan) set to \(Int(rpm)) rpm (\(strategy.rawValue))")

        case "auto":
            guard args.count == 2, let fan = Int(args[1]) else {
                throw ToolError.invalidArguments
            }
            try service.setFanAuto(index: fan)
            print("fan \(fan) returned to auto")

        case "auto-all":
            try service.setAllFansAuto()
            print("all fans returned to auto")

        case "turbo":
            try service.setAllFansToMaximum()
            print("all fans set to maximum")

        default:
            printUsage()
        }
    }

    private static func printUsage() {
        print("""
        uso:
          mantenimiento-fanctl list-json
          mantenimiento-fanctl sensors-json
          mantenimiento-fanctl system-json
          mantenimiento-fanctl set <fan> <rpm>
          mantenimiento-fanctl auto <fan>
          mantenimiento-fanctl auto-all
          mantenimiento-fanctl turbo
        """)
    }
}

private enum ToolError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
        "Argumentos invalidos."
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
