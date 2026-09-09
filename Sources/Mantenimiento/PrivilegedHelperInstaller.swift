import Darwin
import Foundation

enum PrivilegedHelperInstaller {
    static let label = "local.marc.mantenimiento.helper"
    static let socketPath = "/var/run/local.marc.mantenimiento.helper.sock"
    static let helperDestination = "/Library/PrivilegedHelperTools/local.marc.mantenimiento.helper"
    static let plistDestination = "/Library/LaunchDaemons/local.marc.mantenimiento.helper.plist"

    static var bundledHelperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools")
            .appendingPathComponent(label)
    }

    static func ping() -> String? {
        try? PrivilegedHelperClient.run(arguments: ["ping"])
    }

    static func isConnected() -> Bool {
        ping() != nil
    }

    static func install() throws {
        let helperURL = bundledHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw PrivilegedHelperInstallerError.missingBundle
        }

        try verifySignature(at: helperURL)

        let appURL = Bundle.main.bundleURL
        guard let executableURL = Bundle.main.executableURL else {
            throw PrivilegedHelperInstallerError.missingBundle
        }

        guard let certificateSHA1 = leafCertificateSHA1(for: appURL), !certificateSHA1.isEmpty else {
            throw PrivilegedHelperInstallerError.unsigned
        }

        let identifier = Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento"
        let ownerUID = getuid()
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mantenimiento-helper-\(UUID().uuidString).plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperDestination)</string>
                <string>--socket</string>
                <string>\(socketPath)</string>
                <string>--owner-uid</string>
                <string>\(ownerUID)</string>
                <string>--client-path</string>
                <string>\(executableURL.path)</string>
                <string>--client-identifier</string>
                <string>\(identifier)</string>
                <string>--client-cert-sha1</string>
                <string>\(certificateSHA1)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>/var/log/mantenimiento-helper.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/mantenimiento-helper.err</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: plistURL) }

        let script = """
        set -euo pipefail
        mkdir -p /Library/PrivilegedHelperTools
        cp \(shellQuoted(helperURL.path)) \(shellQuoted(helperDestination))
        chown root:wheel \(shellQuoted(helperDestination))
        chmod 755 \(shellQuoted(helperDestination))
        cp \(shellQuoted(plistURL.path)) \(shellQuoted(plistDestination))
        chown root:wheel \(shellQuoted(plistDestination))
        chmod 644 \(shellQuoted(plistDestination))
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootout system \(shellQuoted(plistDestination)) 2>/dev/null || true
        launchctl bootstrap system \(shellQuoted(plistDestination))
        launchctl enable system/\(label)
        launchctl kickstart -k system/\(label)
        """
        try runPrivileged(script)
    }

    static func uninstall() throws {
        let script = """
        set -euo pipefail
        launchctl bootout system/\(label) 2>/dev/null || true
        launchctl bootout system \(shellQuoted(plistDestination)) 2>/dev/null || true
        rm -f \(shellQuoted(plistDestination)) \(shellQuoted(helperDestination)) \(shellQuoted(socketPath))
        """
        try runPrivileged(script)
    }

    static func waitUntilConnected(attempts: Int = 10, interval: TimeInterval = 0.4) -> Bool {
        for _ in 0..<attempts {
            if isConnected() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return isConnected()
    }

    private static func verifySignature(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PrivilegedHelperInstallerError.unsigned
        }
    }

    private static func leafCertificateSHA1(for url: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "-r-", url.path]
        process.standardOutput = output
        process.standardError = output
        try? process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let regex = try? NSRegularExpression(pattern: #"certificate leaf = H\"([0-9A-Fa-f]+)\""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func runPrivileged(_ script: String) throws {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mantenimiento-helper-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let command = "bash \(shellQuoted(scriptURL.path))"
        let appleScript = "do shell script \(appleScriptString(command)) with administrator privileges"
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw PrivilegedHelperInstallerError.failed(errorText)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

enum PrivilegedHelperInstallerError: LocalizedError {
    case missingBundle
    case unsigned
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingBundle:
            return "No se encontró el helper dentro de la app. Instala Mantenimiento en Aplicaciones y vuelve a intentarlo."
        case .unsigned:
            return "La app necesita una identidad de firma estable antes de instalar el helper."
        case .failed(let message):
            if message.localizedCaseInsensitiveContains("User canceled") ||
                message.localizedCaseInsensitiveContains("(-128)") {
                return "La autorización de administrador se canceló."
            }
            return message.isEmpty ? "No se pudo completar la operación de administrador." : message
        }
    }
}
