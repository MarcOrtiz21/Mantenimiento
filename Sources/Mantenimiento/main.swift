import AppKit

if CommandLine.arguments.contains("--install-helper") || CommandLine.arguments.contains("--uninstall-helper") {
    do {
        if CommandLine.arguments.contains("--install-helper") { try PrivilegedHelperInstaller.install() }
        else { try PrivilegedHelperInstaller.uninstall() }
        exit(0)
    }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

let app = NSApplication.shared
let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
