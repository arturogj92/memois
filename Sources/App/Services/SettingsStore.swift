import Foundation
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    @Published var assemblyAIKey: String {
        didSet { userDefaults.set(assemblyAIKey, forKey: Keys.assemblyAIKey) }
    }

    @Published var shortcutKeyCode: Int {
        didSet { userDefaults.set(shortcutKeyCode, forKey: Keys.shortcutKeyCode) }
    }

    @Published var shortcutModifierFlagsRawValue: UInt64 {
        didSet { userDefaults.set(shortcutModifierFlagsRawValue, forKey: Keys.shortcutModifierFlagsRawValue) }
    }

    @Published var shortcutDescription: String {
        didSet { userDefaults.set(shortcutDescription, forKey: Keys.shortcutDescription) }
    }

    @Published var screenshotShortcutKeyCode: Int {
        didSet { userDefaults.set(screenshotShortcutKeyCode, forKey: Keys.screenshotShortcutKeyCode) }
    }

    @Published var screenshotShortcutModifierFlagsRawValue: UInt64 {
        didSet { userDefaults.set(screenshotShortcutModifierFlagsRawValue, forKey: Keys.screenshotShortcutModifierFlagsRawValue) }
    }

    @Published var screenshotShortcutDescription: String {
        didSet { userDefaults.set(screenshotShortcutDescription, forKey: Keys.screenshotShortcutDescription) }
    }

    @Published var selectedMicrophoneUID: String? {
        didSet { userDefaults.set(selectedMicrophoneUID, forKey: Keys.selectedMicrophoneUID) }
    }

    @Published var soundEffectsEnabled: Bool {
        didSet { userDefaults.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled) }
    }

    @Published var startRecordingSound: String {
        didSet { userDefaults.set(startRecordingSound, forKey: Keys.startRecordingSound) }
    }

    @Published var stopRecordingSound: String {
        didSet { userDefaults.set(stopRecordingSound, forKey: Keys.stopRecordingSound) }
    }

    @Published var showIndicatorOnlyWhenRecording: Bool {
        didSet { userDefaults.set(showIndicatorOnlyWhenRecording, forKey: Keys.showIndicatorOnlyWhenRecording) }
    }

    @Published var floatingPanelFreePosition: Bool {
        didSet { userDefaults.set(floatingPanelFreePosition, forKey: Keys.floatingPanelFreePosition) }
    }

    @Published var floatingPanelX: Double? {
        didSet {
            if let v = floatingPanelX { userDefaults.set(v, forKey: Keys.floatingPanelX) }
            else { userDefaults.removeObject(forKey: Keys.floatingPanelX) }
        }
    }

    @Published var floatingPanelY: Double? {
        didSet {
            if let v = floatingPanelY { userDefaults.set(v, forKey: Keys.floatingPanelY) }
            else { userDefaults.removeObject(forKey: Keys.floatingPanelY) }
        }
    }

    @Published var transcriptionModel: String {
        didSet { userDefaults.set(transcriptionModel, forKey: Keys.transcriptionModel) }
    }

    @Published var speakerDiarization: Bool {
        didSet { userDefaults.set(speakerDiarization, forKey: Keys.speakerDiarization) }
    }

    @Published var startAtLogin: Bool {
        didSet {
            userDefaults.set(startAtLogin, forKey: Keys.startAtLogin)
            applyLoginItem()
        }
    }

    @Published var hideDockIcon: Bool {
        didSet { userDefaults.set(hideDockIcon, forKey: Keys.hideDockIcon) }
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Default shortcut: Option + Shift + R
        self.assemblyAIKey = userDefaults.string(forKey: Keys.assemblyAIKey) ?? ""
        self.shortcutKeyCode = userDefaults.object(forKey: Keys.shortcutKeyCode) as? Int ?? kVK_ANSI_R
        self.shortcutModifierFlagsRawValue = userDefaults.object(forKey: Keys.shortcutModifierFlagsRawValue) as? UInt64 ?? SettingsStore.defaultModifierFlags.rawValue
        self.shortcutDescription = userDefaults.string(forKey: Keys.shortcutDescription) ?? ShortcutFormatter.description(
            keyCode: kVK_ANSI_R,
            modifiers: SettingsStore.defaultModifierFlags
        )
        self.screenshotShortcutKeyCode = userDefaults.object(forKey: Keys.screenshotShortcutKeyCode) as? Int ?? kVK_ANSI_S
        self.screenshotShortcutModifierFlagsRawValue = userDefaults.object(forKey: Keys.screenshotShortcutModifierFlagsRawValue) as? UInt64 ?? SettingsStore.defaultModifierFlags.rawValue
        self.screenshotShortcutDescription = userDefaults.string(forKey: Keys.screenshotShortcutDescription) ?? ShortcutFormatter.description(
            keyCode: kVK_ANSI_S,
            modifiers: SettingsStore.defaultModifierFlags
        )
        self.selectedMicrophoneUID = userDefaults.string(forKey: Keys.selectedMicrophoneUID)
        self.soundEffectsEnabled = userDefaults.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true
        self.startRecordingSound = userDefaults.string(forKey: Keys.startRecordingSound) ?? "Frog"
        self.stopRecordingSound = userDefaults.string(forKey: Keys.stopRecordingSound) ?? "Pop"
        self.showIndicatorOnlyWhenRecording = userDefaults.object(forKey: Keys.showIndicatorOnlyWhenRecording) as? Bool ?? true
        self.floatingPanelFreePosition = userDefaults.object(forKey: Keys.floatingPanelFreePosition) as? Bool ?? true
        self.floatingPanelX = userDefaults.object(forKey: Keys.floatingPanelX) as? Double
        self.floatingPanelY = userDefaults.object(forKey: Keys.floatingPanelY) as? Double
        self.transcriptionModel = userDefaults.string(forKey: Keys.transcriptionModel) ?? "best"
        self.speakerDiarization = userDefaults.object(forKey: Keys.speakerDiarization) as? Bool ?? true
        self.startAtLogin = userDefaults.object(forKey: Keys.startAtLogin) as? Bool ?? false
        self.hideDockIcon = userDefaults.object(forKey: Keys.hideDockIcon) as? Bool ?? false
    }

    var shortcutModifierFlags: CGEventFlags {
        CGEventFlags(rawValue: shortcutModifierFlagsRawValue)
    }

    func updateShortcut(keyCode: Int, modifierFlags: CGEventFlags) {
        shortcutKeyCode = keyCode
        shortcutModifierFlagsRawValue = modifierFlags.rawValue
        shortcutDescription = ShortcutFormatter.description(keyCode: keyCode, modifiers: modifierFlags)
    }

    func resetShortcutToDefault() {
        updateShortcut(keyCode: kVK_ANSI_R, modifierFlags: Self.defaultModifierFlags)
    }

    var screenshotShortcutModifierFlags: CGEventFlags {
        CGEventFlags(rawValue: screenshotShortcutModifierFlagsRawValue)
    }

    func updateScreenshotShortcut(keyCode: Int, modifierFlags: CGEventFlags) {
        screenshotShortcutKeyCode = keyCode
        screenshotShortcutModifierFlagsRawValue = modifierFlags.rawValue
        screenshotShortcutDescription = ShortcutFormatter.description(keyCode: keyCode, modifiers: modifierFlags)
    }

    func resetScreenshotShortcutToDefault() {
        updateScreenshotShortcut(keyCode: kVK_ANSI_S, modifierFlags: Self.defaultModifierFlags)
    }

    func resetFloatingPanelPosition() {
        floatingPanelX = nil
        floatingPanelY = nil
    }

    func applyLoginItem() {
        if startAtLogin {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }

    static let defaultModifierFlags: CGEventFlags = [.maskShift, .maskAlternate]

    static let availableModels: [(id: String, label: String)] = [
        ("best", "Best (Universal-3 Pro)"),
        ("nano", "Nano (Fast & cheap)"),
    ]
}

private enum Keys {
    static let assemblyAIKey = "settings.assemblyAIKey"
    static let shortcutKeyCode = "settings.shortcutKeyCode"
    static let shortcutModifierFlagsRawValue = "settings.shortcutModifierFlagsRawValue"
    static let shortcutDescription = "settings.shortcutDescription"
    static let screenshotShortcutKeyCode = "settings.screenshotShortcutKeyCode"
    static let screenshotShortcutModifierFlagsRawValue = "settings.screenshotShortcutModifierFlagsRawValue"
    static let screenshotShortcutDescription = "settings.screenshotShortcutDescription"
    static let selectedMicrophoneUID = "settings.selectedMicrophoneUID"
    static let soundEffectsEnabled = "settings.soundEffectsEnabled"
    static let startRecordingSound = "settings.startRecordingSound"
    static let stopRecordingSound = "settings.stopRecordingSound"
    static let showIndicatorOnlyWhenRecording = "settings.showIndicatorOnlyWhenRecording"
    static let floatingPanelFreePosition = "settings.floatingPanelFreePosition"
    static let floatingPanelX = "settings.floatingPanelX"
    static let floatingPanelY = "settings.floatingPanelY"
    static let transcriptionModel = "settings.transcriptionModel"
    static let speakerDiarization = "settings.speakerDiarization"
    static let startAtLogin = "settings.startAtLogin"
    static let hideDockIcon = "settings.hideDockIcon"
}
