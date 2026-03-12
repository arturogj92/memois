# memois - Meeting Recording & Transcription App

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS menu bar app that records meeting audio (system + microphone), saves recordings, and transcribes them via AssemblyAI batch API.

**Architecture:** SwiftUI + AppKit hybrid, same pattern as Blablabla. ScreenCaptureKit captures system audio, AVAudioEngine captures microphone, both mixed and written to .m4a via AVAssetWriter. Transcription uses AssemblyAI's REST upload + transcribe API (batch, not streaming). Same corporate dark UI theme.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit, ScreenCaptureKit, AVFoundation, AVAudioEngine, AVAssetWriter, XcodeGen, AssemblyAI REST API

---

## Project Structure

```
memois/
├── Sources/App/
│   ├── MemoisApp.swift                    # @main SwiftUI entry
│   ├── AppDelegate.swift                  # NSApplicationDelegate lifecycle
│   ├── AppModel.swift                     # @MainActor ObservableObject state
│   ├── Models/
│   │   ├── Recording.swift                # Recording model (Codable)
│   │   └── AudioDevice.swift              # CoreAudio device enumeration
│   ├── Services/
│   │   ├── AudioRecorder.swift            # ScreenCaptureKit + AVAudioEngine → .m4a
│   │   ├── AssemblyAIClient.swift         # REST upload + transcribe (batch)
│   │   ├── GlobalShortcutMonitor.swift    # CGEvent tap (reuse from Blablabla)
│   │   ├── SettingsStore.swift            # UserDefaults wrapper
│   │   ├── PermissionManager.swift        # Mic, Screen Recording, Input Monitoring
│   │   ├── RecordingStore.swift           # JSON persistence for recordings metadata
│   │   ├── SoundEffectPlayer.swift        # AudioToolbox system sounds
│   │   └── ShortcutFormatter.swift        # Key code → human-readable
│   └── UI/
│       ├── MainWindowView.swift           # Sidebar + Recordings/Settings/Permissions
│       ├── RecordingDetailView.swift       # View a single recording + transcript
│       ├── DockTabView.swift              # Dock pill with waveform
│       ├── DockTabController.swift        # Non-activating NSPanel
│       ├── WaveformView.swift             # Animated waveform
│       └── ShortcutRecorderSheet.swift    # Keyboard shortcut capture
├── Resources/
│   ├── Info.plist
│   ├── Memois.entitlements
│   └── Assets.xcassets/
│       └── AppIcon.appiconset/
├── project.yml                            # XcodeGen
└── docs/plans/
```

---

### Task 1: Project Scaffold & XcodeGen Configuration

**Files:**
- Create: `project.yml`
- Create: `Resources/Info.plist`
- Create: `Resources/Memois.entitlements`
- Create: `Sources/App/MemoisApp.swift`

**Step 1: Create project.yml**

```yaml
name: Memois
options:
  bundleIdPrefix: com.vzgb9jp
  deploymentTarget:
    macOS: 14.0
settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: com.vzgb9jp.memois
    PRODUCT_NAME: Memois
    SWIFT_VERSION: 5.10
    GENERATE_INFOPLIST_FILE: NO
    INFOPLIST_FILE: Resources/Info.plist
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ZC8MCRVRBP
    CODE_SIGN_IDENTITY: "Developer ID Application: Arturo García Jurado (ZC8MCRVRBP)"
    CURRENT_PROJECT_VERSION: 1
    MARKETING_VERSION: 0.1.0
    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    ENABLE_APP_SANDBOX: NO
targets:
  Memois:
    type: application
    platform: macOS
    sources:
      - path: Sources/App
      - path: Resources/Assets.xcassets
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vzgb9jp.memois
        INFOPLIST_FILE: Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: Resources/Memois.entitlements
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "Developer ID Application: Arturo García Jurado (ZC8MCRVRBP)"
        ENABLE_HARDENED_RUNTIME: YES
    scheme:
      testTargets: []
```

**Step 2: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Memois</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Memois needs microphone access to record your voice during meetings.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Memois needs screen recording permission to capture system audio from meetings.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
```

**Step 3: Create entitlements**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

**Step 4: Create minimal MemoisApp.swift**

```swift
import SwiftUI

@main
struct MemoisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Memois") {
            MainWindowView(model: appDelegate.model, settings: appDelegate.model.settings)
                .frame(minWidth: 620, minHeight: 720)
        }
        .defaultPosition(.center)
        .defaultSize(width: 780, height: 760)
    }
}
```

**Step 5: Create AppIcon.appiconset from Downloads/image.png**

Copy `/Users/vzgb9jp/Downloads/image.png` to `Resources/Assets.xcassets/AppIcon.appiconset/` and create Contents.json with all required sizes.

**Step 6: Generate and verify Xcode project builds**

```bash
cd /Users/vzgb9jp/Development/memois && xcodegen generate
xcodebuild -project Memois.xcodeproj -scheme Memois build 2>&1 | tail -5
```

Expected: Build succeeds (with stub files for referenced types).

**Step 7: Commit**

```bash
git add project.yml Resources/ Sources/App/MemoisApp.swift
git commit -m "feat: project scaffold with XcodeGen, Info.plist, entitlements, and app entry point"
```

---

### Task 2: Data Models & Persistence

**Files:**
- Create: `Sources/App/Models/Recording.swift`
- Create: `Sources/App/Models/AudioDevice.swift`
- Create: `Sources/App/Services/RecordingStore.swift`

**Step 1: Create Recording model**

```swift
import Foundation

struct Recording: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let durationSeconds: Double
    let audioFileName: String

    var transcriptionFileName: String?
    var transcriptionStatus: TranscriptionStatus
    var transcriptionModel: String?
    var speakerCount: Int?

    enum TranscriptionStatus: String, Codable {
        case none
        case uploading
        case processing
        case completed
        case failed
    }

    var audioURL: URL {
        Recording.recordingsDirectory.appendingPathComponent(audioFileName)
    }

    var transcriptionURL: URL? {
        guard let name = transcriptionFileName else { return nil }
        return Recording.recordingsDirectory.appendingPathComponent(name)
    }

    var formattedDuration: String {
        let minutes = Int(durationSeconds) / 60
        let seconds = Int(durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Memois/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
```

**Step 2: Create AudioDevice model**

Reuse Blablabla's AudioDevice.swift (copy from `/Users/vzgb9jp/Development/blablabla/Sources/App/Models/AudioDevice.swift`).

**Step 3: Create RecordingStore**

```swift
import Foundation

@MainActor
final class RecordingStore {
    private let saveURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("Memois", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        self.saveURL = folder.appendingPathComponent("recordings.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [Recording] {
        guard let data = try? Data(contentsOf: saveURL) else { return [] }
        return (try? decoder.decode([Recording].self, from: data)) ?? []
    }

    func save(_ records: [Recording]) {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }
}
```

**Step 4: Commit**

```bash
git add Sources/App/Models/ Sources/App/Services/RecordingStore.swift
git commit -m "feat: Recording model, AudioDevice, and RecordingStore persistence"
```

---

### Task 3: Settings Store

**Files:**
- Create: `Sources/App/Services/SettingsStore.swift`

**Step 1: Create SettingsStore**

```swift
import Foundation
import Carbon.HIToolbox

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
        self.selectedMicrophoneUID = userDefaults.string(forKey: Keys.selectedMicrophoneUID)
        self.soundEffectsEnabled = userDefaults.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true
        self.startRecordingSound = userDefaults.string(forKey: Keys.startRecordingSound) ?? "Frog"
        self.stopRecordingSound = userDefaults.string(forKey: Keys.stopRecordingSound) ?? "Pop"
        self.showIndicatorOnlyWhenRecording = userDefaults.object(forKey: Keys.showIndicatorOnlyWhenRecording) as? Bool ?? false
        self.floatingPanelFreePosition = userDefaults.object(forKey: Keys.floatingPanelFreePosition) as? Bool ?? false
        self.floatingPanelX = userDefaults.object(forKey: Keys.floatingPanelX) as? Double
        self.floatingPanelY = userDefaults.object(forKey: Keys.floatingPanelY) as? Double
        self.transcriptionModel = userDefaults.string(forKey: Keys.transcriptionModel) ?? "best"
        self.speakerDiarization = userDefaults.object(forKey: Keys.speakerDiarization) as? Bool ?? true
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

    func resetFloatingPanelPosition() {
        floatingPanelX = nil
        floatingPanelY = nil
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
}
```

**Step 2: Commit**

```bash
git add Sources/App/Services/SettingsStore.swift
git commit -m "feat: SettingsStore with transcription model and diarization settings"
```

---

### Task 4: Permission Manager

**Files:**
- Create: `Sources/App/Services/PermissionManager.swift`

**Step 1: Create PermissionManager**

Adapted from Blablabla's PermissionManager. Replaces Accessibility with Screen Recording permission (needed for ScreenCaptureKit system audio):

```swift
import AVFoundation
import CoreGraphics
import Foundation
import AppKit
import ScreenCaptureKit

enum MicrophoneAuthStatus {
    case granted
    case denied
    case undetermined
}

struct PermissionStatus {
    let microphoneGranted: Bool
    let microphoneStatus: MicrophoneAuthStatus
    let screenRecordingGranted: Bool
    let inputMonitoringGranted: Bool

    var allGranted: Bool {
        microphoneGranted && screenRecordingGranted && inputMonitoringGranted
    }
}

@MainActor
final class PermissionManager {
    func currentStatus() -> PermissionStatus {
        let micStatus = microphoneAuthStatus
        return PermissionStatus(
            microphoneGranted: micStatus == .granted,
            microphoneStatus: micStatus,
            screenRecordingGranted: checkScreenRecordingPermission(),
            inputMonitoringGranted: CGPreflightListenEventAccess()
        )
    }

    func requestMicrophoneAccess() async -> Bool {
        if microphoneAuthStatus == .granted { return true }
        let granted = await AVAudioApplication.requestRecordPermission()
        if granted || microphoneAuthStatus == .granted { return true }
        let captureGranted = await AVCaptureDevice.requestAccess(for: .audio)
        return captureGranted || microphoneAuthStatus == .granted
    }

    func requestScreenRecordingAccess() {
        // Trigger the permission prompt by attempting to get shareable content
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
    }

    func requestInputMonitoringAccess() {
        _ = CGRequestListenEventAccess()
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    var microphoneAuthStatus: MicrophoneAuthStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .denied
        case .undetermined:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .undetermined
        @unknown default:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .granted : .undetermined
        }
    }

    private func checkScreenRecordingPermission() -> Bool {
        // On macOS 14+, CGPreflightScreenCaptureAccess works for ScreenCaptureKit
        return CGPreflightScreenCaptureAccess()
    }
}
```

**Step 2: Commit**

```bash
git add Sources/App/Services/PermissionManager.swift
git commit -m "feat: PermissionManager with mic, screen recording, and input monitoring"
```

---

### Task 5: Audio Recorder (ScreenCaptureKit + AVAudioEngine → .m4a)

**Files:**
- Create: `Sources/App/Services/AudioRecorder.swift`

This is the most complex service. It captures system audio via ScreenCaptureKit and microphone audio via AVAudioEngine, mixes them, and writes to an .m4a file.

**Step 1: Create AudioRecorder**

```swift
import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    var onAudioLevel: ((Float) -> Void)?

    @Published private(set) var isRecording = false

    private var scStream: SCStream?
    private var micEngine: AVAudioEngine?
    private var assetWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var startTime: CMTime?
    private var streamOutput: AudioStreamOutput?

    private let sampleRate: Double = 48_000
    private let channels: Int = 1

    func start(deviceUID: String?) async throws -> URL {
        let fileName = "recording-\(ISO8601DateFormatter().string(from: Date())).m4a"
            .replacingOccurrences(of: ":", with: "-")
        let url = Recording.recordingsDirectory.appendingPathComponent(fileName)
        outputURL = url

        // Setup AVAssetWriter
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]

        let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        sysInput.expectsMediaDataInRealTime = true
        writer.add(sysInput)
        systemAudioInput = sysInput

        assetWriter = writer
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        startTime = nil

        // Setup ScreenCaptureKit for system audio
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Memois", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = channels
        // We don't need video
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // minimal video frames

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = AudioStreamOutput { [weak self] sampleBuffer in
            self?.handleSystemAudio(sampleBuffer)
        }
        streamOutput = output
        try stream.addStreamOutput(output, type: .audio, sampleBufferQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        scStream = stream

        // Setup AVAudioEngine for microphone
        let engine = AVAudioEngine()
        if let uid = deviceUID {
            setInputDevice(engine: engine, uid: uid)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Convert mic audio to match our output format
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )!

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.computeAudioLevel(buffer: buffer)

            // Convert to target format
            guard let converter else { return }
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var providedInput = false
            converter.convert(to: converted, error: nil) { _, outStatus in
                if providedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                providedInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            // Mix mic audio into system audio track
            if let cmBuffer = converted.toCMSampleBuffer(sampleRate: self.sampleRate) {
                self.handleSystemAudio(cmBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        micEngine = engine

        isRecording = true
        return url
    }

    func stop() async -> URL? {
        isRecording = false

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }
        streamOutput = nil

        systemAudioInput?.markAsFinished()

        await withCheckedContinuation { continuation in
            assetWriter?.finishWriting {
                continuation.resume()
            }
        }

        let url = outputURL
        assetWriter = nil
        systemAudioInput = nil
        outputURL = nil
        startTime = nil

        return url
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }

        // Adjust timing relative to start
        if startTime == nil {
            startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedTime = CMTimeSubtract(originalTime, startTime!)

        if let adjusted = sampleBuffer.adjustingTiming(to: adjustedTime) {
            input.append(adjusted)
        } else {
            input.append(sampleBuffer)
        }
    }

    private func setInputDevice(engine: AVAudioEngine, uid: String) {
        var deviceID: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            UInt32(MemoryLayout<CFString>.size),
            &cfUID,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return }

        let audioUnit = engine.inputNode.audioUnit!
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func computeAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let samples = channelData[0]
        var sumOfSquares: Float = 0
        for i in 0..<frames {
            sumOfSquares += samples[i] * samples[i]
        }

        let rms = sqrtf(sumOfSquares / Float(frames))
        let db = 20 * log10f(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 60) / 60))
        onAudioLevel?(normalized)
    }
}

// SCStream output delegate
private class AudioStreamOutput: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}

// Helper to adjust CMSampleBuffer timing
extension CMSampleBuffer {
    func adjustingTiming(to newTime: CMTime) -> CMSampleBuffer? {
        var timingInfo = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(self),
            presentationTimeStamp: newTime,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: self,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleBufferOut: &newBuffer
        )
        return newBuffer
    }
}

// Helper to convert AVAudioPCMBuffer to CMSampleBuffer
extension AVAudioPCMBuffer {
    func toCMSampleBuffer(sampleRate: Double) -> CMSampleBuffer? {
        let frameCount = Int(frameLength)
        guard frameCount > 0 else { return nil }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatRef: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatRef
        )

        guard let format = formatRef,
              let data = floatChannelData?[0] else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var buffer: CMSampleBuffer?
        let dataSize = frameCount * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard let block = blockBuffer else { return nil }
        CMBlockBufferReplaceDataBytes(
            with: data,
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )

        CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )

        return buffer
    }
}
```

**Step 2: Commit**

```bash
git add Sources/App/Services/AudioRecorder.swift
git commit -m "feat: AudioRecorder with ScreenCaptureKit system audio + AVAudioEngine mic → .m4a"
```

---

### Task 6: AssemblyAI Batch Transcription Client

**Files:**
- Create: `Sources/App/Services/AssemblyAIClient.swift`

**Step 1: Create AssemblyAIClient**

```swift
import Foundation

@MainActor
final class AssemblyAIClient {
    struct TranscriptResponse: Codable {
        let id: String
        let status: String
        let text: String?
        let utterances: [Utterance]?
        let error: String?

        struct Utterance: Codable {
            let speaker: String
            let text: String
            let start: Int
            let end: Int
        }
    }

    private let baseURL = "https://api.assemblyai.com/v2"

    /// Upload a local audio file and return the upload URL
    func upload(fileURL: URL, apiKey: String, onProgress: ((Double) -> Void)? = nil) async throws -> String {
        let data = try Data(contentsOf: fileURL)
        var request = URLRequest(url: URL(string: "\(baseURL)/upload")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "AssemblyAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Upload failed"])
        }

        struct UploadResponse: Codable { let upload_url: String }
        let uploadResponse = try JSONDecoder().decode(UploadResponse.self, from: responseData)
        return uploadResponse.upload_url
    }

    /// Submit a transcription request and return the transcript ID
    func transcribe(audioURL: String, apiKey: String, model: String, speakerLabels: Bool) async throws -> String {
        var body: [String: Any] = [
            "audio_url": audioURL,
            "speaker_labels": speakerLabels,
        ]

        // Map model setting to AssemblyAI speech_model
        if model == "nano" {
            body["speech_model"] = "nano"
        }
        // "best" uses default (no need to specify)

        var request = URLRequest(url: URL(string: "\(baseURL)/transcript")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "AssemblyAI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Transcription request failed: \(errorBody)"])
        }

        let transcript = try JSONDecoder().decode(TranscriptResponse.self, from: data)
        return transcript.id
    }

    /// Poll for transcription result until completed or failed
    func poll(transcriptID: String, apiKey: String) async throws -> TranscriptResponse {
        while true {
            var request = URLRequest(url: URL(string: "\(baseURL)/transcript/\(transcriptID)")!)
            request.setValue(apiKey, forHTTPHeaderField: "authorization")

            let (data, _) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(TranscriptResponse.self, from: data)

            switch result.status {
            case "completed":
                return result
            case "error":
                throw NSError(domain: "AssemblyAI", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: result.error ?? "Transcription failed"
                ])
            default:
                // queued or processing — wait and retry
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    /// Format transcript with speaker labels
    func formatTranscript(_ response: TranscriptResponse) -> String {
        if let utterances = response.utterances, !utterances.isEmpty {
            return utterances.map { utterance in
                "Speaker \(utterance.speaker): \(utterance.text)"
            }.joined(separator: "\n\n")
        }
        return response.text ?? ""
    }
}
```

**Step 2: Commit**

```bash
git add Sources/App/Services/AssemblyAIClient.swift
git commit -m "feat: AssemblyAI batch client with upload, transcribe, and poll"
```

---

### Task 7: Shared Services (GlobalShortcutMonitor, ShortcutFormatter, SoundEffectPlayer)

**Files:**
- Create: `Sources/App/Services/GlobalShortcutMonitor.swift`
- Create: `Sources/App/Services/ShortcutFormatter.swift`
- Create: `Sources/App/Services/SoundEffectPlayer.swift`

**Step 1: Copy GlobalShortcutMonitor from Blablabla**

Copy `/Users/vzgb9jp/Development/blablabla/Sources/App/Services/GlobalShortcutMonitor.swift` as-is — no changes needed.

**Step 2: Copy ShortcutFormatter from Blablabla**

Copy `/Users/vzgb9jp/Development/blablabla/Sources/App/Services/ShortcutFormatter.swift` as-is.

**Step 3: Copy SoundEffectPlayer from Blablabla**

Copy `/Users/vzgb9jp/Development/blablabla/Sources/App/Services/SoundEffectPlayer.swift` as-is.

**Step 4: Commit**

```bash
git add Sources/App/Services/GlobalShortcutMonitor.swift Sources/App/Services/ShortcutFormatter.swift Sources/App/Services/SoundEffectPlayer.swift
git commit -m "feat: shared services — GlobalShortcutMonitor, ShortcutFormatter, SoundEffectPlayer"
```

---

### Task 8: App Model (Core State Management)

**Files:**
- Create: `Sources/App/AppModel.swift`

**Step 1: Create AppModel**

```swift
import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum SessionState: Equatable {
        case idle
        case recording
        case error(String)
    }

    enum TranscriptionProgress: Equatable {
        case none
        case uploading
        case processing
        case completed
        case failed(String)
    }

    @Published private(set) var sessionState: SessionState = .idle
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var permissionStatus: PermissionStatus
    @Published var recordings: [Recording]
    @Published private(set) var activeTranscription: TranscriptionProgress = .none

    let settings: SettingsStore

    var showMainWindow: (() -> Void)?
    var showFloatingPanel: (() -> Void)?
    var hideFloatingPanel: (() -> Void)?

    private let permissions: PermissionManager
    private let recordingStore: RecordingStore
    let audioRecorder: AudioRecorder
    private let assemblyAI: AssemblyAIClient
    private let soundPlayer = SoundEffectPlayer()
    private var recordingStartedAt: Date?
    private var durationTimer: Timer?

    init(
        settings: SettingsStore,
        permissions: PermissionManager,
        recordingStore: RecordingStore,
        audioRecorder: AudioRecorder,
        assemblyAI: AssemblyAIClient
    ) {
        self.settings = settings
        self.permissions = permissions
        self.recordingStore = recordingStore
        self.audioRecorder = audioRecorder
        self.assemblyAI = assemblyAI
        self.permissionStatus = permissions.currentStatus()
        self.recordings = recordingStore.load()

        audioRecorder.onAudioLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPermissions()
        }
    }

    func refreshPermissions() {
        permissionStatus = permissions.currentStatus()
    }

    func requestMicrophonePermission() {
        Task {
            let granted = await permissions.requestMicrophoneAccess()
            refreshPermissions()
            statusMessage = granted ? "Microphone access granted" : "Microphone access denied"
        }
    }

    func requestScreenRecordingPermission() {
        permissions.requestScreenRecordingAccess()
        refreshPermissions()
    }

    func requestInputMonitoringPermission() {
        permissions.requestInputMonitoringAccess()
        refreshPermissions()
    }

    func openScreenRecordingSettings() { permissions.openScreenRecordingSettings() }
    func openMicrophoneSettings() { permissions.openMicrophoneSettings() }
    func openInputMonitoringSettings() { permissions.openInputMonitoringSettings() }

    // MARK: - Recording

    func toggleRecording() {
        switch sessionState {
        case .idle, .error:
            startRecording()
        case .recording:
            stopRecording()
        }
    }

    func handleShortcutPressed() {
        guard ensureReadyForRecording() else { return }
        toggleRecording()
    }

    private func ensureReadyForRecording() -> Bool {
        refreshPermissions()

        guard permissionStatus.microphoneGranted else {
            statusMessage = "Microphone access required"
            showMainWindow?()
            return false
        }

        guard permissionStatus.screenRecordingGranted else {
            statusMessage = "Screen Recording permission required for system audio"
            showMainWindow?()
            return false
        }

        guard permissionStatus.inputMonitoringGranted else {
            statusMessage = "Input Monitoring required for global shortcut"
            showMainWindow?()
            return false
        }

        return true
    }

    private func startRecording() {
        sessionState = .recording
        statusMessage = "Recording..."
        recordingStartedAt = Date()
        recordingDuration = 0
        showFloatingPanel?()

        if settings.soundEffectsEnabled {
            soundPlayer.play(.recordingStarted, soundName: settings.startRecordingSound)
        }

        // Start duration timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.recordingStartedAt else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }

        Task {
            do {
                _ = try await audioRecorder.start(deviceUID: settings.selectedMicrophoneUID)
            } catch {
                fail(with: error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard sessionState == .recording else { return }

        durationTimer?.invalidate()
        durationTimer = nil

        let duration = recordingDuration
        sessionState = .idle
        statusMessage = "Saving recording..."

        if settings.soundEffectsEnabled {
            soundPlayer.play(.recordingStopped, soundName: settings.stopRecordingSound)
        }

        Task {
            guard let url = await audioRecorder.stop() else {
                statusMessage = "Recording failed"
                return
            }

            let recording = Recording(
                id: UUID(),
                createdAt: Date(),
                durationSeconds: duration,
                audioFileName: url.lastPathComponent,
                transcriptionFileName: nil,
                transcriptionStatus: .none,
                transcriptionModel: nil,
                speakerCount: nil
            )

            recordings.insert(recording, at: 0)
            recordingStore.save(recordings)
            statusMessage = "Recording saved"
            audioLevel = 0
            hideFloatingPanel?()
        }
    }

    // MARK: - Transcription

    func transcribe(recordingID: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        let recording = recordings[index]

        guard !settings.assemblyAIKey.isEmpty else {
            statusMessage = "Add your AssemblyAI API key first"
            return
        }

        recordings[index].transcriptionStatus = .uploading
        activeTranscription = .uploading
        recordingStore.save(recordings)

        Task {
            do {
                // Upload
                statusMessage = "Uploading audio..."
                let uploadURL = try await assemblyAI.upload(
                    fileURL: recording.audioURL,
                    apiKey: settings.assemblyAIKey
                )

                // Submit transcription
                guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
                recordings[index].transcriptionStatus = .processing
                recordings[index].transcriptionModel = settings.transcriptionModel
                activeTranscription = .processing
                recordingStore.save(recordings)
                statusMessage = "Transcribing..."

                let transcriptID = try await assemblyAI.transcribe(
                    audioURL: uploadURL,
                    apiKey: settings.assemblyAIKey,
                    model: settings.transcriptionModel,
                    speakerLabels: settings.speakerDiarization
                )

                // Poll for result
                let result = try await assemblyAI.poll(
                    transcriptID: transcriptID,
                    apiKey: settings.assemblyAIKey
                )

                // Save transcript text file
                let formatted = assemblyAI.formatTranscript(result)
                let txtFileName = recording.audioFileName
                    .replacingOccurrences(of: ".m4a", with: ".txt")
                let txtURL = Recording.recordingsDirectory.appendingPathComponent(txtFileName)
                try formatted.write(to: txtURL, atomically: true, encoding: .utf8)

                // Update recording
                guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
                recordings[index].transcriptionStatus = .completed
                recordings[index].transcriptionFileName = txtFileName
                recordings[index].speakerCount = result.utterances?.map(\.speaker).uniqued().count
                activeTranscription = .completed
                recordingStore.save(recordings)
                statusMessage = "Transcription complete"

            } catch {
                guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
                recordings[index].transcriptionStatus = .failed
                activeTranscription = .failed(error.localizedDescription)
                recordingStore.save(recordings)
                statusMessage = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteRecording(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let recording = recordings[index]

        // Delete audio file
        try? FileManager.default.removeItem(at: recording.audioURL)
        // Delete transcript file if exists
        if let txtURL = recording.transcriptionURL {
            try? FileManager.default.removeItem(at: txtURL)
        }

        recordings.remove(at: index)
        recordingStore.save(recordings)
    }

    func readTranscript(for recording: Recording) -> String? {
        guard let url = recording.transcriptionURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func fail(with message: String) {
        audioLevel = 0
        durationTimer?.invalidate()
        durationTimer = nil
        sessionState = .error(message)
        statusMessage = message
        hideFloatingPanel?()
    }
}

// Helper
extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
```

**Step 2: Commit**

```bash
git add Sources/App/AppModel.swift
git commit -m "feat: AppModel with recording lifecycle, transcription, and state management"
```

---

### Task 9: UI - WaveformView, DockTabView, DockTabController, FloatingPanelView

**Files:**
- Create: `Sources/App/UI/WaveformView.swift`
- Create: `Sources/App/UI/DockTabView.swift`
- Create: `Sources/App/UI/DockTabController.swift`
- Create: `Sources/App/UI/FloatingPanelView.swift`

**Step 1: Copy WaveformView from Blablabla — no changes needed**

**Step 2: Create DockTabView adapted for memois states**

Adapt from Blablabla's DockTabView, changing state references:
- `listeningPushToTalk/listeningLocked` → `recording`
- Remove `finalizing` state
- Keep same visual style (pill, gradient waveform, etc.)

**Step 3: Create DockTabController — adapt from Blablabla**

Copy Blablabla's DockTabController, rename "Blablabla" → "Memois" in menu text.

**Step 4: Create FloatingPanelView adapted for memois**

Show recording duration instead of transcript preview. Keep same visual style.

**Step 5: Commit**

```bash
git add Sources/App/UI/
git commit -m "feat: UI components — WaveformView, DockTab, FloatingPanel"
```

---

### Task 10: UI - ShortcutRecorderSheet

**Files:**
- Create: `Sources/App/UI/ShortcutRecorderSheet.swift`

**Step 1: Copy from Blablabla and adjust references**

Copy Blablabla's ShortcutRecorderSheet.swift — it's self-contained and only depends on SettingsStore.

**Step 2: Commit**

```bash
git add Sources/App/UI/ShortcutRecorderSheet.swift
git commit -m "feat: ShortcutRecorderSheet for keyboard shortcut capture"
```

---

### Task 11: UI - MainWindowView (Recordings, Settings, Permissions)

**Files:**
- Create: `Sources/App/UI/MainWindowView.swift`

**Step 1: Create MainWindowView**

Same structure as Blablabla (sidebar + content area, dark theme, brand colors), but with these tabs:
- **Recordings** — list of recordings with status, duration, transcribe button, delete
- **Settings** — API key, shortcut, microphone, transcription model, sounds
- **Permissions** — Microphone, Screen Recording, Input Monitoring

Use same color palette from Blablabla:
```swift
private extension Color {
    static let brandCyan = Color(red: 0.0, green: 0.85, blue: 0.95)
    static let brandGreen = Color(red: 0.3, green: 0.95, blue: 0.4)
    static let brandYellow = Color(red: 1.0, green: 0.85, blue: 0.1)
    static let brandPink = Color(red: 1.0, green: 0.3, blue: 0.6)
    static let surfaceBase = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surfaceSidebar = Color(red: 0.09, green: 0.09, blue: 0.10)
    static let surfaceCard = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let surfaceInput = Color(red: 0.14, green: 0.14, blue: 0.16)
}
```

Recording row should show:
- Date & time
- Duration
- Status badge (Recorded / Transcribing / Transcribed / Failed)
- "Transcribe" button (if status is none or failed)
- "Open" button (if transcribed — opens the .txt file)
- Delete button

Settings should include:
- AssemblyAI API Key (same as Blablabla)
- Shortcut (same as Blablabla)
- Microphone picker (same as Blablabla)
- Transcription Model picker (best / nano)
- Speaker Diarization toggle
- Sound Effects (same as Blablabla)
- Recording Indicator settings (same as Blablabla)

Permissions should show:
- Microphone
- Screen Recording (replaces Accessibility)
- Input Monitoring

**Step 2: Commit**

```bash
git add Sources/App/UI/MainWindowView.swift
git commit -m "feat: MainWindowView with Recordings, Settings, and Permissions tabs"
```

---

### Task 12: UI - RecordingDetailView

**Files:**
- Create: `Sources/App/UI/RecordingDetailView.swift`

**Step 1: Create RecordingDetailView**

A view that shows the full transcript text for a recording, with copy button and option to open the .txt file in Finder.

**Step 2: Commit**

```bash
git add Sources/App/UI/RecordingDetailView.swift
git commit -m "feat: RecordingDetailView for viewing transcripts"
```

---

### Task 13: AppDelegate (Wiring Everything Together)

**Files:**
- Create: `Sources/App/AppDelegate.swift`

**Step 1: Create AppDelegate**

Adapt from Blablabla's AppDelegate:
- Initialize AppModel with memois-specific services
- Setup GlobalShortcutMonitor (toggle mode, no push-to-talk)
- Setup DockTabController
- Setup status bar item
- Handle shortcut changes reactively

```swift
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    private var dockTabController: DockTabController!
    private var shortcutMonitor: GlobalShortcutMonitor!
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        let settings = SettingsStore()
        self.model = AppModel(
            settings: settings,
            permissions: PermissionManager(),
            recordingStore: RecordingStore(),
            audioRecorder: AudioRecorder(),
            assemblyAI: AssemblyAIClient()
        )
        super.init()

        dockTabController = DockTabController(model: model, settings: settings)
        model.showMainWindow = { [weak self] in self?.presentMainWindow() }
        model.showFloatingPanel = { [weak self] in
            guard let self else { return }
            if self.model.settings.showIndicatorOnlyWhenRecording {
                self.dockTabController.show()
            } else {
                self.dockTabController.reposition()
            }
        }
        model.hideFloatingPanel = { [weak self] in
            guard let self else { return }
            if self.model.settings.showIndicatorOnlyWhenRecording {
                self.dockTabController.hide()
            }
        }

        rebuildShortcutMonitor()

        settings.$shortcutKeyCode
            .combineLatest(settings.$shortcutModifierFlagsRawValue)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.rebuildShortcutMonitor() }
            .store(in: &cancellables)

        settings.$showIndicatorOnlyWhenRecording
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] onlyWhenRecording in
                guard let self else { return }
                let isRecording = self.model.sessionState == .recording
                if onlyWhenRecording && !isRecording {
                    self.dockTabController.hide()
                } else if !onlyWhenRecording {
                    self.dockTabController.show()
                }
            }
            .store(in: &cancellables)

        model.$sessionState
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.model.settings.showIndicatorOnlyWhenRecording else { return }
                if state != .recording {
                    self.dockTabController.hide()
                }
            }
            .store(in: &cancellables)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        shortcutMonitor.start()
        configureStatusItem()
        model.refreshPermissions()
        if !model.settings.showIndicatorOnlyWhenRecording {
            dockTabController.show()
        }
        presentMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcutMonitor.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Memois")
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Recordings", action: #selector(showMainWindowFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Permissions", action: #selector(refreshPermissionsFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Memois", action: #selector(quitApplication), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func rebuildShortcutMonitor() {
        shortcutMonitor?.stop()
        shortcutMonitor = GlobalShortcutMonitor(
            keyCode: model.settings.shortcutKeyCode,
            requiredFlags: model.settings.shortcutModifierFlags
        )
        shortcutMonitor.onPress = { [weak self] in
            Task { @MainActor [weak self] in
                self?.model.handleShortcutPressed()
            }
        }
        // No release handler — toggle mode
        if NSApp != nil { shortcutMonitor.start() }
    }

    private func presentMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) }) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            if let screen = NSScreen.main ?? NSScreen.screens.first,
               !screen.visibleFrame.intersects(window.frame) {
                window.center()
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func showMainWindowFromMenu() { presentMainWindow() }
    @objc private func refreshPermissionsFromMenu() {
        model.refreshPermissions()
        presentMainWindow()
    }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}
```

**Step 2: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat: AppDelegate wiring model, shortcut monitor, dock tab, and status bar"
```

---

### Task 14: Asset Catalog & App Icon

**Files:**
- Create: `Resources/Assets.xcassets/Contents.json`
- Create: `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Copy: icon from `/Users/vzgb9jp/Downloads/image.png`

**Step 1: Create asset catalog structure**

Generate all required icon sizes from the source image using `sips` command, create proper Contents.json.

**Step 2: Commit**

```bash
git add Resources/Assets.xcassets/
git commit -m "feat: app icon asset catalog"
```

---

### Task 15: Build, Test & Fix

**Step 1: Generate Xcode project**

```bash
cd /Users/vzgb9jp/Development/memois && xcodegen generate
```

**Step 2: Build**

```bash
xcodebuild -project Memois.xcodeproj -scheme Memois build 2>&1 | tail -20
```

**Step 3: Fix any compilation errors**

Iterate on build errors until the project compiles cleanly.

**Step 4: Commit**

```bash
git add -A
git commit -m "fix: resolve compilation errors, app builds successfully"
```

---

### Task 16: Manual Integration Test

**Step 1: Run the app**

```bash
open /Users/vzgb9jp/Development/memois/build/Build/Products/Debug/Memois.app
```

Or build and run via `xcodebuild`:
```bash
xcodebuild -project Memois.xcodeproj -scheme Memois -configuration Debug build
```

**Step 2: Verify**

- App launches with main window
- Dark theme renders correctly
- Sidebar navigation works (Recordings, Settings, Permissions)
- Permission status shows correctly
- Setting API key works
- Shortcut can be recorded
- Press shortcut → recording starts (system audio + mic)
- Press shortcut again → recording stops, .m4a saved
- Recording appears in list
- "Transcribe" button works → transcript saved as .txt
- Transcript viewable from the app

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: memois v0.1.0 — meeting recording and transcription app"
```
