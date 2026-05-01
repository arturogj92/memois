import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Global hotkey via Carbon's `RegisterEventHotKey`.
///
/// The Carbon Event Manager hotkey API does not go through TCC's Input
/// Monitoring or Accessibility services, so it works on macOS Tahoe where
/// `CGEvent.tapCreate` is unreliable due to stale cdhash bindings. Same API
/// used by Spotlight, Raycast, Alfred, etc.
final class GlobalShortcutMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private let keyCode: UInt32
    private let requiredFlags: CGEventFlags
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyID: UInt32 = 0
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var isPressed = false

    private static let lock = NSLock()
    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: WeakMonitor] = [:]
    private static var sharedHandler: EventHandlerRef?

    private final class WeakMonitor {
        weak var value: GlobalShortcutMonitor?
        init(_ value: GlobalShortcutMonitor) { self.value = value }
    }

    init(keyCode: Int, requiredFlags: CGEventFlags) {
        self.keyCode = UInt32(keyCode)
        self.requiredFlags = requiredFlags
    }

    deinit { stop() }

    func start() {
        stop()

        Self.installSharedHandlerIfNeeded()

        Self.lock.lock()
        let id = Self.nextID
        Self.nextID &+= 1
        Self.registry[id] = WeakMonitor(self)
        Self.lock.unlock()
        hotKeyID = id

        let modifiers = Self.carbonModifiers(from: requiredFlags)
        let eventID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            eventID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            hotKeyRef = ref
            MemoisDebugLog.shared.write("GlobalShortcutMonitor: registered hotkey id=\(id) keyCode=\(keyCode) carbonMods=\(modifiers)")
        } else {
            MemoisDebugLog.shared.write("GlobalShortcutMonitor: RegisterEventHotKey FAILED status=\(status) id=\(id) keyCode=\(keyCode) carbonMods=\(modifiers)")
            Self.lock.lock()
            Self.registry.removeValue(forKey: id)
            Self.lock.unlock()
            hotKeyID = 0
        }

        // Local NSEvent monitors stop NSBeep when our own window has focus
        // (Carbon hotkeys are dispatched independently of the responder chain,
        // so without this the key combo also bubbles to the focused control).
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.matchesShortcut(event) else { return event }
            return nil
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.matchesShortcut(event) else { return event }
            return nil
        }
    }

    func stop() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if hotKeyID != 0 {
            Self.lock.lock()
            Self.registry.removeValue(forKey: hotKeyID)
            Self.lock.unlock()
            hotKeyID = 0
        }
        if let monitor = localKeyDownMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyDownMonitor = nil
        }
        if let monitor = localKeyUpMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyUpMonitor = nil
        }
        isPressed = false
    }

    fileprivate func dispatchPressed() {
        guard !isPressed else { return }
        isPressed = true
        onPress?()
    }

    fileprivate func dispatchReleased() {
        guard isPressed else { return }
        isPressed = false
        onRelease?()
    }

    private func matchesShortcut(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == keyCode else { return false }
        let flags = event.modifierFlags.intersection([.shift, .option, .command, .control, .function])
        return flags == Self.cgFlagsToNSFlags(requiredFlags)
    }

    // MARK: - Static dispatch

    /// 'MEMO' four-char-code so events from this app are distinguishable.
    private static let signature: OSType = 0x4D454D4F

    private static func installSharedHandlerIfNeeded() {
        lock.lock()
        let needsInstall = (sharedHandler == nil)
        lock.unlock()
        guard needsInstall else { return }

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }

                GlobalShortcutMonitor.lock.lock()
                let monitor = GlobalShortcutMonitor.registry[hotKeyID.id]?.value
                GlobalShortcutMonitor.lock.unlock()
                guard let monitor else { return noErr }

                let kind = GetEventKind(eventRef)
                MemoisDebugLog.shared.write(">>> CARBON HOTKEY id=\(hotKeyID.id) kind=\(kind) <<<")
                DispatchQueue.main.async {
                    if kind == UInt32(kEventHotKeyPressed) {
                        monitor.dispatchPressed()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        monitor.dispatchReleased()
                    }
                }
                return noErr
            },
            specs.count,
            &specs,
            nil,
            &handler
        )

        lock.lock()
        if status == noErr, let handler {
            sharedHandler = handler
            MemoisDebugLog.shared.write("GlobalShortcutMonitor: Carbon event handler installed")
        } else {
            MemoisDebugLog.shared.write("GlobalShortcutMonitor: InstallEventHandler FAILED status=\(status)")
        }
        lock.unlock()
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        return mods
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
}
