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
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var permissionStatus: PermissionStatus
    @Published var recordings: [Recording]
    @Published private(set) var activeTranscription: TranscriptionProgress = .none
    @Published var recordingName = ""
    @Published private(set) var isSavingRecording = false

    let settings: SettingsStore
    let transcriptionStats = TranscriptionStatsStore()

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

        audioRecorder.onMicLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.micLevel = level
            }
        }
        audioRecorder.onSystemLevel = { [weak self] level in
            Task { @MainActor [weak self] in
                self?.systemLevel = level
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
        recordingName = ""
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
        isSavingRecording = true

        if settings.soundEffectsEnabled {
            soundPlayer.play(.recordingStopped, soundName: settings.stopRecordingSound)
        }

        Task {
            guard let url = await audioRecorder.stop() else {
                statusMessage = "Recording failed"
                isSavingRecording = false
                return
            }

            let recording = Recording(
                id: UUID(),
                createdAt: Date(),
                durationSeconds: duration,
                audioFileName: url.lastPathComponent,
                folderName: audioRecorder.recordingFolderName,
                name: recordingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recordingName.trimmingCharacters(in: .whitespacesAndNewlines),
                transcriptionFileName: nil,
                transcriptionStatus: .none,
                transcriptionModel: nil,
                speakerCount: nil
            )

            recordings.insert(recording, at: 0)
            recordingStore.save(recordings)
            isSavingRecording = false
            statusMessage = "Recording saved"
            micLevel = 0
            systemLevel = 0
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

                // Save transcript text file in recording's folder
                let formatted = assemblyAI.formatTranscript(result)
                let txtFileName = "transcript.txt"
                let txtURL = recording.folderURL.appendingPathComponent(txtFileName)
                try formatted.write(to: txtURL, atomically: true, encoding: .utf8)

                // Update recording
                guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
                recordings[index].transcriptionStatus = .completed
                recordings[index].transcriptionFileName = txtFileName
                recordings[index].speakerCount = result.utterances?.map(\.speaker).uniqued().count
                activeTranscription = .completed
                recordingStore.save(recordings)
                statusMessage = "Transcription complete"

                // Track usage stats
                transcriptionStats.recordTranscription(
                    durationSeconds: recording.durationSeconds,
                    model: settings.transcriptionModel
                )

            } catch {
                guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
                recordings[index].transcriptionStatus = .failed
                recordings[index].transcriptionError = error.localizedDescription
                activeTranscription = .failed(error.localizedDescription)
                recordingStore.save(recordings)
                statusMessage = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteRecording(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let recording = recordings[index]

        // Delete entire recording folder (or individual files for legacy recordings)
        if recording.folderName != nil {
            try? FileManager.default.removeItem(at: recording.folderURL)
        } else {
            try? FileManager.default.removeItem(at: recording.audioURL)
            if let txtURL = recording.transcriptionURL {
                try? FileManager.default.removeItem(at: txtURL)
            }
        }

        recordings.remove(at: index)
        recordingStore.save(recordings)
    }

    func readTranscript(for recording: Recording) -> String? {
        guard let url = recording.transcriptionURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func loadSpeakerNames(for recording: Recording) -> [String: String] {
        let url = recording.speakerNamesURL
        guard let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return names
    }

    func saveSpeakerNames(_ names: [String: String], for recording: Recording) {
        let url = recording.speakerNamesURL
        guard let data = try? JSONEncoder().encode(names) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func applyingSpeakerNames(_ names: [String: String], to transcript: String) -> String {
        var result = transcript
        for (key, name) in names where !name.isEmpty {
            result = result.replacingOccurrences(of: "Speaker \(key):", with: "\(name):")
        }
        return result
    }

    func renameRecording(id: UUID, name: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingStore.save(recordings)
    }

    func showInFinder(recording: Recording) {
        NSWorkspace.shared.selectFile(recording.audioURL.path, inFileViewerRootedAtPath: recording.audioURL.deletingLastPathComponent().path)
    }

    private func fail(with message: String) {
        micLevel = 0
        systemLevel = 0
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
