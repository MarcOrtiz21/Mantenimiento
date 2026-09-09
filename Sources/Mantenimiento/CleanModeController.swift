import AppKit

protocol CleanModeControllerDelegate: AnyObject {
    func cleanModeStateDidChange(_ controller: CleanModeController)
}

final class CleanModeController {
    weak var delegate: CleanModeControllerDelegate?

    private let inputBlocker = InputBlocker()
    private var overlayWindows: [CleanOverlayWindow] = []
    private var countdownTimer: Timer?
    private var endDate: Date?
    private var screenObserver: NSObjectProtocol?

    var isActive: Bool {
        endDate != nil
    }

    init(delegate: CleanModeControllerDelegate?) {
        self.delegate = delegate
        inputBlocker.onEmergencyUnlock = { [weak self] in
            DispatchQueue.main.async {
                self?.stop()
            }
        }
    }

    deinit {
        stop()
    }

    func start(duration: TimeInterval) throws {
        if !InputBlocker.isAccessibilityTrusted(prompt: true) {
            throw CleanModeError.accessibilityPermissionMissing
        }

        if !InputBlocker.isInputMonitoringTrusted(prompt: true) {
            throw CleanModeError.inputMonitoringPermissionMissing
        }

        stop()

        endDate = Date().addingTimeInterval(duration)

        do {
            try inputBlocker.start()
            createOverlayWindows()
            installScreenObserver()
            startTimer()
            delegate?.cleanModeStateDidChange(self)
        } catch {
            endDate = nil
            inputBlocker.stop()
            closeOverlayWindows()
            removeScreenObserver()
            throw error
        }
    }

    func stop() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        endDate = nil

        inputBlocker.stop()
        closeOverlayWindows()
        removeScreenObserver()
        delegate?.cleanModeStateDidChange(self)
    }

    private func startTimer() {
        updateOverlayCountdown()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(countdownTimer!, forMode: .common)
    }

    private func tick() {
        guard let endDate else {
            stop()
            return
        }

        if Date() >= endDate {
            stop()
            return
        }

        updateOverlayCountdown()
    }

    private func updateOverlayCountdown() {
        let remaining = max(0, Int(ceil(endDate?.timeIntervalSinceNow ?? 0)))
        overlayWindows.forEach { $0.update(remainingSeconds: remaining) }
    }

    private func createOverlayWindows() {
        closeOverlayWindows()
        overlayWindows = NSScreen.screens.map { screen in
            let window = CleanOverlayWindow(screen: screen)
            window.update(remainingSeconds: max(0, Int(ceil(endDate?.timeIntervalSinceNow ?? 0))))
            window.orderFrontRegardless()
            return window
        }
    }

    private func closeOverlayWindows() {
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard self?.isActive == true else {
                return
            }
            self?.createOverlayWindows()
        }
    }

    private func removeScreenObserver() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
    }
}

enum CleanModeError: LocalizedError {
    case accessibilityPermissionMissing
    case inputMonitoringPermissionMissing

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Activa Mantenimiento en Ajustes del Sistema > Privacidad y seguridad > Accesibilidad, y vuelve a intentarlo."
        case .inputMonitoringPermissionMissing:
            return "Activa Mantenimiento en Ajustes del Sistema > Privacidad y seguridad > Monitorización de entrada, y vuelve a intentarlo."
        }
    }
}
