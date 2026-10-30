import Foundation

struct LaunchItem: Identifiable, Equatable {
    enum Scope: String, CaseIterable {
        case userAgent
        case globalAgent
        case daemon

        var title: String {
            switch self {
            case .userAgent: return "Agentes de tu usuario"
            case .globalAgent: return "Agentes para todos los usuarios"
            case .daemon: return "Servicios del sistema"
            }
        }

        var directory: String {
            switch self {
            case .userAgent: return NSHomeDirectory() + "/Library/LaunchAgents"
            case .globalAgent: return "/Library/LaunchAgents"
            case .daemon: return "/Library/LaunchDaemons"
            }
        }
    }

    var id: String { "\(scope.rawValue):\(label)" }
    let label: String
    let scope: Scope
    let plistURL: URL
    let programPath: String?
    let programExists: Bool
    let vendor: String
    let runsAtLoad: Bool
    let keepsAlive: Bool
    let isDisabled: Bool
    let isRunning: Bool

    /// El ejecutable al que apunta ya no existe: suele ser un resto de una app desinstalada.
    var isOrphaned: Bool { programPath != nil && !programExists }
}

/// Solo lectura: lista los LaunchAgents y LaunchDaemons de terceros instalados en el Mac.
enum LaunchItemsScanner {
    static func scan() -> [LaunchItem] {
        let userList = ExternalCommandRunner.capture(executable: "/bin/launchctl", arguments: ["list"], timeout: 2)
        let systemList = ExternalCommandRunner.capture(executable: "/bin/launchctl", arguments: ["print", "system"], timeout: 2)
        let running = runningLabels(userList: userList).union(runningSystemLabels(systemList))
        let uid = getuid()
        let disabled = disabledLabels(ExternalCommandRunner.capture(executable: "/bin/launchctl", arguments: ["print-disabled", "gui/\(uid)"], timeout: 2))
            .union(disabledLabels(ExternalCommandRunner.capture(executable: "/bin/launchctl", arguments: ["print-disabled", "system"], timeout: 2)))

        return LaunchItem.Scope.allCases.flatMap { scope -> [LaunchItem] in
            let directory = URL(fileURLWithPath: scope.directory, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "plist" }.compactMap { url in
                item(at: url, scope: scope, running: running, disabled: disabled)
            }
        }
        .sorted { ($0.vendor, $0.label) < ($1.vendor, $1.label) }
    }

    static func item(at url: URL, scope: LaunchItem.Scope, running: Set<String>, disabled: Set<String>) -> LaunchItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
        let keepAlive: Bool
        if let flag = plist["KeepAlive"] as? Bool {
            keepAlive = flag
        } else {
            keepAlive = plist["KeepAlive"] is [String: Any]
        }
        return LaunchItem(
            label: label,
            scope: scope,
            plistURL: url,
            programPath: program,
            programExists: program.map { FileManager.default.fileExists(atPath: $0) } ?? true,
            vendor: vendor(label: label, programPath: program),
            runsAtLoad: plist["RunAtLoad"] as? Bool ?? false,
            keepsAlive: keepAlive,
            isDisabled: (plist["Disabled"] as? Bool ?? false) || disabled.contains(label),
            isRunning: running.contains(label)
        )
    }

    private static let knownVendors: [(prefix: String, name: String)] = [
        ("org.chromium.chromoting", "Escritorio remoto de Chrome"),
        ("local.marc.mantenimiento", "Mantenimiento"),
        ("com.adobe", "Adobe"),
        ("com.google", "Google"),
        ("com.microsoft", "Microsoft"),
        ("com.nordvpn", "NordVPN"),
        ("com.logitech", "Logitech"),
        ("com.dropbox", "Dropbox"),
        ("com.docker", "Docker"),
        ("us.zoom", "Zoom"),
        ("com.spotify", "Spotify"),
        ("com.openai", "OpenAI")
    ]

    static func vendor(label: String, programPath: String?) -> String {
        if let known = knownVendors.first(where: { label.hasPrefix($0.prefix) }) {
            return known.name
        }
        if let programPath, let range = programPath.range(of: ".app/") {
            let appPath = String(programPath[..<range.lowerBound])
            return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        }
        let parts = label.split(separator: ".")
        guard parts.count >= 2 else { return label }
        return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
    }

    /// `launchctl list`: columnas PID, estado y etiqueta; PID "-" significa que no está en ejecución.
    static func runningLabels(userList: String) -> Set<String> {
        Set(userList.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t")
            guard fields.count == 3, Int(fields[0]) != nil else { return nil }
            return String(fields[2])
        })
    }

    /// `launchctl print system`: en el bloque `services` cada línea es PID, último estado y etiqueta.
    static func runningSystemLabels(_ output: String) -> Set<String> {
        var labels: Set<String> = []
        var inServices = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inServices = true; continue }
            if inServices && trimmed == "}" { break }
            guard inServices else { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 3, let pid = Int(fields[0]), pid > 0 {
                labels.insert(String(fields[fields.count - 1]))
            }
        }
        return labels
    }

    static func disabledLabels(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("disabled") || trimmed.hasSuffix("true"),
                  let end = trimmed.dropFirst().firstIndex(of: "\"") else {
                return nil
            }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        })
    }
}
