import ApplicationServices
import Foundation

final class InputBlocker {
    var onEmergencyUnlock: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func isInputMonitoringTrusted(prompt: Bool) -> Bool {
        if #available(macOS 10.15, *) {
            return prompt ? CGRequestListenEventAccess() : CGPreflightListenEventAccess()
        }
        return true
    }

    func start() throws {
        stop()

        let coreMask = eventMask([
            .keyDown,
            .keyUp,
            .flagsChanged,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel
        ])

        let extendedMask = coreMask
            | eventMask([.tabletPointer, .tabletProximity])

        guard let tap = createTap(mask: extendedMask) ?? createTap(mask: coreMask) else {
            throw InputBlockerError.eventTapUnavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw InputBlockerError.runLoopSourceUnavailable
        }

        eventTap = tap
        runLoopSource = source
        runLoop = CFRunLoopGetMain()

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(runLoop ?? CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        runLoop = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if shouldEmergencyUnlock(type: type, event: event) {
            onEmergencyUnlock?()
        }

        return nil
    }

    private func shouldEmergencyUnlock(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else {
            return false
        }

        let escapeKeyCode: Int64 = 53
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let requiredFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

        return keyCode == escapeKeyCode && flags.intersection(requiredFlags) == requiredFlags
    }

    private func eventMask(_ eventTypes: [CGEventType]) -> CGEventMask {
        eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
    }

    private func createTap(mask: CGEventMask) -> CFMachPort? {
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap, .cgAnnotatedSessionEventTap] {
            if let tap = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: inputBlockerCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                return tap
            }
        }
        return nil
    }
}

private let inputBlockerCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let blocker = Unmanaged<InputBlocker>.fromOpaque(userInfo).takeUnretainedValue()
    return blocker.handle(type: type, event: event)
}

enum InputBlockerError: LocalizedError {
    case eventTapUnavailable
    case runLoopSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "macOS no permitió crear el filtro de teclado/ratón. Activa Mantenimiento en Accesibilidad y Monitorización de entrada. Si ya aparecen activas, quita Mantenimiento de ambas listas, vuelve a abrir /Applications/Mantenimiento.app y añádelo de nuevo."
        case .runLoopSourceUnavailable:
            return "No se pudo conectar el filtro de entrada al bucle principal de la app."
        }
    }
}
