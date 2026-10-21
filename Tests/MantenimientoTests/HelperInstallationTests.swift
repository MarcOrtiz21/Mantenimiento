import Foundation
import Testing
@testable import Mantenimiento

struct HelperInstallationTests {
    private func sign(_ file: URL, identifier: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", identifier, file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func codeIdentityIgnoresLocationButDetectsDifferentRequirements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: first)
        try sign(first, identifier: "local.marc.mantenimiento.test-one")
        try FileManager.default.copyItem(at: first, to: second)
        let initial = try #require(PrivilegedHelperInstaller.executableCodeHash(at: first))
        #expect(PrivilegedHelperInstaller.executableCodeHash(at: second) == initial)
        try sign(second, identifier: "local.marc.mantenimiento.test-two")
        #expect(PrivilegedHelperInstaller.executableCodeHash(at: second) != initial)
    }

    @Test func invalidOrMissingBinaryCannotBeReportedAsCurrent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(PrivilegedHelperInstaller.executableCodeHash(at: file) == nil)
        try Data("not an executable".utf8).write(to: file)
        #expect(PrivilegedHelperInstaller.executableCodeHash(at: file) == nil)
    }
}
