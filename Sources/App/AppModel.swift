import AppKit
import AVFoundation
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
    @Published private(set) var screenshotCount = 0

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
    private var currentScreenshots: [Screenshot] = []
    private var screenshotWindow: ScreenshotSelectionWindow?

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

        // Reset transcriptions stuck in uploading/processing from a previous session
        var didReset = false
        for i in recordings.indices {
            if recordings[i].transcriptionStatus == .uploading || recordings[i].transcriptionStatus == .processing {
                recordings[i].transcriptionStatus = .none
                recordings[i].transcriptionError = nil
                didReset = true
            }
        }
        if didReset {
            recordingStore.save(recordings)
        }

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

        if !permissionStatus.microphoneGranted {
            sessionState = .error("Microphone access required")
            statusMessage = "Microphone access required"
        } else if !permissionStatus.screenRecordingGranted {
            sessionState = .error("Screen Recording permission required")
            statusMessage = "Screen Recording permission required"
        } else if !permissionStatus.inputMonitoringGranted {
            sessionState = .error("Input Monitoring required")
            statusMessage = "Input Monitoring required"
        } else if case .error = sessionState {
            sessionState = .idle
            statusMessage = "Ready"
        }
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
        if case .error = sessionState {
            showMainWindow?()
            return false
        }
        return true
    }

    private func startRecording() {
        guard !isSavingRecording else { return }
        sessionState = .recording
        statusMessage = "Recording..."
        recordingStartedAt = Date()
        recordingDuration = 0
        recordingName = ""
        currentScreenshots = []
        screenshotCount = 0
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
                folderName: url.deletingLastPathComponent().lastPathComponent,
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

                // Save structured utterance data with timestamps
                if let utterances = result.utterances, !utterances.isEmpty {
                    let transcriptUtterances = utterances.map { u in
                        TranscriptUtterance(
                            id: UUID(),
                            speaker: u.speaker,
                            text: u.text,
                            startMs: u.start,
                            endMs: u.end
                        )
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    if let data = try? encoder.encode(transcriptUtterances) {
                        try? data.write(to: recording.utterancesURL, options: .atomic)
                    }
                }

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

    func importAudio(from sourceURL: URL) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folderName = dateFormatter.string(from: Date())
        let folderURL = Recording.recordingsDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let destFileName = "recording.\(sourceURL.pathExtension.lowercased())"
        let destURL = folderURL.appendingPathComponent(destFileName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)

            // Get audio duration
            let asset = AVURLAsset(url: destURL)
            let duration = Double(CMTimeGetSeconds(asset.duration))

            let recording = Recording(
                id: UUID(),
                createdAt: Date(),
                durationSeconds: duration > 0 ? duration : 0,
                audioFileName: destFileName,
                folderName: folderName,
                name: sourceURL.deletingPathExtension().lastPathComponent,
                transcriptionFileName: nil,
                transcriptionStatus: .none,
                transcriptionModel: nil,
                speakerCount: nil
            )

            recordings.insert(recording, at: 0)
            recordingStore.save(recordings)
            statusMessage = "Audio imported"
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
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

    func saveClaudeCodeResponse(_ response: String, projectName: String, for recordingId: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == recordingId }) else { return }
        try? response.write(to: recordings[index].claudeCodeResponseURL, atomically: true, encoding: .utf8)
        recordings[index].claudeCodeSentAt = Date()
        recordings[index].claudeCodeProject = projectName
        recordingStore.save(recordings)
    }

    func loadClaudeCodeResponse(for recording: Recording) -> String? {
        try? String(contentsOf: recording.claudeCodeResponseURL, encoding: .utf8)
    }

    func applyingSpeakerNames(_ names: [String: String], to transcript: String) -> String {
        var result = transcript
        for (key, name) in names where !name.isEmpty {
            result = result.replacingOccurrences(of: "Speaker \(key):", with: "\(name):")
        }
        return result
    }

    /// Builds the full copyable text: title + transcript (with speaker names) + screenshot references
    func buildCopyText(for recording: Recording) -> String? {
        let rawTranscript = readTranscript(for: recording)
        let speakerNames = loadSpeakerNames(for: recording)
        let screenshots = loadScreenshots(for: recording)

        let hasTranscript = rawTranscript != nil && !rawTranscript!.isEmpty
        let hasScreenshots = !screenshots.isEmpty

        guard hasTranscript || hasScreenshots else { return nil }

        var parts: [String] = []

        // Title at the top
        if let name = recording.name, !name.isEmpty {
            parts.append("# \(name)")
            parts.append("")
        }

        // Transcript body with speaker names applied
        if let raw = rawTranscript, !raw.isEmpty {
            parts.append(applyingSpeakerNames(speakerNames, to: raw))
        }

        // Screenshot references at the end
        if hasScreenshots {
            parts.append("")
            parts.append("---")
            parts.append("Screenshots:")
            for screenshot in screenshots {
                let url = recording.screenshotURL(for: screenshot)
                parts.append("[\(screenshot.formattedTimestamp)] \(url.path)")
            }
        }

        return parts.joined(separator: "\n")
    }

    func renameRecording(id: UUID, name: String) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name.trimmingCharacters(in: .whitespacesAndNewlines)
        recordingStore.save(recordings)
    }

    // MARK: - Repair

    func repairRecording(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let recording = recordings[index]
        let chunks = recording.chunkURLs
        guard !chunks.isEmpty else {
            statusMessage = "No chunks found to repair"
            return
        }

        statusMessage = "Repairing recording..."

        Task {
            let finalURL = recording.folderURL.appendingPathComponent("recording.m4a")

            let composition = AVMutableComposition()
            guard let sysTrackComp = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let micTrackComp = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                statusMessage = "Repair failed: could not create composition"
                return
            }

            var currentTime = CMTime.zero
            for chunkURL in chunks {
                let asset = AVURLAsset(url: chunkURL)
                do {
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    let duration = try await asset.load(.duration)
                    let range = CMTimeRange(start: .zero, duration: duration)
                    if let sys = tracks.first {
                        try sysTrackComp.insertTimeRange(range, of: sys, at: currentTime)
                    }
                    if tracks.count > 1 {
                        try micTrackComp.insertTimeRange(range, of: tracks[1], at: currentTime)
                    }
                    currentTime = CMTimeAdd(currentTime, duration)
                } catch {
                    continue
                }
            }

            guard let exportSession = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A
            ) else {
                statusMessage = "Repair failed: export not available"
                return
            }

            exportSession.outputURL = finalURL
            exportSession.outputFileType = .m4a
            await exportSession.export()

            guard exportSession.status == .completed else {
                statusMessage = "Repair failed: \(exportSession.error?.localizedDescription ?? "export error")"
                return
            }

            // Clean up chunks
            for url in chunks {
                try? FileManager.default.removeItem(at: url)
            }

            // Update recording metadata
            guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
            recordings[index] = Recording(
                id: recording.id,
                createdAt: recording.createdAt,
                durationSeconds: CMTimeGetSeconds(currentTime),
                audioFileName: "recording.m4a",
                folderName: recording.folderName,
                name: recording.name,
                transcriptionFileName: recording.transcriptionFileName,
                transcriptionStatus: recording.transcriptionStatus == .failed ? .none : recording.transcriptionStatus,
                transcriptionModel: recording.transcriptionModel,
                speakerCount: recording.speakerCount
            )
            recordingStore.save(recordings)
            statusMessage = "Recording repaired"
        }
    }

    // MARK: - Screenshots

    func captureScreenshot() {
        guard sessionState == .recording else { return }
        guard let screen = NSScreen.main else { return }

        let timestamp = recordingDuration

        let window = ScreenshotSelectionWindow(screen: screen)
        window.onCapture = { [weak self] image in
            guard let self else { return }
            Task { @MainActor in
                self.saveScreenshot(image, at: timestamp)
                self.screenshotWindow = nil
            }
        }
        screenshotWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func saveScreenshot(_ image: NSImage, at timestamp: TimeInterval) {
        guard let folderName = audioRecorder.recordingFolderName else { return }
        let folderURL = Recording.recordingsDirectory.appendingPathComponent(folderName, isDirectory: true)

        let index = currentScreenshots.count
        let minutes = Int(timestamp) / 60
        let seconds = Int(timestamp) % 60
        let filename = String(format: "screenshot_%02d_%dm%02ds.png", index, minutes, seconds)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let fileURL = folderURL.appendingPathComponent(filename)
        try? pngData.write(to: fileURL, options: .atomic)

        let screenshot = Screenshot(id: UUID(), filename: filename, timestamp: timestamp)
        currentScreenshots.append(screenshot)
        screenshotCount = currentScreenshots.count

        // Persist screenshots metadata
        saveScreenshots(currentScreenshots, to: folderURL)
    }

    private func saveScreenshots(_ screenshots: [Screenshot], to folderURL: URL) {
        let url = folderURL.appendingPathComponent("screenshots.json")
        guard let data = try? JSONEncoder().encode(screenshots) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadUtterances(for recording: Recording) -> [TranscriptUtterance] {
        let url = recording.utterancesURL
        guard let data = try? Data(contentsOf: url),
              let utterances = try? JSONDecoder().decode([TranscriptUtterance].self, from: data) else {
            return []
        }
        return utterances
    }

    func loadScreenshots(for recording: Recording) -> [Screenshot] {
        let url = recording.screenshotsURL
        guard let data = try? Data(contentsOf: url),
              let screenshots = try? JSONDecoder().decode([Screenshot].self, from: data) else {
            return []
        }
        return screenshots.sorted { $0.timestamp < $1.timestamp }
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
