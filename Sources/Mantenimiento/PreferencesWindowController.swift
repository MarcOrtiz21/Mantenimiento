import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    init() {
        let viewController = NSHostingController(rootView: PreferencesRootView())
        let window = NSWindow(contentViewController: viewController)
        window.title = "Preferencias"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 520, height: 580))
        window.minSize = NSSize(width: 520, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct PreferencesRootView: View {
    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            PermissionsPreferencesView()
                .tabItem {
                    Label("Permisos", systemImage: "lock.shield")
                }

            HelperPreferencesView()
                .tabItem {
                    Label("Helper", systemImage: "wrench.and.screwdriver")
                }

            AlertPreferencesView()
                .tabItem {
                    Label("Alertas", systemImage: "bell")
                }
        }
        .padding(14)
        .frame(width: 520, height: 580)
        .background(.regularMaterial)
    }
}

private struct GeneralPreferencesView: View {
    @AppStorage(AppPreferenceKeys.openPanelAtLaunch) private var openPanelAtLaunch = true
    @AppStorage(AppPreferenceKeys.showStatusItem) private var showStatusItem = true
    @AppStorage(AppPreferenceKeys.statusRefreshInterval) private var statusRefreshInterval = 1.5
    @AppStorage(AppPreferenceKeys.showCPUInMenuBar) private var showCPU = true
    @AppStorage(AppPreferenceKeys.showGPUInMenuBar) private var showGPU = true
    @AppStorage(AppPreferenceKeys.showMemoryInMenuBar) private var showMemory = true
    @AppStorage(AppPreferenceKeys.showNetworkInMenuBar) private var showNetwork = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesHeader(
                title: "General",
                subtitle: "Barra, popover y comportamiento al iniciar."
            )

            PreferencesPanel(title: "General", symbol: "gearshape") {
                Toggle("Abrir panel al iniciar", isOn: $openPanelAtLaunch)
                Picker("Refresco barra", selection: $statusRefreshInterval) {
                    Text("1.5 s").tag(1.5)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                }
                .pickerStyle(.segmented)
            }

            PreferencesPanel(title: "Barra y popover", symbol: "menubar.rectangle") {
                Toggle("Mostrar indicador en la barra", isOn: $showStatusItem)
                Divider()
                Toggle("CPU", isOn: $showCPU)
                Toggle("GPU", isOn: $showGPU)
                Toggle("RAM", isOn: $showMemory)
                Toggle("Red", isOn: $showNetwork)
            }

            HStack {
                Button("Restaurar defaults") {
                    openPanelAtLaunch = true
                    showStatusItem = true
                    statusRefreshInterval = 1.5
                    showCPU = true
                    showGPU = true
                    showMemory = true
                    showNetwork = true
                }

                Spacer()

                Text("Los cambios se aplican al momento.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
    }
}

private struct PermissionsPreferencesView: View {
    @State private var accessibilityTrusted = InputBlocker.isAccessibilityTrusted(prompt: false)
    @State private var inputMonitoringTrusted = InputBlocker.isInputMonitoringTrusted(prompt: false)
    @State private var notificationStatus: PermissionReadiness = .unknown
    @State private var notificationMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PreferencesHeader(
                    title: "Permisos",
                    subtitle: "Accesibilidad, monitorización de entrada y notificaciones."
                )

                PreferencesPanel(title: "Accesibilidad", symbol: "accessibility") {
                    PermissionStatusRow(
                        status: accessibilityTrusted ? .granted : .missing,
                        detail: "Necesaria para el modo Limpieza."
                    )
                    Button("Abrir Ajustes") {
                        PrivacySettings.requestAccessibilityPrompt()
                    }
                }

                PreferencesPanel(title: "Monitorización de entrada", symbol: "keyboard") {
                    PermissionStatusRow(
                        status: inputMonitoringTrusted ? .granted : .missing,
                        detail: "Bloquea teclado, trackpad y ratón durante la limpieza."
                    )
                    Button("Abrir Ajustes") {
                        PrivacySettings.requestInputMonitoringPrompt()
                    }
                }

                PreferencesPanel(title: "Notificaciones", symbol: "bell") {
                    PermissionStatusRow(
                        status: notificationStatus,
                        detail: "Avisos de temperatura, memoria y ventiladores."
                    )
                    HStack {
                        Button("Solicitar permiso") {
                            requestNotifications()
                        }
                        Button("Abrir Ajustes") {
                            PrivacySettings.openNotifications()
                        }
                    }
                    if !notificationMessage.isEmpty {
                        Text(notificationMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("macOS a veces no aplica el permiso hasta que sales de la app y la vuelves a abrir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        accessibilityTrusted = InputBlocker.isAccessibilityTrusted(prompt: false)
        inputMonitoringTrusted = InputBlocker.isInputMonitoringTrusted(prompt: false)
        NotificationPermissionStatus.current { notificationStatus = $0 }
    }

    private func requestNotifications() {
        AlertNotificationService.shared.requestAuthorization { granted in
            notificationMessage = granted
                ? "Notificaciones permitidas."
                : "macOS no concedió el permiso. Ábrelo en Ajustes si aparece denegado."
            refresh()
        }
    }
}

private struct HelperPreferencesView: View {
    @State private var statusText = "Consultando..."
    @State private var isConnected = false
    @State private var isWorking = false
    @State private var lastMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesHeader(
                title: "Helper",
                subtitle: "Evita pedir la contraseña en cada cambio de ventilador."
            )

            PreferencesPanel(title: "Estado", symbol: "lock.shield") {
                HStack {
                    Circle()
                        .fill(isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Comprobar") {
                        refreshStatus()
                    }
                    .disabled(isWorking)
                }

                Text("Se instala un LaunchDaemon local. macOS pedirá autorización de administrador una vez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Instalar helper") {
                    runHelperAction(install: true)
                }
                .disabled(isWorking || isConnected)

                Button("Quitar helper") {
                    runHelperAction(install: false)
                }
                .disabled(isWorking)

                Spacer()
            }

            if isWorking {
                ProgressView("Esperando autorización de administrador...")
                    .controlSize(.small)
            }

            if !lastMessage.isEmpty {
                Text(lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .onAppear(perform: refreshStatus)
    }

    private func refreshStatus() {
        Task.detached(priority: .utility) {
            let ping = PrivilegedHelperInstaller.ping()
            await MainActor.run {
                isConnected = ping != nil
                statusText = ping != nil ? "Conectado" : "No instalado o inactivo"
                if let ping {
                    lastMessage = ping
                }
            }
        }
    }

    private func runHelperAction(install: Bool) {
        isWorking = true
        lastMessage = ""
        Task.detached(priority: .userInitiated) {
            do {
                if install {
                    try PrivilegedHelperInstaller.install()
                    let connected = PrivilegedHelperInstaller.waitUntilConnected()
                    await MainActor.run {
                        isWorking = false
                        refreshStatus()
                        lastMessage = connected
                            ? "Helper instalado y en marcha."
                            : "El helper se instaló, pero aún no responde. Espera unos segundos y pulsa Comprobar."
                    }
                } else {
                    try PrivilegedHelperInstaller.uninstall()
                    await MainActor.run {
                        isWorking = false
                        refreshStatus()
                        lastMessage = "Helper eliminado."
                    }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    refreshStatus()
                    lastMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct PermissionStatusRow: View {
    let status: PermissionReadiness
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(status.title, systemImage: status.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isGranted ? Color.green : Color.orange)
                .font(.callout.weight(.semibold))
            Spacer()
        }
        Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct AlertPreferencesView: View {
    @AppStorage(AppPreferenceKeys.systemNotificationsEnabled) private var notificationsEnabled = false
    @AppStorage(AppPreferenceKeys.notificationSoundEnabled) private var soundEnabled = false
    @AppStorage(AppPreferenceKeys.temperatureAlertsEnabled) private var temperatureAlertsEnabled = true
    @AppStorage(AppPreferenceKeys.temperatureWarningThreshold) private var warningTemperature = 85.0
    @AppStorage(AppPreferenceKeys.temperatureCriticalThreshold) private var criticalTemperature = 95.0
    @AppStorage(AppPreferenceKeys.memoryAlertsEnabled) private var memoryAlertsEnabled = true
    @AppStorage(AppPreferenceKeys.memoryPressureThreshold) private var memoryPressureThreshold = 3
    @AppStorage(AppPreferenceKeys.fanAlertsEnabled) private var fanAlertsEnabled = true
    @AppStorage(AppPreferenceKeys.appCostAlertsEnabled) private var appCostAlertsEnabled = false
    @AppStorage(AppPreferenceKeys.appCPUThreshold) private var appCPUThreshold = 0.10
    @AppStorage(AppPreferenceKeys.alertCooldown) private var alertCooldown = 900.0

    @State private var authorizationDescription = "Consultando..."
    @State private var testStatus = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            PreferencesHeader(
                title: "Alertas",
                subtitle: "Avisos persistentes, sin lecturas adicionales."
            )

            PreferencesPanel(title: "Notificaciones", symbol: "bell") {
                Toggle("Notificaciones del sistema", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { enabled in
                        guard enabled else {
                            return
                        }
                        requestNotificationAuthorization()
                    }

                Toggle("Reproducir sonido", isOn: $soundEnabled)
                    .disabled(!notificationsEnabled)

                HStack {
                    Text("Permiso")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(authorizationDescription)
                        .fontWeight(.semibold)
                    Button("Probar") {
                        sendTestNotification()
                    }
                    .disabled(!notificationsEnabled)
                }
                .font(.caption)

                if !testStatus.isEmpty {
                    Text(testStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            PreferencesPanel(title: "Umbrales", symbol: "gauge.with.dots.needle.bottom.50percent") {
                Toggle("Temperatura", isOn: $temperatureAlertsEnabled)

                Stepper(value: $warningTemperature, in: 60...100, step: 1) {
                    PreferenceValueRow(title: "Aviso", value: "\(Int(warningTemperature)) C")
                }
                .disabled(!temperatureAlertsEnabled)
                .onChange(of: warningTemperature) { value in
                    if criticalTemperature < value + 5 {
                        criticalTemperature = min(value + 5, 110)
                    }
                }

                Stepper(value: $criticalTemperature, in: 65...110, step: 1) {
                    PreferenceValueRow(title: "Crítica", value: "\(Int(criticalTemperature)) C")
                }
                .disabled(!temperatureAlertsEnabled)
                .onChange(of: criticalTemperature) { value in
                    if value < warningTemperature + 5 {
                        warningTemperature = max(value - 5, 60)
                    }
                }

                Toggle("Presión de memoria", isOn: $memoryAlertsEnabled)

                Picker("Avisar desde", selection: $memoryPressureThreshold) {
                    Text("Moderada").tag(2)
                    Text("Alta").tag(3)
                }
                .disabled(!memoryAlertsEnabled)

                Toggle("Ventilador sin respuesta", isOn: $fanAlertsEnabled)

                Toggle("Consumo de Mantenimiento", isOn: $appCostAlertsEnabled)

                Stepper(value: $appCPUThreshold, in: 0.03...0.50, step: 0.01) {
                    PreferenceValueRow(
                        title: "CPU de la app",
                        value: "\(Int((appCPUThreshold * 100).rounded()))%"
                    )
                }
                .disabled(!appCostAlertsEnabled)

                Picker("Repetir como máximo", selection: $alertCooldown) {
                    Text("5 min").tag(300.0)
                    Text("15 min").tag(900.0)
                    Text("30 min").tag(1_800.0)
                    Text("1 h").tag(3_600.0)
                }
            }

            HStack {
                Button("Restaurar alertas") {
                    restoreAlertDefaults()
                }
                Spacer()
                Text("Se exigen varias muestras antes de avisar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
        }
        .padding(8)
        .onAppear {
            refreshAuthorizationDescription()
        }
    }

    private func requestNotificationAuthorization() {
        AlertNotificationService.shared.requestAuthorization { granted in
            if !granted {
                notificationsEnabled = false
                testStatus = "macOS no concedió permiso para notificaciones."
            }
            refreshAuthorizationDescription()
        }
    }

    private func sendTestNotification() {
        AlertNotificationService.shared.requestAuthorization { granted in
            if granted {
                AlertNotificationService.shared.sendTestNotification()
                testStatus = "Notificación de prueba enviada."
            } else {
                notificationsEnabled = false
                testStatus = "Activa las notificaciones de Mantenimiento en Ajustes."
            }
            refreshAuthorizationDescription()
        }
    }

    private func refreshAuthorizationDescription() {
        AlertNotificationService.shared.authorizationDescription { description in
            authorizationDescription = description
        }
    }

    private func restoreAlertDefaults() {
        notificationsEnabled = false
        soundEnabled = false
        temperatureAlertsEnabled = true
        warningTemperature = 85
        criticalTemperature = 95
        memoryAlertsEnabled = true
        memoryPressureThreshold = 3
        fanAlertsEnabled = true
        appCostAlertsEnabled = false
        appCPUThreshold = 0.10
        alertCooldown = 900
        testStatus = ""
    }
}

private struct PreferencesHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            PopoverAppMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct PreferenceValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct PreferencesPanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        )
    }
}
