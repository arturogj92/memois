import Carbon.HIToolbox
import CoreGraphics
import SwiftUI

struct ShortcutRecorderSheet: View {
    let title: String
    let currentDescription: String
    let onSave: (Int, CGEventFlags) -> Void
    let onReset: () -> Void
    @Binding var isPresented: Bool

    @State private var eventMonitor: Any?
    @State private var helperText = "Press the new shortcut now"

    init(
        settings: SettingsStore,
        isPresented: Binding<Bool>
    ) {
        self.title = "Record Shortcut"
        self.currentDescription = settings.shortcutDescription
        self.onSave = { keyCode, flags in settings.updateShortcut(keyCode: keyCode, modifierFlags: flags) }
        self.onReset = { settings.resetShortcutToDefault() }
        self._isPresented = isPresented
    }

    init(
        title: String,
        currentDescription: String,
        onSave: @escaping (Int, CGEventFlags) -> Void,
        onReset: @escaping () -> Void,
        isPresented: Binding<Bool>
    ) {
        self.title = title
        self.currentDescription = currentDescription
        self.onSave = onSave
        self.onReset = onReset
        self._isPresented = isPresented
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.bold))

            Text(helperText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Current: \(currentDescription)")
                .font(.system(size: 13, weight: .medium, design: .rounded))

            HStack {
                Button("Use Default") {
                    onReset()
                    isPresented = false
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear(perform: installEventMonitor)
        .onDisappear(perform: removeEventMonitor)
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let eventModifiers = event.modifierFlags.intersection(ShortcutFormatter.supportedEventModifierMask)
            let modifiers = CGEventFlags(rawValue: UInt64(eventModifiers.rawValue)).intersection(ShortcutFormatter.supportedModifierMask)

            if event.keyCode == UInt16(kVK_Escape) {
                isPresented = false
                return nil
            }

            guard !ShortcutFormatter.isModifierOnlyKey(event.keyCode) else {
                helperText = "Add a non-modifier key too"
                return nil
            }

            guard !ShortcutFormatter.modifierNames(for: modifiers).isEmpty else {
                helperText = "Use at least one modifier: Command, Control, Option, Shift, or Fn"
                return nil
            }

            onSave(Int(event.keyCode), modifiers)
            isPresented = false
            return nil
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}
