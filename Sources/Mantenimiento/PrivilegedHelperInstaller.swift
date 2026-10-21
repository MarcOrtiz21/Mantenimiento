import Darwin
import Foundation
import CryptoKit
import Security
import MantenimientoCore

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
        ping() == FanHelperProtocol.greeting && installedHelperMatchesBundle()
    }

    static func installedHelperMatchesBundle() -> Bool {
        guard let bundled = executableCodeHash(at: bundledHelperURL),
              let installed = executableCodeHash(at: URL(fileURLWithPath: helperDestination)) else { return false }
        return bundled == installed
    }

    static func executableCodeHash(at url: URL) -> Data? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        // El CDHash identifica código y requisitos, no la fecha del sobre CMS.
        return info[kSecCodeInfoUnique as String] as? Data
    }

    static func install() throws {
        let helperURL = bundledHelperURL
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw PrivilegedHelperInstallerError.missingBundle
        }

        let appURL = Bundle.main.bundleURL
        guard let executableURL = Bundle.main.executableURL else {
            throw PrivilegedHelperInstallerError.missingBundle
        }

        guard let certificateSHA1 = leafCertificateSHA1(for: appURL), !certificateSHA1.isEmpty else {
            throw PrivilegedHelperInstallerError.unsigned
        }

        let identifier = Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento"
        let requirement = "identifier \"\(label)\" and certificate leaf = H\"\(certificateSHA1)\""
        try verifySignature(at: helperURL, requirement: requirement)
        let ownerUID = getuid()
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperDestination, "--socket", socketPath, "--owner-uid", String(ownerUID),
                                 "--client-path", executableURL.path, "--client-identifier", identifier,
                                 "--client-cert-sha1", certificateSHA1],
            "RunAtLoad": true, "KeepAlive": true,
            "StandardOutPath": "/var/log/mantenimiento-helper.log",
            "StandardErrorPath": "/var/log/mantenimiento-helper.err"
        ]
        let encodedPlist = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .base64EncodedString()
        let script = """
        set -euo pipefail
        umask 077
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        stage=$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.mantenimiento-install.XXXXXX)
        trap '/bin/rm -rf "$stage"' EXIT
        /bin/cp \(shellQuoted(helperURL.path)) "$stage/helper"
        /usr/bin/codesign --verify --strict -R \(shellQuoted("=" + requirement)) "$stage/helper"
        printf '%s' \(shellQuoted(encodedPlist)) | /usr/bin/base64 -D > "$stage/helper.plist"
        /usr/bin/plutil -lint "$stage/helper.plist"
        /usr/sbin/chown root:wheel "$stage/helper" "$stage/helper.plist"
        /bin/chmod 755 "$stage/helper"
        /bin/chmod 644 "$stage/helper.plist"
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/mv -f "$stage/helper" \(shellQuoted(helperDestination))
        /bin/mv -f "$stage/helper.plist" \(shellQuoted(plistDestination))
        /bin/launchctl bootstrap system \(shellQuoted(plistDestination))
        /bin/launchctl enable system/\(label)
        /bin/launchctl kickstart -k system/\(label)
        """
        try runPrivileged(script)
    }

    static func uninstall() throws {
        if FileManager.default.fileExists(atPath: "/var/run/local.marc.mantenimiento.helper.manual") {
            _ = try PrivilegedFanTool.setAllFansAuto()
        }
        let script = """
        set -euo pipefail
        /bin/launchctl bootout system/\(label) 2>/dev/null || true
        /bin/launchctl bootout system \(shellQuoted(plistDestination)) 2>/dev/null || true
        /bin/rm -f \(shellQuoted(plistDestination)) \(shellQuoted(helperDestination)) \(shellQuoted(socketPath))
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

    private static func verifySignature(at url: URL, requirement text: String) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw PrivilegedHelperInstallerError.unsigned
        }
    }

    private static func leafCertificateSHA1(for url: URL) -> String? {
        var code: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { return nil }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func runPrivileged(_ script: String) throws {
        let command = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash -c \(shellQuoted(script))"
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
