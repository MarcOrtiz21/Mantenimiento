import Foundation
import Testing
@testable import Mantenimiento

struct ExternalCommandRunnerTests {
    @Test func largeStdoutAndStderrDoNotBlockTheProcess() {
        let output = ExternalCommandRunner.capture(
            executable: "/usr/bin/awk",
            arguments: ["BEGIN { for (i=0; i<100000; i++) { print \"output0123456789\"; print \"error0123456789\" > \"/dev/stderr\" } }"],
            timeout: 5, outputLimit: 1_024
        )
        #expect(output.hasPrefix("output0123456789"))
        #expect(output.utf8.count <= 1_024)
    }

    @Test func stderrIsUsedWhenStdoutIsEmpty() {
        #expect(ExternalCommandRunner.capture(executable: "/bin/sh", arguments: ["-c", "printf diagnostic >&2"]) == "diagnostic")
    }

    @Test func hangingProcessHasABoundedTimeout() {
        let start = ProcessInfo.processInfo.systemUptime
        let output = ExternalCommandRunner.capture(
            executable: "/bin/sh", arguments: ["-c", "printf started; while :; do :; done"], timeout: 0.1
        )
        #expect(output == "started")
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }

    @Test func inheritedPipeDoesNotRequireDescendantToExit() {
        let start = ProcessInfo.processInfo.systemUptime
        let output = ExternalCommandRunner.capture(
            executable: "/bin/sh", arguments: ["-c", "/bin/sleep 1 & printf done"], timeout: 0.2
        )
        #expect(output == "done")
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.8)
    }

    @Test func missingExecutableAndInvalidLimitsReturnEmptyOutput() {
        #expect(ExternalCommandRunner.capture(executable: "/missing/mantenimiento-command", arguments: []) == "")
        #expect(ExternalCommandRunner.capture(executable: "/bin/echo", arguments: ["unused"], outputLimit: 0) == "")
    }
}
