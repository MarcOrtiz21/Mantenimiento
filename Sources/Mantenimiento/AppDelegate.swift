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

final class AppDelegate: NSObject, NSApplicationDelegate, CleanModeControllerDelegate {
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
    private var activeMenuRefreshTask: Task<Void, Never>?
    private var anomalousFanSamples = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        AlertNotificationService.shared.configure()
        configureMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.registerDefaults()
        activeProfile = AppPreferences.statusRefreshInterval >= 5 ? .silent : .balanced
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
        if AppPreferences.openPanelAtLaunch {
            openDiagnostics()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshTimer?.invalidate()
        activeMenuRefreshTask?.cancel()
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

        activeMenuRefreshTask?.cancel()
        activeMenuRefreshTask = nil
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

    private var effectiveStatusRefreshInterval: TimeInterval {
        if !AppPreferences.showStatusItem {
            return 8
        }
        if statusPopoverController?.isShown == true {
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
        configureStatusRefreshTimer()
    }

    @objc private func systemWillSleep() {
        statusRefreshTimer?.invalidate()
        restoreFansToAutoIfNeeded(asynchronously: true, reason: "suspensión del sistema")
    }

    @objc private func systemDidWake() {
        anomalousFanSamples = 0
        TelemetryStore.shared.invalidateSMC()
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
        Task {
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
                activeProfile = profile
                isApplyingProfile = false
                fanManualControlTouched = profile == .turbo
                UserDefaults.standard.set(profile.refreshInterval, forKey: AppPreferenceKeys.statusRefreshInterval)
                if profile == .turbo {
                    NotificationCenter.default.post(name: .fanManualControlDidSucceed, object: nil)
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
        let previous = previousMenuBarSnapshot
        let includeSMC = MenuBarSnapshot.shouldIncludeSMC(previous: previous, force: force)

        Task {
            let snapshot = await Task.detached(priority: .utility) {
                MenuBarSnapshot.load(previous: previous, includeSMC: includeSMC, force: force)
            }.value

            await MainActor.run {
                previousMenuBarSnapshot = snapshot
                latestMenuBarSnapshot = snapshot
                isRefreshingStatus = false
                MaintenanceAlertMonitor.shared.process(snapshot: snapshot)
                TelemetryHistoryRecorder.shared.record(snapshot: snapshot)
                updateFanSafety(with: snapshot)
                updateStatusItemVisibility()
                updateActiveStatusMenu()
                updateStatusPopover()
                if let section = activeMenuSection {
                    refreshDemandIfNeeded(for: section)
                }
            }
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
                self?.activeMenuRefreshTask?.cancel()
                self?.activeMenuRefreshTask = nil
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
        activeMenuRefreshTask?.cancel()
        activeMenuRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else {
                    return
                }
                await MainActor.run {
                    guard self.activeMenuSection == section else {
                        return
                    }
                    self.refreshMenuBarStatus()
                    self.refreshDemandIfNeeded(for: section)
                }
            }
        }
        session.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        activeMenuRefreshTask?.cancel()
        activeMenuRefreshTask = nil
        activeStatusMenu = nil
        activeMenuSection = nil
        activeMenuHandles = nil
    }

    private func updateStatusPopover() {
        guard let controller = statusPopoverController,
              controller.isShown,
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

        Task {
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
                MenuInfoLine(title: "Uso total", value: snapshot.cpuUsage.map(formatPercent) ?? "calculando"),
                MenuInfoLine(title: "Núcleos", value: "\(snapshot.telemetry.cpu.coreCount)"),
                MenuInfoLine(title: "Temperatura CPU", value: snapshot.cpuTemperature.map(formatTemperature) ?? "sin datos"),
                MenuInfoLine(title: "Estado térmico", value: snapshot.thermalState)
            ]
        case .gpu:
            return [
                MenuInfoLine(title: "Resumen", value: snapshot.gpuSummary),
                MenuInfoLine(title: "Temperatura GPU", value: snapshot.gpuTemperature.map(formatTemperature) ?? "sin datos"),
                MenuInfoLine(title: "Renderer", value: snapshot.telemetry.gpu?.rendererUtilizationPercent.map { "\(Int($0.rounded()))%" } ?? "sin datos"),
                MenuInfoLine(title: "Tiler", value: snapshot.telemetry.gpu?.tilerUtilizationPercent.map { "\(Int($0.rounded()))%" } ?? "sin datos"),
                MenuInfoLine(title: "Memoria GPU", value: snapshot.telemetry.gpu?.inUseMemoryBytes.map(formatBytes) ?? "sin datos")
            ]
        case .memory:
            return [
                MenuInfoLine(title: "Memoria usada", value: "\(formatBytes(snapshot.telemetry.memory.usedBytes)) / \(formatBytes(snapshot.telemetry.memory.totalBytes)) (\(formatPercent(snapshot.telemetry.memory.usedRatio)))"),
                MenuInfoLine(title: "Memoria de apps", value: formatBytes(snapshot.telemetry.memory.appBytes)),
                MenuInfoLine(title: "Memoria cableada", value: formatBytes(snapshot.telemetry.memory.wiredBytes)),
                MenuInfoLine(title: "Comprimida", value: formatBytes(snapshot.telemetry.memory.compressedBytes)),
                MenuInfoLine(title: "Archivos en cache", value: formatBytes(snapshot.telemetry.memory.cachedFilesBytes)),
                MenuInfoLine(title: "Temperatura memoria", value: snapshot.memoryTemperature.map(formatTemperature) ?? "sin datos"),
                MenuInfoLine(title: "Presión", value: snapshot.telemetry.memory.pressureDescription)
            ]
        case .network:
            return [
                MenuInfoLine(title: "Bajada", value: snapshot.networkDownBps.map(formatRate) ?? "calculando"),
                MenuInfoLine(title: "Subida", value: snapshot.networkUpBps.map(formatRate) ?? "calculando"),
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
            if let cycles = battery.cycleCount {
                lines.append(MenuInfoLine(title: "Ciclos", value: "\(cycles)"))
            }
            if let health = battery.healthPercent {
                lines.append(MenuInfoLine(title: "Salud", value: "\(health)%"))
            }
            if let temperature = battery.temperatureCelsius {
                lines.append(MenuInfoLine(title: "Temperatura", value: formatTemperature(temperature)))
            }
            return lines
        }
    }

    private func resetFansIfNeeded() {
        restoreFansToAutoIfNeeded(asynchronously: false, reason: "cierre de la aplicación")
    }

    private func updateFanSafety(with snapshot: MenuBarSnapshot) {
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
        guard fanManualControlTouched else {
            return
        }
        fanManualControlTouched = false
        anomalousFanSamples = 0
        TelemetryStore.shared.invalidateSMC()

        let operation = {
            do {
                try FanService.make().setAllFansAuto()
            } catch {
                guard PrivilegedFanTool.shouldRetryPrivileged(error) else {
                    appLogger.error("Could not restore fans to automatic mode after \(reason, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
                _ = try? PrivilegedFanTool.setAllFansAuto()
            }
            appLogger.info("Fans restored to automatic mode: \(reason, privacy: .public)")
        }

        if asynchronously {
            Task.detached(priority: .userInitiated, operation: operation)
        } else {
            operation()
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
            detail: "↓ \(formatBytes(received)) · ↑ \(formatBytes(sent))",
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
            MenuDemandEntry(name: name, detail: gpuTime(nanoseconds), sortValue: Double(nanoseconds))
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

private func gpuTime(_ nanoseconds: UInt64) -> String {
    let seconds = Double(nanoseconds) / 1_000_000_000
    if seconds >= 60 {
        return String(format: "%.1f min GPU", seconds / 60)
    }
    return String(format: "%.1f s GPU", seconds)
}

struct MenuBarSnapshot {
    static let smcRefreshInterval: TimeInterval = 4.5

    let date: Date
    let smcDate: Date?
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
            MenuInfoLine(title: "Temp max", value: hottestTemperature.map(formatTemperature) ?? "sin datos"),
            MenuInfoLine(title: "CPU", value: "\(cpuUsage.map(formatPercent) ?? "calculando") (\(telemetry.cpu.coreCount) núcleos)"),
            MenuInfoLine(title: "GPU", value: gpuSummary),
            MenuInfoLine(title: "RAM", value: "\(formatPercent(telemetry.memory.usedRatio)) usada, presión \(telemetry.memory.pressureDescription)"),
            MenuInfoLine(title: "Ventiladores", value: "\(averageRPM.map(formatRPM) ?? "sin datos") media"),
            MenuInfoLine(title: "Red", value: "↓ \(networkDownBps.map(formatRate) ?? "calculando") · ↑ \(networkUpBps.map(formatRate) ?? "calculando")"),
            MenuInfoLine(title: "Disco I/O", value: "↓ \(diskReadBps.map(formatRate) ?? "calculando") · ↑ \(diskWriteBps.map(formatRate) ?? "calculando")"),
            MenuInfoLine(title: "Disco", value: "\(formatBytes(telemetry.disk.availableBytes)) libres"),
            MenuInfoLine(title: "Mantenimiento", value: appResourceSummary(appResources)),
            MenuInfoLine(title: "Estado térmico", value: thermalState)
        ]

        if let battery = telemetry.battery {
            lines.insert(MenuInfoLine(title: "Batería", value: batterySummary(battery)), at: 6)
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
            parts.append("\(formatPercent(usage)) uso")
        }
        if let renderer = gpu.rendererUtilizationPercent {
            parts.append("\(Int(renderer.rounded()))% renderer")
        }
        if let tiler = gpu.tilerUtilizationPercent {
            parts.append("\(Int(tiler.rounded()))% tiler")
        }
        if let memory = gpu.inUseMemoryBytes {
            parts.append("\(formatBytes(memory)) memoria")
        }

        let detail = parts.isEmpty ? "sin actividad" : parts.joined(separator: ", ")
        if let coreCount = gpu.coreCount {
            return "\(gpu.model), \(coreCount) núcleos, \(detail)"
        }
        return "\(gpu.model), \(detail)"
    }

    static func shouldIncludeSMC(previous: MenuBarSnapshot?, force: Bool) -> Bool {
        if force || previous?.sensors == nil {
            return true
        }
        guard let smcDate = previous?.smcDate else {
            return true
        }
        return Date().timeIntervalSince(smcDate) >= smcRefreshInterval
    }

    static func load(previous: MenuBarSnapshot?, includeSMC: Bool = false, force: Bool = false) -> MenuBarSnapshot {
        let shared = TelemetryStore.shared.snapshot(
            previousTelemetry: previous?.telemetry,
            includeSMC: includeSMC,
            fullTelemetry: includeSMC,
            force: force
        )
        let date = shared.date
        let telemetry = shared.telemetry
        let sensors = shared.sensors ?? previous?.sensors
        let fans = shared.fans ?? previous?.fans
        let smcDate = shared.smcDate ?? previous?.smcDate
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
        let diskReadBps = computeRate(
            current: telemetry.diskIO.readBytes,
            previous: previous?.telemetry.diskIO.readBytes,
            interval: interval
        )
        let diskWriteBps = computeRate(
            current: telemetry.diskIO.writtenBytes,
            previous: previous?.telemetry.diskIO.writtenBytes,
            interval: interval
        )
        let cpuUsage = computeCPUUsage(current: telemetry.cpu, previous: previous?.telemetry.cpu)

        return MenuBarSnapshot(
            date: date,
            smcDate: smcDate,
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
                    value: snapshot?.cpuUsage.map(formatPercent) ?? "--",
                    temperature: compactTemperature(snapshot?.cpuTemperature),
                    x: cursor,
                    y: y
                )
            case .gpu:
                drawMetric(
                    label: "GPU",
                    value: snapshot?.telemetry.gpu?.utilizationRatio.map(formatPercent) ?? "--",
                    temperature: compactTemperature(snapshot?.gpuTemperature),
                    x: cursor,
                    y: y
                )
            case .memory:
                drawMetric(
                    label: "RAM",
                    value: snapshot.map { formatPercent($0.telemetry.memory.usedRatio) } ?? "--",
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

private func computeCPUUsage(current: CPUSnapshot, previous: CPUSnapshot?) -> Double? {
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

private func formatRPM(_ value: Double) -> String {
    "\(Int(value.rounded())) RPM"
}

private func formatTemperature(_ value: Double) -> String {
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

private func formatPercent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.statusBarStorage.string(fromByteCount: Int64(bytes))
}

private func formatRate(_ bytesPerSecond: Double) -> String {
    "\(formatRateValue(bytesPerSecond)) \(rateUnit(bytesPerSecond))"
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

private func formatRateValue(_ bytesPerSecond: Double) -> String {
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.1f", bytesPerSecond / 1_000)
    }
    return "\(Int(bytesPerSecond.rounded()))"
}

private func rateUnit(_ bytesPerSecond: Double) -> String {
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
        return "en corriente"
    }
    return "en batería"
}

private func batterySummary(_ battery: BatterySnapshot) -> String {
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

private func appResourceSummary(_ resources: AppResourceSnapshot) -> String {
    let cpu = resources.cpuRatio.map(formatPercent) ?? "calculando"
    return "CPU \(cpu) | RAM \(formatBytes(resources.residentMemoryBytes))"
}

private extension ByteCountFormatter {
    static var statusBarStorage: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }
}
