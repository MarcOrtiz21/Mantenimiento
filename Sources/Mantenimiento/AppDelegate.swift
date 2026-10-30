import AppKit
import MantenimientoCore
import OSLog

private let helperLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento",
    category: "PrivilegedHelper"
)

private let appLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "local.marc.mantenimiento",
    category: "Lifecycle"
)

enum MenuBarSection: String, Hashable, CaseIterable, Identifiable {
    case overview
    case cpu
    case gpu
    case memory
    case network
    case battery

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .overview:
            return "Mantenimiento"
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .memory:
            return "RAM"
        case .network:
            return "Red"
        case .battery:
            return "Batería"
        }
    }

    var symbol: String {
        switch self {
        case .overview:
            return "gauge.with.dots.needle.bottom.50percent"
        case .cpu:
            return "cpu"
        case .gpu:
            return "square.stack.3d.up.fill"
        case .memory:
            return "memorychip"
        case .network:
            return "network"
        case .battery:
            return "battery.100percent"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, CleanModeControllerDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem?
    private var statusView: CompactStatusBarView?
    private lazy var cleanController = CleanModeController(delegate: self)
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var fanManualControlTouched = false
    private var activeProfile: PerformanceProfile = .balanced
    private var isApplyingProfile = false
    private var statusRefreshTimer: Timer?
    private var isRefreshingStatus = false
    private var previousMenuBarSnapshot: MenuBarSnapshot?
    private var latestMenuBarSnapshot: MenuBarSnapshot?
    private var statusPopoverController: StatusPopoverController?
    private var activeStatusMenu: NSMenu?
    private var activeMenuSection: MenuBarSection?
    private var activeMenuHandles: StatusMenuHandles?
    private var demandCache: [MenuBarSection: [MenuDemandEntry]] = [:]
    private var demandRefreshDates: [MenuBarSection: Date] = [:]
    private var refreshingDemandSections: Set<MenuBarSection> = []
    private var anomalousFanSamples = 0
    private var lastFanSafetyDate: Date?
    private var fanHeartbeatTimer: Timer?
    private var isSendingFanHeartbeat = false
    private var isRestoringFans = false
    private var isSamplingRunawayProcesses = false
    private var knownUSBDevices: [Int: USBPowerDevice]?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AlertNotificationService.shared.configure()
        configureMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.registerDefaults()
        activeProfile = AppPreferences.statusRefreshInterval >= 5 ? .silent : .balanced
        NotificationCenter.default.addObserver(
            self, selector: #selector(telemetryDidUpdate(_:)), name: .telemetryUpdated, object: nil
        )
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(diagnosticsVisibilityDidChange(_:)), name: name, object: nil
            )
        }
        configureStatusItem()
        appLogger.info("Application launched; status item configured: \(self.statusItem != nil, privacy: .public)")
        checkPrivilegedHelper()
        refreshMenuBarStatus()
        configureStatusRefreshTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(markFanManualControlTouched),
            name: .fanManualControlDidSucceed,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(markFanAutomaticControlConfirmed), name: .fanAutomaticControlDidSucceed, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(startCleanModeFromPanel(_:)),
            name: .cleanModeStartRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateDidChange),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPreferences),
            name: .preferencesRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        EventLog.shared.record(.system, title: "Mantenimiento iniciado")
        if AppPreferences.openPanelAtLaunch {
            openDiagnostics()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTimer?.invalidate()
        fanHeartbeatTimer?.invalidate()
        statusPopoverController?.close()
        cleanController.stop()
        resetFansIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDiagnostics()
        return true
    }

    func cleanModeStateDidChange(_ controller: CleanModeController) {
        updateStatusButton()
        updateActiveStatusMenu()
        updateStatusPopover()
    }

    private func configureMainMenu() {
        let appName = "Mantenimiento"
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)

        let aboutItem = NSMenuItem(
            title: "Acerca de \(appName)",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let preferencesItem = NSMenuItem(
            title: "Preferencias...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "Ocultar \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Ocultar otros",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "Mostrar todo",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Salir de \(appName)",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Ventana")

        let showPanelItem = NSMenuItem(
            title: "Mostrar panel",
            action: #selector(openDiagnostics as () -> Void),
            keyEquivalent: "0"
        )
        showPanelItem.target = self
        windowMenu.addItem(showPanelItem)
        let showStatusItem = NSMenuItem(
            title: "Mostrar estado",
            action: #selector(showStatusFromMenu),
            keyEquivalent: "0"
        )
        showStatusItem.keyEquivalentModifierMask = [.command, .shift]
        showStatusItem.target = self
        windowMenu.addItem(showStatusItem)
        windowMenu.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Traer todo al frente",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showStatusFromMenu) {
            return AppPreferences.showStatusItem && statusItem?.button?.window != nil
        }
        return true
    }

    @objc private func showStatusFromMenu() {
        guard let button = statusItem?.button else { return }
        presentStatusPopover(section: .overview, from: button)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mantenimiento",
            .credits: NSAttributedString(string: "Diagnóstico y mantenimiento del Mac.")
        ])
    }

    private var displayedMenuBarSections: [MenuBarSection] {
        let sections = AppPreferences.displayedMenuBarSections(hasBattery: false)
            .filter { $0 != .battery }
        return sections.isEmpty ? [.cpu, .gpu, .memory, .network] : sections
    }

    private func configureStatusItem() {
        guard AppPreferences.showStatusItem else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: CompactStatusBarView.preferredWidth(for: displayedMenuBarSections))
        item.isVisible = true
        item.button?.imagePosition = .noImage
        item.button?.imageScaling = .scaleNone
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        if let button = item.button {
            let view = CompactStatusBarView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            view.snapshot = latestMenuBarSnapshot
            view.isCleaning = cleanController.isActive
            view.toolTip = "CPU, GPU, RAM y red. Clic por zonas para abrir el detalle."
            button.addSubview(view)
            statusView = view
            item.isVisible = true
        } else {
            appLogger.error("Status item created without a button")
        }

        updateStatusButton()
    }

    private func updateStatusItemVisibility() {
        if AppPreferences.showStatusItem {
            if statusItem == nil {
                configureStatusItem()
            } else {
                updateStatusButton()
            }
            return
        }

        activeStatusMenu = nil
        activeMenuSection = nil
        activeMenuHandles = nil
        statusPopoverController?.close()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusView?.removeFromSuperview()
        statusView = nil
        statusItem = nil
    }

    private func checkPrivilegedHelper() {
        Task.detached(priority: .utility) {
            do {
                let response = try PrivilegedHelperClient.run(arguments: ["ping"])
                helperLogger.info("Helper health check: \(response, privacy: .public)")
            } catch {
                helperLogger.info("Helper unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func updateStatusButton() {
        let enabledSections = displayedMenuBarSections
        statusItem?.length = CompactStatusBarView.preferredWidth(for: enabledSections)

        guard let button = statusItem?.button else {
            return
        }

        button.image = nil
        button.imagePosition = .noImage
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.alignment = .center
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.refusesFirstResponder = true
        button.toolTip = "CPU, GPU, RAM y red. Clic por zonas para abrir el detalle."
        button.cell?.wraps = true
        button.cell?.lineBreakMode = .byClipping

        if statusView?.superview !== button {
            statusView?.removeFromSuperview()
            let view = CompactStatusBarView(frame: button.bounds)
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            statusView = view
        }

        statusView?.frame = button.bounds
        statusView?.enabledSections = enabledSections
        statusView?.snapshot = latestMenuBarSnapshot
        statusView?.isCleaning = cleanController.isActive
    }

    private func configureStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: effectiveStatusRefreshInterval, repeats: false) { [weak self] _ in
            self?.refreshMenuBarStatus()
            self?.configureStatusRefreshTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusRefreshTimer = timer
    }

    @objc private func diagnosticsVisibilityDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.title == "Mantenimiento" else { return }
        configureStatusRefreshTimer()
    }

    private var effectiveStatusRefreshInterval: TimeInterval {
        if NSApp.windows.contains(where: {
            $0.title == "Mantenimiento" && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }) {
            return max(AppPreferences.statusRefreshInterval, ProcessInfo.processInfo.isLowPowerModeEnabled ? 5 : 1.5)
        }
        if !AppPreferences.showStatusItem {
            return 8
        }
        if statusPopoverController?.isShown == true || activeStatusMenu != nil {
            return min(AppPreferences.statusRefreshInterval, 1.5)
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return max(AppPreferences.statusRefreshInterval, 5)
        }
        return AppPreferences.statusRefreshInterval
    }

    private func makeTitleMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = StatusMenuTitleView(frame: NSRect(x: 0, y: 0, width: 392, height: 30))
        return item
    }

    private func makeHeaderMenuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let view = StatusMenuHeaderView(frame: NSRect(x: 0, y: 0, width: 392, height: 20))
        view.text = title
        item.view = view
        return item
    }

    private func makeInfoMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = StatusMenuInfoView(frame: NSRect(x: 0, y: 0, width: 392, height: 24))
        return item
    }

    private func makeStatusMenu(section: MenuBarSection = .overview) -> (menu: NSMenu, handles: StatusMenuHandles) {
        let menu = NSMenu()
        let titleItem = makeTitleMenuItem()
        menu.addItem(titleItem)

        let performanceHeaderItem = makeHeaderMenuItem(title: "Rendimiento")
        menu.addItem(performanceHeaderItem)
        let detailItems = (0..<10).map { _ in
            let item = makeInfoMenuItem()
            menu.addItem(item)
            return item
        }

        let demandSeparator = NSMenuItem.separator()
        menu.addItem(demandSeparator)
        let demandHeaderItem = makeHeaderMenuItem(title: "Mayor demanda")
        menu.addItem(demandHeaderItem)
        let demandItems = (0..<8).map { _ in
            let item = makeInfoMenuItem()
            menu.addItem(item)
            return item
        }

        menu.addItem(.separator())

        let showTitle = section == .overview ? "Mostrar panel" : "Abrir \(section.title) en panel"
        let showItem = NSMenuItem(title: showTitle, action: #selector(openDiagnosticsFromMenu(_:)), keyEquivalent: "")
        showItem.target = self
        showItem.representedObject = section == .overview ? nil : section.rawValue
        menu.addItem(showItem)

        let refreshItem = NSMenuItem(title: "Actualizar ahora", action: #selector(refreshMenuBarStatusNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !isRefreshingStatus
        menu.addItem(refreshItem)

        let preferencesItem = NSMenuItem(title: "Preferencias", action: #selector(openPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        let cleanMenu = NSMenu()
        addCleanDuration("1 minuto", seconds: 60, to: cleanMenu)
        addCleanDuration("2 minutos", seconds: 120, to: cleanMenu)
        addCleanDuration("5 minutos", seconds: 300, to: cleanMenu)

        let cleanItem = NSMenuItem(title: "Iniciar limpieza", action: nil, keyEquivalent: "")
        cleanItem.submenu = cleanMenu
        cleanItem.isEnabled = !cleanController.isActive
        menu.addItem(cleanItem)

        let unlockItem = NSMenuItem(title: "Desbloquear ahora", action: #selector(stopCleanMode), keyEquivalent: "")
        unlockItem.target = self
        unlockItem.isEnabled = cleanController.isActive
        menu.addItem(unlockItem)

        menu.addItem(.separator())

        let turboItem = NSMenuItem(title: "Turbo ventiladores", action: #selector(setAllFansTurboFromMenu), keyEquivalent: "")
        turboItem.target = self
        menu.addItem(turboItem)

        let autoFansItem = NSMenuItem(title: "Ventiladores en Auto", action: #selector(setAllFansAutoFromMenu), keyEquivalent: "")
        autoFansItem.target = self
        menu.addItem(autoFansItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        let handles = StatusMenuHandles(
            titleItem: titleItem,
            performanceHeaderItem: performanceHeaderItem,
            detailItems: detailItems,
            demandSeparator: demandSeparator,
            demandHeaderItem: demandHeaderItem,
            demandItems: demandItems,
            refreshItem: refreshItem,
            cleanItem: cleanItem,
            unlockItem: unlockItem
        )
        return (menu, handles)
    }

    private func addCleanDuration(_ title: String, seconds: TimeInterval, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(startCleanMode(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = seconds
        menu.addItem(item)
    }

    @objc private func startCleanMode(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else {
            return
        }

        startCleanMode(duration: seconds)
    }

    @objc private func startCleanModeFromPanel(_ notification: Notification) {
        guard let seconds = notification.userInfo?["duration"] as? TimeInterval else {
            return
        }

        startCleanMode(duration: seconds)
    }

    private func startCleanMode(duration seconds: TimeInterval) {
        do {
            try cleanController.start(duration: seconds)
        } catch {
            showAlert(
                title: "No se pudo bloquear la entrada",
                message: error.localizedDescription
            )
        }
    }

    @objc private func stopCleanMode() {
        cleanController.stop()
    }

    @objc private func handleStatusItemClick(_ sender: NSButton) {
        guard let event = NSApp.currentEvent else {
            appLogger.debug("Status item click without current event; opening overview popover")
            presentStatusPopover(section: .overview, from: sender)
            return
        }

        appLogger.debug("Status item click received: \(event.type.rawValue, privacy: .public)")

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            presentStatusMenu(section: .overview, from: sender)
            return
        }

        let section = section(for: sender, event: event)
        presentStatusPopover(section: section, from: sender)
    }

    @objc private func openDiagnostics() {
        openDiagnostics(sectionRawValue: nil)
    }

    @objc private func openPreferences() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }

        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openDiagnosticsFromMenu(_ sender: NSMenuItem) {
        openDiagnostics(sectionRawValue: sender.representedObject as? String)
    }

    private func openDiagnostics(sectionRawValue: String?) {
        if diagnosticsWindowController == nil {
            diagnosticsWindowController = DiagnosticsWindowController()
        }

        diagnosticsWindowController?.showWindow(nil)
        diagnosticsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.diagnosticsWindowController?.window?.makeFirstResponder(nil)
        }

        if let sectionRawValue {
            NotificationCenter.default.post(
                name: .diagnosticsSectionRequested,
                object: nil,
                userInfo: ["section": sectionRawValue]
            )
        }
    }

    @objc private func quit() {
        cleanController.stop()
        resetFansIfNeeded()
        NSApp.terminate(nil)
    }

    @objc private func markFanManualControlTouched() {
        fanManualControlTouched = true
        fanHeartbeatTimer?.invalidate()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in self?.sendFanHeartbeat() }
        RunLoop.main.add(timer, forMode: .common)
        fanHeartbeatTimer = timer
    }

    @objc private func markFanAutomaticControlConfirmed() {
        fanManualControlTouched = false
        fanHeartbeatTimer?.invalidate()
        fanHeartbeatTimer = nil
        anomalousFanSamples = 0
    }

    private func sendFanHeartbeat() {
        guard fanManualControlTouched, !isSendingFanHeartbeat, !isRestoringFans else { return }
        isSendingFanHeartbeat = true
        Task { @MainActor in
            let succeeded = await Task.detached(priority: .utility) {
                do { try PrivilegedFanTool.heartbeat(); return true }
                catch { return false }
            }.value
            isSendingFanHeartbeat = false
            if !succeeded { restoreFansToAutoIfNeeded(asynchronously: true, reason: "pérdida de supervisión") }
        }
    }

    @objc private func preferencesDidChange() {
        configureStatusRefreshTimer()
        MaintenanceAlertMonitor.shared.reset()
        if let activeMenuSection,
           activeMenuSection != .overview,
           !AppPreferences.enabledMenuBarSections.contains(activeMenuSection) {
            selectStatusPopoverSection(.overview)
        }
        updateStatusItemVisibility()
        updateStatusPopover()
    }

    @objc private func powerStateDidChange() {
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        DispatchQueue.main.async { [weak self] in
            EventLog.shared.record(.power, title: isLowPower ? "Modo de bajo consumo activado" : "Modo de bajo consumo desactivado")
            self?.configureStatusRefreshTimer()
        }
    }

    @objc private func thermalStateDidChange() {
        let state = ProcessInfo.processInfo.thermalState
        let severity: MaintenanceEvent.Severity = state == .critical ? .critical : state == .serious ? .warning : .info
        EventLog.shared.record(
            .thermal,
            severity: severity,
            title: "Estado térmico \(thermalStateDescription(state))",
            detail: state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                ? "macOS está limitando el rendimiento para enfriar el equipo."
                : nil
        )
    }

    @objc private func systemWillSleep() {
        statusRefreshTimer?.invalidate()
        EventLog.shared.record(.system, title: "Reposo")
        restoreFansToAutoIfNeeded(asynchronously: true, reason: "suspensión del sistema")
    }

    @objc private func systemDidWake() {
        EventLog.shared.record(.system, title: "Reactivación tras reposo")
        anomalousFanSamples = 0
        TelemetryStore.shared.resetAfterWake()
        refreshMenuBarStatus(force: true)
        configureStatusRefreshTimer()
    }

    @objc private func refreshMenuBarStatusNow() {
        refreshMenuBarStatus(force: true)
        if let section = activeMenuSection {
            refreshDemandIfNeeded(for: section, force: true)
        }
    }

    @objc private func setAllFansTurboFromMenu() {
        applyProfile(.turbo)
    }

    @objc private func setAllFansAutoFromMenu() {
        applyProfile(.balanced)
    }

    private func applyProfile(_ profile: PerformanceProfile) {
        guard !isApplyingProfile else {
            return
        }

        isApplyingProfile = true
        updateStatusPopover()
        Task { @MainActor in
            do {
                try await PerformanceProfileService.apply(profile)
            } catch {
                await MainActor.run {
                    isApplyingProfile = false
                    updateStatusPopover()
                    showAlert(title: "No se pudo aplicar \(profile.title)", message: error.localizedDescription)
                }
                return
            }

            await MainActor.run {
                EventLog.shared.record(.fans, title: "Perfil \(profile.title) aplicado")
                activeProfile = profile
                isApplyingProfile = false
                UserDefaults.standard.set(profile.refreshInterval, forKey: AppPreferenceKeys.statusRefreshInterval)
                if profile == .turbo {
                    NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
                } else {
                    markFanAutomaticControlConfirmed()
                }
                TelemetryStore.shared.invalidateSMC()
                refreshMenuBarStatus(force: true)
                updateStatusPopover()
            }
        }
    }

    private func refreshMenuBarStatus(force: Bool = false) {
        guard !isRefreshingStatus else {
            return
        }

        isRefreshingStatus = true
        Task { @MainActor in
            _ = await Task.detached(priority: .utility) {
                TelemetryStore.shared.snapshot(
                    previousTelemetry: nil, includeSMC: true, fullTelemetry: true, force: force
                )
            }.value
            isRefreshingStatus = false
            updateActiveStatusMenu()
            updateStatusPopover()
        }
    }

    @objc private func telemetryDidUpdate(_ notification: Notification) {
        guard let shared = notification.object as? SharedTelemetrySnapshot,
              latestMenuBarSnapshot.map({ shared.date > $0.date }) ?? true else { return }
        let snapshot = MenuBarSnapshot.make(shared: shared, previous: previousMenuBarSnapshot)
        recordPowerTransitions(from: latestMenuBarSnapshot?.telemetry.battery, to: snapshot.telemetry.battery)
        BatteryHealthLog.shared.recordIfNeeded(snapshot.telemetry.battery)
        recordUSBDeviceChanges(snapshot.telemetry)
        recordChargeRates(snapshot.telemetry.battery)
        previousMenuBarSnapshot = snapshot
        latestMenuBarSnapshot = snapshot
        MaintenanceAlertMonitor.shared.process(snapshot: snapshot)
        sampleRunawayProcessesIfNeeded()
        TelemetryHistoryRecorder.shared.record(snapshot: snapshot)
        updateFanSafety(with: snapshot)
        updateStatusItemVisibility()
        updateActiveStatusMenu()
        updateStatusPopover()
        if let section = activeMenuSection {
            refreshDemandIfNeeded(for: section)
        }
    }

    private func recordPowerTransitions(from previous: BatterySnapshot?, to current: BatterySnapshot?) {
        guard let previous, let current else { return }
        if !previous.externalConnected && current.externalConnected {
            let adapter = current.adapter?.name ?? current.adapter?.watts.map { "\($0) W" }
            EventLog.shared.record(.power, title: "Cargador conectado", detail: [adapter, "batería al \(current.percent)%"].compactMap { $0 }.joined(separator: " · "))
        } else if previous.externalConnected && !current.externalConnected {
            EventLog.shared.record(.power, title: "Cargador desconectado", detail: "Batería al \(current.percent)%")
        } else if !previous.isCharged && current.isCharged && current.externalConnected {
            EventLog.shared.record(.power, title: "Carga completa", detail: "Batería al \(current.percent)%")
        }
    }

    private func recordChargeRates(_ battery: BatterySnapshot?) {
        guard let battery else { return }
        let estimator = ChargeRateEstimator.shared
        if let current = battery.currentCapacityMah, let full = battery.fullChargeCapacityMah {
            estimator.record(id: ChargeRateEstimator.macID, level: current, full: full, isCharging: battery.isCharging)
        } else {
            estimator.record(id: ChargeRateEstimator.macID, level: battery.percent, full: 100, isCharging: battery.isCharging)
        }
        var active: Set<String> = [ChargeRateEstimator.macID]
        for port in battery.ports where port.role == .poweringDevice {
            guard let percent = port.deviceBatteryPercent else { continue }
            let id = ChargeRateEstimator.portID(port.index)
            active.insert(id)
            if let remaining = port.deviceRemainingCapacity, let full = port.deviceFullCapacity {
                estimator.record(id: id, level: remaining, full: full, isCharging: percent < 100)
            } else {
                estimator.record(id: id, level: percent, full: 100, isCharging: percent < 100)
            }
        }
        estimator.forget(idsNotIn: active)
    }

    /// Las muestras ligeras reutilizan la lista anterior; solo las completas (con volúmenes) sirven de referencia.
    private func recordUSBDeviceChanges(_ telemetry: SystemTelemetrySnapshot) {
        guard !telemetry.volumes.isEmpty else { return }
        let current = Dictionary(telemetry.usbDevices.map { ($0.locationID, $0) }, uniquingKeysWith: { first, _ in first })
        defer { knownUSBDevices = current }
        guard let known = knownUSBDevices else { return }

        for (location, device) in current where known[location] == nil {
            let battery = telemetry.battery?.ports.first { $0.role == .poweringDevice && $0.deviceVendorID == device.vendorID }?.deviceBatteryPercent
            EventLog.shared.record(
                .power,
                title: "\(device.name) conectado",
                detail: [String(format: "hasta %.0f W", device.allocatedWatts), battery.map { "batería al \($0)%" }].compactMap { $0 }.joined(separator: " · ")
            )
        }
        for (location, device) in known where current[location] == nil {
            EventLog.shared.record(.power, title: "\(device.name) desconectado")
        }
    }

    private func sampleRunawayProcessesIfNeeded() {
        guard AppPreferences.runawayProcessAlertsEnabled, !isSamplingRunawayProcesses else { return }
        if let last = RunawayProcessDetector.shared.lastSampleDate, Date().timeIntervalSince(last) < 30 {
            return
        }
        isSamplingRunawayProcesses = true
        Task { @MainActor in
            let entries = await Task.detached(priority: .utility) {
                ProcessDemandSampler.shared.cpuEntries()
            }.value
            isSamplingRunawayProcesses = false
            RunawayProcessDetector.shared.deliver(RunawayProcessDetector.shared.process(entries: entries))
        }
    }

    private func refreshMenuBarStatusForMenu() {
        // El menú debe aparecer inmediatamente; la lectura de SMC continúa en segundo plano.
        refreshMenuBarStatus(force: true)
    }

    private func section(for button: NSButton, event: NSEvent) -> MenuBarSection {
        let point = button.convert(event.locationInWindow, from: nil)
        return CompactStatusBarView.section(at: point.x, enabledSections: displayedMenuBarSections)
    }

    private func makeStatusPopoverController() -> StatusPopoverController {
        StatusPopoverController(
            actions: StatusPopoverActions(
                selectSection: { [weak self] section in
                    self?.selectStatusPopoverSection(section)
                },
                refresh: { [weak self] in
                    self?.refreshMenuBarStatusNow()
                },
                openPanel: { [weak self] section in
                    self?.openDiagnostics(sectionRawValue: section == .overview ? nil : section.rawValue)
                },
                openPreferences: { [weak self] in
                    self?.openPreferences()
                },
                applyProfile: { [weak self] profile in
                    self?.applyProfile(profile)
                },
                startClean: { [weak self] duration in
                    self?.statusPopoverController?.close()
                    self?.startCleanMode(duration: duration)
                },
                stopClean: { [weak self] in
                    self?.stopCleanMode()
                },
                turboFans: { [weak self] in
                    self?.setAllFansTurboFromMenu()
                },
                autoFans: { [weak self] in
                    self?.setAllFansAutoFromMenu()
                },
                quit: { [weak self] in
                    self?.quit()
                }
            ),
            onClose: { [weak self] in
                self?.activeMenuSection = nil
                self?.configureStatusRefreshTimer()
            }
        )
    }

    private func presentStatusPopover(section: MenuBarSection, from button: NSButton) {
        let controller = statusPopoverController ?? makeStatusPopoverController()
        statusPopoverController = controller

        if controller.isShown, activeMenuSection == section {
            controller.close()
            return
        }

        activeMenuSection = section
        refreshMenuBarStatusForMenu()
        refreshDemandIfNeeded(for: section, force: true)
        updateStatusPopover()
        controller.show(relativeTo: button, initialSection: section)
        configureStatusRefreshTimer()
    }

    private func selectStatusPopoverSection(_ section: MenuBarSection) {
        activeMenuSection = section
        statusPopoverController?.select(section)
        refreshDemandIfNeeded(for: section, force: true)
        updateStatusPopover()
    }

    private func presentStatusMenu(section: MenuBarSection, from button: NSButton) {
        refreshMenuBarStatusForMenu()
        let session = makeStatusMenu(section: section)
        activeStatusMenu = session.menu
        activeMenuSection = section
        activeMenuHandles = session.handles
        refreshDemandIfNeeded(for: section, force: true)
        updateActiveStatusMenu()
        configureStatusRefreshTimer()
        session.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        activeStatusMenu = nil
        activeMenuSection = nil
        activeMenuHandles = nil
        configureStatusRefreshTimer()
    }

    private func updateStatusPopover() {
        guard let controller = statusPopoverController,
              let section = activeMenuSection else {
            return
        }

        let detailRows = latestMenuBarSnapshot.map { detailLines(for: section, snapshot: $0) }
            ?? [MenuInfoLine(title: "Estado", value: "Calculando...")]
        controller.update(
            snapshot: latestMenuBarSnapshot,
            selectedSection: section,
            detailRows: detailRows,
            demandRows: demandRows(for: section),
            isDemandHidden: section == .overview || section == .battery,
            isDemandLoading: refreshingDemandSections.contains(section),
            isRefreshing: isRefreshingStatus,
            isCleaning: cleanController.isActive,
            activeProfile: activeProfile,
            isApplyingProfile: isApplyingProfile
        )
    }

    private func updateActiveStatusMenu() {
        guard let section = activeMenuSection, let handles = activeMenuHandles else {
            return
        }

        if let titleView = handles.titleItem.view as? StatusMenuTitleView {
            titleView.text = cleanController.isActive ? "Modo Limpieza activo" : section.title
        }

        let detailRows = latestMenuBarSnapshot.map { detailLines(for: section, snapshot: $0) }
            ?? [MenuInfoLine(title: "Estado", value: "Calculando...")]
        updateInfoItems(handles.detailItems, with: detailRows)

        let demandRows = demandRows(for: section)
        handles.demandSeparator.isHidden = section == .overview || section == .battery
        handles.demandHeaderItem.isHidden = section == .overview || section == .battery
        updateInfoItems(handles.demandItems, with: demandRows, hidden: section == .overview || section == .battery)

        handles.refreshItem.title = isRefreshingStatus ? "Actualizando..." : "Actualizar ahora"
        handles.refreshItem.isEnabled = !isRefreshingStatus
        handles.cleanItem.isEnabled = !cleanController.isActive
        handles.unlockItem.isEnabled = cleanController.isActive
    }

    private func updateInfoItems(_ items: [NSMenuItem], with rows: [MenuInfoLine], hidden: Bool = false) {
        for (index, item) in items.enumerated() {
            let shouldHide = hidden || index >= rows.count
            item.isHidden = shouldHide
            guard !shouldHide, let view = item.view as? StatusMenuInfoView else {
                continue
            }
            view.leadingText = rows[index].title
            view.trailingText = rows[index].value
        }
    }

    private func refreshDemandIfNeeded(for section: MenuBarSection, force: Bool = false) {
        guard section != .overview, section != .battery else {
            return
        }
        guard !refreshingDemandSections.contains(section) else {
            return
        }
        if !force, let lastRefresh = demandRefreshDates[section], Date().timeIntervalSince(lastRefresh) < 3 {
            return
        }

        refreshingDemandSections.insert(section)
        updateActiveStatusMenu()
        updateStatusPopover()

        Task { @MainActor in
            let entries = await Task.detached(priority: .utility) { [self] in
                loadDemandEntries(for: section)
            }.value

            await MainActor.run {
                demandCache[section] = Array(entries.prefix(8))
                demandRefreshDates[section] = Date()
                refreshingDemandSections.remove(section)
                if activeMenuSection == section {
                    updateActiveStatusMenu()
                    updateStatusPopover()
                }
            }
        }
    }

    private func demandRows(for section: MenuBarSection) -> [MenuInfoLine] {
        guard section != .overview, section != .battery else {
            return []
        }

        if refreshingDemandSections.contains(section) && demandCache[section]?.isEmpty != false {
            return [MenuInfoLine(title: "Procesos", value: "Actualizando...")]
        }

        let entries = demandCache[section] ?? []
        if entries.isEmpty {
            return [MenuInfoLine(title: "Procesos", value: "Sin actividad detectada")]
        }

        return entries.map { MenuInfoLine(title: $0.name, value: $0.detail) }
    }

    private func loadDemandEntries(for section: MenuBarSection) -> [MenuDemandEntry] {
        switch section {
        case .overview, .battery:
            return []
        case .cpu:
            return ProcessDemandSampler.shared.cpuEntries()
        case .gpu:
            return ProcessDemandSampler.shared.gpuEntries()
        case .memory:
            return ProcessDemandSampler.shared.memoryEntries()
        case .network:
            return ProcessDemandSampler.shared.networkEntries()
        }
    }

    private func detailLines(for section: MenuBarSection, snapshot: MenuBarSnapshot) -> [MenuInfoLine] {
        switch section {
        case .overview:
            return snapshot.detailLines
        case .cpu:
            return [
                MenuInfoLine(title: "Uso total", value: snapshot.cpuUsage.map(menuFormatPercent) ?? "calculando"),
                MenuInfoLine(title: "Núcleos", value: "\(snapshot.telemetry.cpu.coreCount)"),
                MenuInfoLine(title: "Temperatura CPU", value: snapshot.cpuTemperature.map(menuFormatTemperature) ?? "sin datos"),
                MenuInfoLine(title: "Estado térmico", value: snapshot.thermalState)
            ]
        case .gpu:
            return [
                MenuInfoLine(title: "Resumen", value: snapshot.gpuSummary),
                MenuInfoLine(title: "Temperatura GPU", value: snapshot.gpuTemperature.map(menuFormatTemperature) ?? "sin datos"),
                MenuInfoLine(title: "Renderer", value: snapshot.telemetry.gpu?.rendererUtilizationPercent.map { "\(Int($0.rounded()))%" } ?? "sin datos"),
                MenuInfoLine(title: "Tiler", value: snapshot.telemetry.gpu?.tilerUtilizationPercent.map { "\(Int($0.rounded()))%" } ?? "sin datos"),
                MenuInfoLine(title: "Memoria GPU", value: snapshot.telemetry.gpu?.inUseMemoryBytes.map(menuFormatBytes) ?? "sin datos")
            ]
        case .memory:
            guard snapshot.telemetry.memory.isAvailable else {
                return [MenuInfoLine(title: "Estado", value: "Sin lectura de memoria fiable")]
            }
            return [
                MenuInfoLine(title: "Memoria usada", value: "\(menuFormatBytes(snapshot.telemetry.memory.usedBytes)) / \(menuFormatBytes(snapshot.telemetry.memory.totalBytes)) (\(menuFormatPercent(snapshot.telemetry.memory.usedRatio)))"),
                MenuInfoLine(title: "Memoria de apps", value: menuFormatBytes(snapshot.telemetry.memory.appBytes)),
                MenuInfoLine(title: "Memoria cableada", value: menuFormatBytes(snapshot.telemetry.memory.wiredBytes)),
                MenuInfoLine(title: "Comprimida", value: menuFormatBytes(snapshot.telemetry.memory.compressedBytes)),
                MenuInfoLine(title: "Archivos en cache", value: menuFormatBytes(snapshot.telemetry.memory.cachedFilesBytes)),
                MenuInfoLine(title: "Temperatura memoria", value: snapshot.memoryTemperature.map(menuFormatTemperature) ?? "sin datos"),
                MenuInfoLine(title: "Presión", value: snapshot.telemetry.memory.pressureDescription)
            ]
        case .network:
            return [
                MenuInfoLine(title: "Bajada", value: snapshot.networkDownBps.map(menuFormatRate) ?? "calculando"),
                MenuInfoLine(title: "Subida", value: snapshot.networkUpBps.map(menuFormatRate) ?? "calculando"),
                MenuInfoLine(title: "Interfaces activas", value: snapshot.telemetry.network.interfaces.map(\.displayName).prefix(4).joined(separator: ", "))
            ]
        case .battery:
            guard let battery = snapshot.telemetry.battery else {
                return [MenuInfoLine(title: "Estado", value: "Sin batería detectada")]
            }
            var lines = [
                MenuInfoLine(title: "Carga", value: "\(battery.percent)%"),
                MenuInfoLine(title: "Estado", value: batteryStatusDescription(battery))
            ]
            if let minutes = battery.timeToFullMinutes ?? battery.timeToEmptyMinutes {
                lines.append(MenuInfoLine(
                    title: battery.timeToFullMinutes != nil ? "Llena en" : "Restante",
                    value: formatBatteryMinutes(minutes)
                ))
            }
            if let watts = battery.batteryPowerWatts, abs(watts) >= 0.1 {
                lines.append(MenuInfoLine(title: watts > 0 ? "Carga" : "Descarga", value: String(format: "%.1f W", abs(watts))))
            }
            if let adapter = battery.adapter {
                lines.append(MenuInfoLine(title: "Cargador", value: adapter.name ?? adapter.watts.map { "\($0) W" } ?? "conectado"))
            }
            if let cycles = battery.cycleCount {
                lines.append(MenuInfoLine(title: "Ciclos", value: "\(cycles)"))
            }
            if let health = battery.healthPercent {
                lines.append(MenuInfoLine(title: "Salud", value: "\(health)%"))
            }
            if let temperature = battery.temperatureCelsius {
                lines.append(MenuInfoLine(title: "Temperatura", value: menuFormatTemperature(temperature)))
            }
            return lines
        }
    }

    private func resetFansIfNeeded() {
        restoreFansToAutoIfNeeded(asynchronously: false, reason: "cierre de la aplicación")
    }

    private func updateFanSafety(with snapshot: MenuBarSnapshot) {
        if fanManualControlTouched, snapshot.fanStatus.error != nil {
            restoreFansToAutoIfNeeded(asynchronously: true, reason: "fallo de lectura de ventiladores")
            return
        }
        guard snapshot.fanStatus.isCurrent,
              snapshot.fanStatus.lastSuccess != lastFanSafetyDate else { return }
        lastFanSafetyDate = snapshot.fanStatus.lastSuccess
        if fanManualControlTouched, snapshot.fans?.isAutomaticControlConfirmed == true {
            markFanAutomaticControlConfirmed()
        }
        guard fanManualControlTouched,
              let fans = snapshot.fans?.fans,
              !fans.isEmpty else {
            anomalousFanSamples = 0
            return
        }

        let hasAnomaly = fans.contains {
            $0.mode == .manual && $0.targetRPM >= 1_000 && $0.actualRPM < 100
        }
        anomalousFanSamples = hasAnomaly ? anomalousFanSamples + 1 : 0

        if anomalousFanSamples >= 3 {
            restoreFansToAutoIfNeeded(asynchronously: true, reason: "lecturas anómalas")
        }
    }

    private func restoreFansToAutoIfNeeded(asynchronously: Bool, reason: String) {
        guard fanManualControlTouched, !isRestoringFans else {
            return
        }
        isRestoringFans = true
        let operation = { () -> Bool in
            do {
                _ = try PrivilegedFanTool.setAllFansAuto()
                appLogger.info("Fans restored to automatic mode: \(reason, privacy: .public)")
                EventLog.shared.record(.fans, severity: .warning, title: "Ventiladores devueltos a automático", detail: "Motivo: \(reason).")
                return true
            } catch {
                appLogger.error("Auto recovery still pending after \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        if asynchronously {
            Task { @MainActor in
                let confirmed = await Task.detached(priority: .userInitiated, operation: operation).value
                isRestoringFans = false
                if confirmed { markFanAutomaticControlConfirmed() }
                TelemetryStore.shared.invalidateSMC()
            }
        } else {
            let confirmed = operation()
            isRestoringFans = false
            if confirmed { markFanAutomaticControlConfirmed() }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

struct MenuDemandEntry {
    let name: String
    let detail: String
    let sortValue: Double

    var menuTitle: String {
        "\(name): \(detail)"
    }

    init(name: String, detail: String, sortValue: Double = 0) {
        self.name = name
        self.detail = detail
        self.sortValue = sortValue
    }
}

struct MenuInfoLine {
    let title: String
    let value: String
}

private struct StatusMenuHandles {
    let titleItem: NSMenuItem
    let performanceHeaderItem: NSMenuItem
    let detailItems: [NSMenuItem]
    let demandSeparator: NSMenuItem
    let demandHeaderItem: NSMenuItem
    let demandItems: [NSMenuItem]
    let refreshItem: NSMenuItem
    let cleanItem: NSMenuItem
    let unlockItem: NSMenuItem
}

private func topNetworkProcesses() -> [MenuDemandEntry] {
    let output = runCommand("/usr/bin/nettop", arguments: ["-P", "-L", "1", "-x", "-n", "-m", "tcp"], timeout: 1.1)
    var entries: [MenuDemandEntry] = []

    for line in output.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count > 5 else {
            continue
        }

        let processField = String(fields[1])
        guard !processField.isEmpty else {
            continue
        }

        let received = UInt64(fields[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let sent = UInt64(fields[5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard received > 0 || sent > 0 else {
            continue
        }

        let name = processField
            .split(separator: ".")
            .dropLast()
            .joined(separator: ".")
        entries.append(MenuDemandEntry(
            name: name.isEmpty ? processField : name,
            detail: "↓ \(menuFormatBytes(received)) · ↑ \(menuFormatBytes(sent))",
            sortValue: Double(received + sent)
        ))
    }

    return entries.sorted { $0.sortValue > $1.sortValue }
}

private func topGPUClients() -> [MenuDemandEntry] {
    let output = runCommand("/usr/sbin/ioreg", arguments: ["-r", "-c", "AGXDeviceUserClient", "-d", "1"], timeout: 0.9)
    var currentName: String?
    var currentPID: String?
    var currentTime: UInt64 = 0
    var totals: [String: UInt64] = [:]

    func flush() {
        guard let name = currentName, currentTime > 0 else {
            currentName = nil
            currentPID = nil
            currentTime = 0
            return
        }

        let key = currentPID.map { "\(name) (\($0))" } ?? name
        totals[key, default: 0] += currentTime
        currentName = nil
        currentPID = nil
        currentTime = 0
    }

    for line in output.split(separator: "\n").map(String.init) {
        if line.contains("AGXDeviceUserClient") {
            flush()
            continue
        }

        if line.contains("IOUserClientCreator"),
           let match = firstMatch(in: line, pattern: #"pid\s+(\d+),\s*([^"]+)"#),
           match.count == 3 {
            currentPID = match[1]
            currentName = match[2].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for value in allMatches(in: line, pattern: #""accumulatedGPUTime"=(\d+)"#) {
            if value.count == 2, let time = UInt64(value[1]) {
                currentTime += time
            }
        }
    }
    flush()

    return totals
        .sorted { $0.value > $1.value }
        .map { name, nanoseconds in
            MenuDemandEntry(name: name, detail: menuGpuTime(nanoseconds), sortValue: Double(nanoseconds))
        }
}

private func runCommand(_ executable: String, arguments: [String], timeout: TimeInterval) -> String {
    ExternalCommandRunner.capture(
        executable: executable,
        arguments: arguments,
        timeout: timeout
    )
}

private func firstMatch(in text: String, pattern: String) -> [String]? {
    allMatches(in: text, pattern: pattern).first
}

private func allMatches(in text: String, pattern: String) -> [[String]] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }

    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).map { match in
        (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }
}

private func menuGpuTime(_ nanoseconds: UInt64) -> String {
    let seconds = Double(nanoseconds) / 1_000_000_000
    if seconds >= 60 {
        return String(format: "%.1f min GPU", seconds / 60)
    }
    return String(format: "%.1f s GPU", seconds)
}

struct MenuBarSnapshot {
    let date: Date
    let samplingEpoch: UInt64
    let smcDate: Date?
    let fanStatus: TelemetryReadingStatus
    let sensorStatus: TelemetryReadingStatus
    let thermalState: String
    let sensors: SensorSnapshot?
    let fans: FanSnapshot?
    let telemetry: SystemTelemetrySnapshot
    let appResources: AppResourceSnapshot
    let cpuUsage: Double?
    let networkDownBps: Double?
    let networkUpBps: Double?
    let diskReadBps: Double?
    let diskWriteBps: Double?

    var detailLines: [MenuInfoLine] {
        var lines: [MenuInfoLine] = [
            MenuInfoLine(title: "Temperaturas", value: componentTemperatureSummary),
            MenuInfoLine(title: "Temp max", value: hottestTemperature.map(menuFormatTemperature) ?? "sin datos"),
            MenuInfoLine(title: "CPU", value: "\(cpuUsage.map(menuFormatPercent) ?? "calculando") (\(telemetry.cpu.coreCount) núcleos)"),
            MenuInfoLine(title: "GPU", value: gpuSummary),
            MenuInfoLine(title: "RAM", value: "\(menuFormatPercent(telemetry.memory.usedRatio)) usada, presión \(telemetry.memory.pressureDescription)"),
            MenuInfoLine(title: "Ventiladores", value: "\(averageRPM.map(menuFormatRPM) ?? "sin datos") media"),
            MenuInfoLine(title: "Red", value: "↓ \(networkDownBps.map(menuFormatRate) ?? "calculando") · ↑ \(networkUpBps.map(menuFormatRate) ?? "calculando")"),
            MenuInfoLine(title: "Disco I/O", value: "↓ \(diskReadBps.map(menuFormatRate) ?? "calculando") · ↑ \(diskWriteBps.map(menuFormatRate) ?? "calculando")"),
            MenuInfoLine(title: "Disco", value: "\(menuFormatBytes(telemetry.disk.availableBytes)) libres"),
            MenuInfoLine(title: "Mantenimiento", value: menuAppResourceSummary(appResources)),
            MenuInfoLine(title: "Estado térmico", value: thermalState)
        ]

        if let battery = telemetry.battery {
            lines.insert(MenuInfoLine(title: "Batería", value: menuBatterySummary(battery)), at: 6)
        }

        return lines
    }

    private var hottestTemperature: Double? {
        sensors?.hottestTemperature.map { Double($0.value) }
    }

    var cpuTemperature: Double? {
        hottestTemperature(group: .cpu)
    }

    var gpuTemperature: Double? {
        hottestTemperature(group: .gpu)
    }

    var memoryTemperature: Double? {
        hottestTemperature(group: .memory)
    }

    var systemTemperature: Double? {
        hottestTemperature(group: .system)
    }

    var componentTemperatureSummary: String {
        let parts = [
            ("CPU", cpuTemperature),
            ("GPU", gpuTemperature),
            ("RAM", memoryTemperature),
            ("SYS", systemTemperature)
        ]
        .compactMap { label, temperature in
            temperature.map { "\(label) \(compactTemperature($0))" }
        }
        return parts.isEmpty ? "sin datos" : parts.joined(separator: " | ")
    }

    private func hottestTemperature(group: SensorGroup) -> Double? {
        sensors?
            .readings(type: .temperature, group: group)
            .map { Double($0.value) }
            .max()
    }

    private var averageRPM: Double? {
        guard let fanReadings = fans?.fans, !fanReadings.isEmpty else {
            return nil
        }

        let total = fanReadings.reduce(Double(0)) { $0 + Double(max($1.actualRPM, 0)) }
        return total / Double(fanReadings.count)
    }

    var gpuSummary: String {
        guard let gpu = telemetry.gpu else {
            return "sin lectura fiable"
        }

        var parts: [String] = []
        if let usage = gpu.utilizationRatio {
            parts.append("\(menuFormatPercent(usage)) uso")
        }
        if let renderer = gpu.rendererUtilizationPercent {
            parts.append("\(Int(renderer.rounded()))% renderer")
        }
        if let tiler = gpu.tilerUtilizationPercent {
            parts.append("\(Int(tiler.rounded()))% tiler")
        }
        if let memory = gpu.inUseMemoryBytes {
            parts.append("\(menuFormatBytes(memory)) memoria")
        }

        let detail = parts.isEmpty ? "sin actividad" : parts.joined(separator: ", ")
        if let coreCount = gpu.coreCount {
            return "\(gpu.model), \(coreCount) núcleos, \(detail)"
        }
        return "\(gpu.model), \(detail)"
    }

    static func make(shared: SharedTelemetrySnapshot, previous: MenuBarSnapshot?) -> MenuBarSnapshot {
        let date = shared.date
        let previous = previous.flatMap {
            $0.samplingEpoch == shared.samplingEpoch && TelemetryContinuity.isContinuous(from: $0.date, to: date) ? $0 : nil
        }
        let telemetry = shared.telemetry
        let sensors = shared.sensorStatus.isCurrent ? shared.sensors : nil
        let fans = shared.fanStatus.isCurrent ? shared.fans : nil
        let smcDate = shared.smcDate
        let interval = previous.map { max(date.timeIntervalSince($0.date), 0.1) }
        let networkDownBps = computeRate(
            current: telemetry.network.totalReceivedBytes,
            previous: previous?.telemetry.network.totalReceivedBytes,
            interval: interval
        )
        let networkUpBps = computeRate(
            current: telemetry.network.totalSentBytes,
            previous: previous?.telemetry.network.totalSentBytes,
            interval: interval
        )
        let diskReadBps = shared.diskReadBps
        let diskWriteBps = shared.diskWriteBps
        let cpuUsage = menuComputeCPUUsage(current: telemetry.cpu, previous: previous?.telemetry.cpu)

        return MenuBarSnapshot(
            date: date,
            samplingEpoch: shared.samplingEpoch,
            smcDate: smcDate,
            fanStatus: shared.fanStatus,
            sensorStatus: shared.sensorStatus,
            thermalState: thermalStateDescription(ProcessInfo.processInfo.thermalState),
            sensors: sensors,
            fans: fans,
            telemetry: telemetry,
            appResources: shared.appResources,
            cpuUsage: cpuUsage,
            networkDownBps: networkDownBps,
            networkUpBps: networkUpBps,
            diskReadBps: diskReadBps,
            diskWriteBps: diskWriteBps
        )
    }
}

private final class StatusMenuTitleView: NSView {
    var text: String = "" {
        didSet { label.stringValue = text }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.font = font
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.98)
        label.frame = NSRect(x: 16, y: 6, width: frameRect.width - 32, height: 18)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class StatusMenuHeaderView: NSView {
    var text: String = "" {
        didSet { label.stringValue = text.uppercased() }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.58)
        label.frame = NSRect(x: 16, y: 4, width: frameRect.width - 32, height: 12)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class StatusMenuInfoView: NSView {
    var leadingText: String = "" {
        didSet { leadingLabel.stringValue = leadingText }
    }

    var trailingText: String = "" {
        didSet { trailingLabel.stringValue = trailingText }
    }

    private let leadingLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        leadingLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        leadingLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.64)
        leadingLabel.lineBreakMode = .byTruncatingTail
        leadingLabel.frame = NSRect(x: 16, y: 4, width: 118, height: 16)
        addSubview(leadingLabel)

        trailingLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        trailingLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.97)
        trailingLabel.alignment = .right
        trailingLabel.lineBreakMode = .byTruncatingMiddle
        trailingLabel.frame = NSRect(x: 138, y: 4, width: frameRect.width - 154, height: 16)
        addSubview(trailingLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class CompactStatusBarView: NSView {
    private static let sectionGap: CGFloat = 1
    private static let metricWidth: CGFloat = 32
    private static let networkWidth: CGFloat = 58

    static func preferredWidth(for sections: [MenuBarSection]) -> CGFloat {
        let widths = sections.map(sectionWidth)
        let gaps = max(sections.count - 1, 0)
        return widths.reduce(0, +) + CGFloat(gaps) * sectionGap
    }

    var snapshot: MenuBarSnapshot? {
        didSet { needsDisplay = true }
    }

    var enabledSections: [MenuBarSection] = [.cpu, .gpu, .memory, .network] {
        didSet { needsDisplay = true }
    }

    var isCleaning = false {
        didSet { needsDisplay = true }
    }

    private let labelFont = NSFont.monospacedSystemFont(ofSize: 6.5, weight: .medium)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.3, weight: .semibold)
    private let temperatureFont = NSFont.monospacedDigitSystemFont(ofSize: 6.9, weight: .medium)
    private let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 9.3, weight: .semibold)
    private let labelColor = NSColor(calibratedWhite: 1, alpha: 0.74)
    private let valueColor = NSColor(calibratedWhite: 1, alpha: 0.96)
    private let temperatureColor = NSColor(calibratedWhite: 1, alpha: 0.78)
    private let uploadColor = NSColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
    private let downloadColor = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    static func section(at x: CGFloat, enabledSections: [MenuBarSection]) -> MenuBarSection {
        var cursor: CGFloat = 0
        for section in enabledSections {
            let width = sectionWidth(section)
            if x < cursor + width + sectionGap / 2 {
                return section
            }
            cursor += width + sectionGap
        }
        return enabledSections.last ?? .overview
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor.clear.setFill()
        bounds.fill()

        let y = max(0, (bounds.height - 23) / 2)
        var cursor: CGFloat = 0
        for section in enabledSections {
            switch section {
            case .overview:
                continue
            case .cpu:
                drawMetric(
                    label: "CPU",
                    value: snapshot?.cpuUsage.map(menuFormatPercent) ?? "--",
                    temperature: compactTemperature(snapshot?.cpuTemperature),
                    x: cursor,
                    y: y
                )
            case .gpu:
                drawMetric(
                    label: "GPU",
                    value: snapshot?.telemetry.gpu?.utilizationRatio.map(menuFormatPercent) ?? "--",
                    temperature: compactTemperature(snapshot?.gpuTemperature),
                    x: cursor,
                    y: y
                )
            case .memory:
                drawMetric(
                    label: "RAM",
                    value: snapshot.flatMap { $0.telemetry.memory.isAvailable ? menuFormatPercent($0.telemetry.memory.usedRatio) : nil } ?? "--",
                    temperature: compactTemperature(snapshot?.memoryTemperature),
                    x: cursor,
                    y: y
                )
            case .network:
                drawNetwork(
                    up: compactStatusRate(snapshot?.networkUpBps),
                    down: compactStatusRate(snapshot?.networkDownBps),
                    x: cursor,
                    y: y
                )
            case .battery:
                drawMetric(
                    label: "BAT",
                    value: snapshot?.telemetry.battery.map { "\($0.percent)%" } ?? "--",
                    temperature: compactBatteryStatus(snapshot?.telemetry.battery),
                    x: cursor,
                    y: y
                )
            }
            cursor += Self.sectionWidth(section) + Self.sectionGap
        }
    }

    private func drawMetric(label: String, value: String, temperature: String, x: CGFloat, y: CGFloat) {
        drawCentered(
            label,
            font: labelFont,
            color: labelColor,
            rect: NSRect(x: x, y: y + 0.1, width: Self.metricWidth, height: 7)
        )
        drawCentered(
            value,
            font: valueFont,
            color: valueColor,
            rect: NSRect(x: x, y: y + 7.0, width: Self.metricWidth, height: 10)
        )
        drawCentered(
            temperature,
            font: temperatureFont,
            color: temperatureColor,
            rect: NSRect(x: x, y: y + 16.0, width: Self.metricWidth, height: 7)
        )
    }

    private func drawNetwork(up: String, down: String, x: CGFloat, y: CGFloat) {
        drawDot(color: uploadColor, rect: NSRect(x: x + 3, y: y + 4.2, width: 5.2, height: 5.2))
        drawText(up, font: networkFont, color: valueColor, point: NSPoint(x: x + 14, y: y + 0.9))

        drawDot(color: downloadColor, rect: NSRect(x: x + 3, y: y + 13.5, width: 5.2, height: 5.2))
        drawText(down, font: networkFont, color: valueColor, point: NSPoint(x: x + 14, y: y + 10.2))
    }

    private static func sectionWidth(_ section: MenuBarSection) -> CGFloat {
        section == .network ? networkWidth : metricWidth
    }

    private func drawCentered(_ text: String, font: NSFont, color: NSColor, rect: NSRect) {
        let size = text.size(withAttributes: [.font: font])
        drawText(
            text,
            font: font,
            color: color,
            point: NSPoint(x: rect.midX - size.width / 2, y: rect.minY)
        )
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, point: NSPoint) {
        text.draw(
            at: point,
            withAttributes: [
                .font: font,
                .foregroundColor: color
            ]
        )
    }

    private func drawDot(color: NSColor, rect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

private func menuComputeCPUUsage(current: CPUSnapshot, previous: CPUSnapshot?) -> Double? {
    guard let previous,
          current.totalTicks >= previous.totalTicks,
          current.totalActiveTicks >= previous.totalActiveTicks else {
        return nil
    }

    let totalDelta = current.totalTicks - previous.totalTicks
    let activeDelta = current.totalActiveTicks - previous.totalActiveTicks
    guard totalDelta > 0 else {
        return nil
    }

    return min(max(Double(activeDelta) / Double(totalDelta), 0), 1)
}

private func computeRate(current: UInt64, previous: UInt64?, interval: TimeInterval?) -> Double? {
    guard let previous, let interval, current >= previous else {
        return nil
    }
    return Double(current - previous) / interval
}

private func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
        return "nominal"
    case .fair:
        return "moderado"
    case .serious:
        return "alto"
    case .critical:
        return "crítico"
    @unknown default:
        return "desconocido"
    }
}

private func menuFormatRPM(_ value: Double) -> String {
    "\(Int(value.rounded())) RPM"
}

private func menuFormatTemperature(_ value: Double) -> String {
    String(format: "%.1f C", value)
}

private func compactTemperature(_ value: Double?) -> String {
    guard let value else {
        return "--"
    }
    return "\(Int(value.rounded()))C"
}

private func compactBatteryStatus(_ battery: BatterySnapshot?) -> String {
    guard let battery else {
        return "--"
    }
    if battery.isCharged {
        return "full"
    }
    if battery.isCharging {
        return "chg"
    }
    if let temperature = battery.temperatureCelsius {
        return "\(Int(temperature.rounded()))C"
    }
    return battery.externalConnected ? "AC" : "bat"
}

private func menuFormatPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func menuFormatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.statusBarStorage.string(fromByteCount: Int64(bytes))
}

private func menuFormatRate(_ bytesPerSecond: Double) -> String {
    "\(menuFormatRateValue(bytesPerSecond)) \(menuRateUnit(bytesPerSecond))"
}

private func compactNetworkRate(down: Double?, up: Double?) -> String {
    let downText = down.map(compactRateValue) ?? "--"
    let upText = up.map(compactRateValue) ?? "--"
    return "\(downText)/\(upText)"
}

private func statusBarRate(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else {
        return "--"
    }

    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded())) B/s"
}

private func compactStatusRate(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond else {
        return "--"
    }

    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1fMB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.0fKB/s", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded()))B/s"
}

private func compactRateValue(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1fM", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.0fK", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded()))B"
}

private func menuFormatRateValue(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded()))"
}

private func menuRateUnit(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return "MB/s"
    }
    if bytesPerSecond >= 1_000 {
        return "KB/s"
    }
    return "B/s"
}

private func batteryStatusDescription(_ battery: BatterySnapshot) -> String {
    if battery.isCharged {
        return "cargada"
    }
    if battery.isCharging {
        return "cargando"
    }
    if battery.externalConnected {
        return battery.isChargingPaused ? "conectada, carga en pausa" : "en corriente"
    }
    return "en batería"
}

private func menuBatterySummary(_ battery: BatterySnapshot) -> String {
    var parts = ["\(battery.percent)%"]

    if battery.isCharged {
        parts.append("cargada")
    } else if battery.isCharging {
        parts.append("cargando")
    } else if battery.externalConnected {
        parts.append("corriente")
    }

    if let cycles = battery.cycleCount {
        parts.append("\(cycles) ciclos")
    }

    if let health = battery.healthPercent {
        parts.append("salud \(health)%")
    }

    if let temperature = battery.temperatureCelsius {
        parts.append(String(format: "%.1f C", temperature))
    }

    return parts.joined(separator: " | ")
}

private func menuAppResourceSummary(_ resources: AppResourceSnapshot) -> String {
    let cpu = resources.cpuRatio.map(menuFormatPercent) ?? "calculando"
    return "CPU \(cpu) | RAM \(menuFormatBytes(resources.residentMemoryBytes))"
}

private extension ByteCountFormatter {
    static var statusBarStorage: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }
}
