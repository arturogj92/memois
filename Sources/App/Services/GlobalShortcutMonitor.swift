import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class GlobalShortcutMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private let keyCode: CGKeyCode
    private let requiredFlags: CGEventFlags
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var isPressed = false

    init(keyCode: Int, requiredFlags: CGEventFlags) {
        self.keyCode = CGKeyCode(keyCode)
        self.requiredFlags = requiredFlags
    }

    func start() {
        stop()

        // CGEvent tap for global shortcut (works when other apps have focus)
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ref = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable tap if macOS disabled it (timeout or user input)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                let consumed = monitor.handle(event: event, type: type)
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: ref
        ) else {
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Local NSEvent monitors to suppress the bonk when our own window has focus.
        // The CGEvent tap may not fully prevent the event from reaching our responder chain.
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesShortcut(event) else { return event }
            return nil // swallow — prevents NSBeep
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.matchesShortcut(event) else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyDownMonitor = nil
        }
        if let monitor = localKeyUpMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyUpMonitor = nil
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }

        isPressed = false
    }

    private func matchesShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection([.shift, .option, .command, .control, .function])
        let required = Self.cgFlagsToNSFlags(requiredFlags)
        return flags == required
    }

    private static func cgFlagsToNSFlags(_ cgFlags: CGEventFlags) -> NSEvent.ModifierFlags {
        var ns = NSEvent.ModifierFlags()
        if cgFlags.contains(.maskShift) { ns.insert(.shift) }
        if cgFlags.contains(.maskAlternate) { ns.insert(.option) }
        if cgFlags.contains(.maskCommand) { ns.insert(.command) }
        if cgFlags.contains(.maskControl) { ns.insert(.control) }
        if cgFlags.contains(.maskSecondaryFn) { ns.insert(.function) }
        return ns
    }

    @discardableResult
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }

        let eventKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else { return false }

        let flags = event.flags.intersection([.maskShift, .maskAlternate, .maskCommand, .maskControl, .maskSecondaryFn])
        guard flags.contains(requiredFlags), flags == requiredFlags else {
            if type == .keyUp, isPressed {
                isPressed = false
                onRelease?()
                return true
            }
            return false
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch type {
        case .keyDown where !isRepeat && !isPressed:
            isPressed = true
            onPress?()
            return true
        case .keyDown where isRepeat:
            // Suppress key repeat sound
            return true
        case .keyUp where isPressed:
            isPressed = false
            onRelease?()
            return true
        default:
            return true
        }
    }
}
