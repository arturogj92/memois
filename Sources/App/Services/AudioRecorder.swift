import AVFoundation
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    var onMicLevel: ((Float) -> Void)?
    var onSystemLevel: ((Float) -> Void)?

    /// Called from the audio thread with the converted mic PCM buffer
    /// (Float32, 48 kHz, mono). Do not block.
    var onMicPCM: ((AVAudioPCMBuffer) -> Void)?

    /// Called from the audio thread with the system audio sample buffer
    /// (Float32, 48 kHz, mono per SCStreamConfiguration). Do not block.
    var onSystemSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called on the main actor with a user-facing message when a capture source
    /// has been silent long enough to lose content, and with nil once it recovers.
    var onCaptureProblem: ((String?) -> Void)?

    @Published private(set) var isRecording = false
    @Published private(set) var isPreviewing = false

    private var scStream: SCStream?
    private var micEngine: AVAudioEngine?
    private var assetWriter: AVAssetWriter?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var outputURL: URL?
    // Per-chunk timeline. Both tracks are written gap-free on a shared clock:
    // a source that drops out gets silence, so the tracks stay aligned and equal
    // in length (AVFoundation trims a chunk to its shortest track when merging).
    private var chunkStartHostTime = CMTime.zero
    private var sysNextTime = CMTime.zero
    private var micNextTime = CMTime.zero
    private var streamOutput: AudioStreamOutput?

    // Preview-only resources (preflight panel)
    private var previewStream: SCStream?
    private var previewEngine: AVAudioEngine?
    private var previewStreamOutput: AudioStreamOutput?

    // Chunked recording (1 min segments for crash safety)
    private var chunkURLs: [URL] = []
    private var chunkTimer: Timer?
    private var chunkIndex: Int = 0
    private let chunkDuration: TimeInterval = 60

    /// The subfolder for the current recording session
    private(set) var recordingFolder: URL?
    private(set) var recordingFolderName: String?

    // Serializes writes from mic + system audio threads
    private let writeLock = NSLock()

    // Capture health (watchdog). last* timestamps are written from audio threads.
    private let livenessLock = NSLock()
    private var lastMicSoundAt = Date.distantPast
    private var lastSystemBufferAt = Date.distantPast
    private var lastMicRestartAt = Date.distantPast
    private var lastSystemRestartAt = Date.distantPast
    private var systemAudioExpected = false
    private var micDeviceUID: String?
    private var micEngineObserver: NSObjectProtocol?
    private var watchdogTimer: Timer?
    private var reportedProblem: String?
    private var displaySleepAssertion: IOPMAssertionID = 0

    private let sampleRate: Double = 48_000
    private let channels: Int = 1

    func start(deviceUID: String?) async throws -> URL {
        // Create dated subfolder: Recordings/2026-03-12_22-28-15/
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folderName = formatter.string(from: Date())
        let folder = Recording.recordingsDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        self.recordingFolderName = folderName
        self.recordingFolder = folder
        chunkIndex = 0
        chunkURLs = []

        // Setup first chunk writer
        try setupChunkWriter()

        // System audio via ScreenCaptureKit (best-effort; recording continues
        // mic-only if Screen Recording permission is missing or unavailable).
        do {
            try await startSystemCapture()
            systemAudioExpected = true
        } catch {
            MemoisDebugLog.shared.write("recorder.start: system audio unavailable, mic-only: \(error.localizedDescription)")
            systemAudioExpected = false
        }

        micDeviceUID = deviceUID
        try startMicEngine()

        // Start chunk rotation timer (save every 60s for crash safety)
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.rotateChunk()
            }
        }

        // Keep the display awake: when it sleeps, ScreenCaptureKit loses every
        // display and stops system audio capture (SCStream error -3815).
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Memois is recording" as CFString,
            &displaySleepAssertion
        )

        let now = Date()
        livenessLock.lock()
        lastMicSoundAt = now
        lastSystemBufferAt = now
        livenessLock.unlock()
        lastMicRestartAt = now
        lastSystemRestartAt = now
        reportedProblem = nil
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCaptureHealth()
            }
        }

        isRecording = true
        return outputURL!
    }

    // MARK: - Capture sources (restartable)

    private func startSystemCapture() async throws {
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
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let output = AudioStreamOutput(
            handler: { [weak self] sampleBuffer in
                self?.handleSystemAudio(sampleBuffer)
                self?.onSystemSampleBuffer?(sampleBuffer)
            },
            onStop: { [weak self] error in
                Task { @MainActor [weak self] in
                    MemoisDebugLog.shared.write("recorder: system audio stream stopped: \(error.localizedDescription)")
                    self?.scStream = nil
                    self?.streamOutput = nil
                }
            }
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()
        scStream = stream
        streamOutput = output
    }

    private func restartSystemCapture(reason: String) async {
        lastSystemRestartAt = Date()
        MemoisDebugLog.shared.write("recorder: restarting system audio (\(reason))")
        if let old = scStream {
            scStream = nil
            streamOutput = nil
            try? await old.stopCapture()
        }
        do {
            try await startSystemCapture()
            if !isRecording, let stream = scStream {
                // Recording stopped while we were restarting.
                scStream = nil
                streamOutput = nil
                try? await stream.stopCapture()
                return
            }
            MemoisDebugLog.shared.write("recorder: system audio restarted")
        } catch {
            MemoisDebugLog.shared.write("recorder: system audio restart failed: \(error.localizedDescription)")
        }
    }

    private func startMicEngine() throws {
        let engine = AVAudioEngine()
        if let uid = micDeviceUID, !setInputDevice(engine: engine, uid: uid) {
            MemoisDebugLog.shared.write("recorder: mic \(uid) not available, using default input")
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        // installTap raises an uncatchable exception on a 0 Hz format (device gone).
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Memois", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone has no valid input format"])
        }

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
            // A live mic always carries some noise; exact digital zero means
            // the device stopped feeding us even if buffers keep arriving.
            if self.computeAudioLevel(buffer: buffer) > 0 {
                self.livenessLock.lock()
                self.lastMicSoundAt = Date()
                self.livenessLock.unlock()
            }

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

            // Write mic audio to separate track
            if let cmBuffer = converted.toCMSampleBuffer(sampleRate: self.sampleRate) {
                self.handleMicAudio(cmBuffer)
            }

            self.onMicPCM?(converted)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        micEngine = engine

        // Device changes (headset switch, Bluetooth call mode, another app
        // reconfiguring the device) stop the engine for good. Rebuild it.
        micEngineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self, weak engine] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000) // let the device settle
                guard let self, self.isRecording, let engine, self.micEngine === engine else { return }
                self.restartMic(reason: "audio configuration changed")
            }
        }
    }

    private func stopMicEngine() {
        if let observer = micEngineObserver {
            NotificationCenter.default.removeObserver(observer)
            micEngineObserver = nil
        }
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
    }

    private func restartMic(reason: String) {
        lastMicRestartAt = Date()
        MemoisDebugLog.shared.write("recorder: restarting mic (\(reason))")
        stopMicEngine()
        do {
            try startMicEngine()
            MemoisDebugLog.shared.write("recorder: mic restarted")
        } catch {
            MemoisDebugLog.shared.write("recorder: mic restart failed: \(error.localizedDescription)")
        }
    }

    /// Runs every 5 s while recording. Restarts a source that went quiet and
    /// reports a problem when it stays down long enough to lose real content.
    private func checkCaptureHealth() {
        guard isRecording else { return }
        let now = Date()
        livenessLock.lock()
        let micQuiet = now.timeIntervalSince(lastMicSoundAt)
        let systemQuiet = now.timeIntervalSince(lastSystemBufferAt)
        livenessLock.unlock()

        if micQuiet > 15, now.timeIntervalSince(lastMicRestartAt) > 30 {
            restartMic(reason: "no sound for \(Int(micQuiet))s")
        }
        // ScreenCaptureKit delivers buffers even in silence, so no buffers = stopped.
        if systemAudioExpected, systemQuiet > 10, now.timeIntervalSince(lastSystemRestartAt) > 15 {
            Task { await restartSystemCapture(reason: "no buffers for \(Int(systemQuiet))s") }
        }

        var lost: [String] = []
        if micQuiet > 45 { lost.append("the microphone") }
        if systemAudioExpected, systemQuiet > 30 { lost.append("system audio") }
        let problem = lost.isEmpty ? nil : "Memois is not receiving sound from \(lost.joined(separator: " or ")). Trying to reconnect."
        if problem != reportedProblem {
            reportedProblem = problem
            MemoisDebugLog.shared.write("recorder: capture problem -> \(problem ?? "recovered")")
            onCaptureProblem?(problem)
        }
    }

    func stop() async -> URL? {
        isRecording = false
        chunkTimer?.invalidate()
        chunkTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if displaySleepAssertion != 0 {
            IOPMAssertionRelease(displaySleepAssertion)
            displaySleepAssertion = 0
        }
        if let observer = micEngineObserver {
            NotificationCenter.default.removeObserver(observer)
            micEngineObserver = nil
        }
        reportedProblem = nil

        // Snapshot all mutable state BEFORE any await points.
        // A new start() can run during suspension and overwrite instance properties.
        let stoppingStream = scStream
        let stoppingEngine = micEngine
        let stoppingFolder = recordingFolder
        var stoppingChunks = chunkURLs

        // Clear non-locked instance state so a new start() gets a clean slate
        scStream = nil
        micEngine = nil
        streamOutput = nil
        chunkURLs = []

        // Snapshot and clear writer state under lock (accessed by audio threads)
        writeLock.lock()
        let stoppingWriter = assetWriter
        let stoppingSysInput = systemAudioInput
        let stoppingMicInput = micAudioInput
        let stoppingOutputURL = outputURL
        equalizeTracks()
        assetWriter = nil
        systemAudioInput = nil
        micAudioInput = nil
        outputURL = nil
        writeLock.unlock()

        stoppingEngine?.inputNode.removeTap(onBus: 0)
        stoppingEngine?.stop()

        if let stream = stoppingStream {
            try? await stream.stopCapture()
        }

        // Finalize last chunk using captured references
        stoppingSysInput?.markAsFinished()
        stoppingMicInput?.markAsFinished()
        if let writer = stoppingWriter {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }
        if let url = stoppingOutputURL {
            stoppingChunks.append(url)
        }

        // Merge all chunks and mix both tracks into one file
        let finalURL = await mergeChunks(chunks: stoppingChunks, folder: stoppingFolder)

        return finalURL
    }

    // MARK: - Preview (preflight panel)

    /// Starts a non-recording preview that feeds onMicLevel / onSystemLevel
    /// so the UI can show live input/output bars before committing to record.
    func startPreview(deviceUID: String?) async throws {
        guard !isRecording else { return }
        if isPreviewing { await stopPreview() }

        // System audio preview via ScreenCaptureKit (best-effort; preview shows
        // mic-only if Screen Recording is denied so the user can still confirm).
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                throw NSError(domain: "Memois", code: 10, userInfo: [NSLocalizedDescriptionKey: "No display found"])
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(sampleRate)
            config.channelCount = channels
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let output = AudioStreamOutput { [weak self] sampleBuffer in
                self?.computeSystemLevel(sampleBuffer)
            }
            previewStreamOutput = output
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
            previewStream = stream
        } catch {
            MemoisDebugLog.shared.write("recorder.preview: system audio unavailable, mic-only: \(error.localizedDescription)")
            previewStream = nil
            previewStreamOutput = nil
        }

        // Mic preview via AVAudioEngine
        try startPreviewEngine(deviceUID: deviceUID)

        isPreviewing = true
    }

    /// Hot-swap the preview's input device without tearing down the SCStream.
    func switchPreviewDevice(uid: String?) {
        guard isPreviewing else { return }
        previewEngine?.inputNode.removeTap(onBus: 0)
        previewEngine?.stop()
        previewEngine = nil
        try? startPreviewEngine(deviceUID: uid)
    }

    func stopPreview() async {
        let stoppingStream = previewStream
        let stoppingEngine = previewEngine
        previewStream = nil
        previewEngine = nil
        previewStreamOutput = nil

        stoppingEngine?.inputNode.removeTap(onBus: 0)
        stoppingEngine?.stop()

        if let stream = stoppingStream {
            try? await stream.stopCapture()
        }

        isPreviewing = false
        onMicLevel?(0)
        onSystemLevel?(0)
    }

    private func startPreviewEngine(deviceUID: String?) throws {
        let engine = AVAudioEngine()
        if let uid = deviceUID {
            setInputDevice(engine: engine, uid: uid)
        }
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.computeAudioLevel(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        previewEngine = engine
    }

    // MARK: - Chunk Management

    private func setupChunkWriter() throws {
        guard let folder = recordingFolder else {
            throw NSError(domain: "Memois", code: 2, userInfo: [NSLocalizedDescriptionKey: "No recording folder"])
        }
        let fileName = "chunk\(chunkIndex).m4a"
        let url = folder.appendingPathComponent(fileName)
        chunkIndex += 1

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]

        // Track 0: system audio
        let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        sysInput.expectsMediaDataInRealTime = true
        writer.add(sysInput)

        // Track 1: microphone audio (separate track avoids timestamp conflicts)
        let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        micInput.expectsMediaDataInRealTime = true
        writer.add(micInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Atomic swap under lock so audio threads see consistent state
        writeLock.lock()
        equalizeTracks()
        self.assetWriter = writer
        self.systemAudioInput = sysInput
        self.micAudioInput = micInput
        self.outputURL = url
        self.chunkStartHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        self.sysNextTime = .zero
        self.micNextTime = .zero
        writeLock.unlock()
    }

    private func rotateChunk() async {
        guard isRecording else { return }

        let oldWriter = assetWriter
        let oldSysInput = systemAudioInput
        let oldMicInput = micAudioInput
        let oldURL = outputURL

        // Create new chunk (swaps writer/input references)
        do {
            try setupChunkWriter()
        } catch {
            return // Continue with current chunk
        }

        // Finalize old chunk
        oldSysInput?.markAsFinished()
        oldMicInput?.markAsFinished()
        if let writer = oldWriter {
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
        }
        if let url = oldURL {
            chunkURLs.append(url)
        }
    }

    private func mergeChunks(chunks: [URL], folder: URL?) async -> URL? {
        guard !chunks.isEmpty, let folder = folder else { return nil }

        let finalURL = folder.appendingPathComponent("recording.m4a")

        // Build composition: two tracks (system + mic) across all chunks
        let composition = AVMutableComposition()
        guard let sysCompTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let micCompTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return chunks.first }

        var currentTime = CMTime.zero
        for chunkURL in chunks {
            let asset = AVURLAsset(url: chunkURL)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                let duration = try await asset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: duration)

                // Track 0 = system audio
                if let sysTrack = tracks.first {
                    try sysCompTrack.insertTimeRange(range, of: sysTrack, at: currentTime)
                }
                // Track 1 = mic audio
                if tracks.count > 1 {
                    try micCompTrack.insertTimeRange(range, of: tracks[1], at: currentTime)
                }
                currentTime = CMTimeAdd(currentTime, duration)
            } catch {
                MemoisDebugLog.shared.write("merge: skipped \(chunkURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }
        }

        // Export mixes both tracks into a single audio stream
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return chunks.first }

        exportSession.outputURL = finalURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        if exportSession.status == .completed {
            for url in chunks {
                try? FileManager.default.removeItem(at: url)
            }
            return finalURL
        } else {
            // Merge failed - keep chunks as fallback
            return chunks.first
        }
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        computeSystemLevel(sampleBuffer)
        livenessLock.lock()
        lastSystemBufferAt = Date()
        livenessLock.unlock()

        writeLock.lock()
        defer { writeLock.unlock() }

        guard let input = systemAudioInput else { return }
        appendAligned(sampleBuffer, to: input, next: &sysNextTime, other: micAudioInput, otherNext: &micNextTime)
    }

    private func handleMicAudio(_ sampleBuffer: CMSampleBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard let input = micAudioInput else { return }
        appendAligned(sampleBuffer, to: input, next: &micNextTime, other: systemAudioInput, otherNext: &sysNextTime)
    }

    // MARK: - Gap-free track timeline (call with writeLock held)

    /// Seconds of drift tolerated before a gap is filled with silence.
    private let gapTolerance = 0.25

    private func chunkElapsed() -> CMTime {
        CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), chunkStartHostTime)
    }

    /// Appends `sampleBuffer` right after the previous one on its track. If the
    /// source was silent for a while (stream restarted, device switched), the
    /// gap is filled with silence first so the track keeps real time. Then the
    /// other track is topped up with silence to the same point, in small steps,
    /// so a dead source never leaves its track behind (bulk padding later would
    /// be refused by the real-time writer).
    private func appendAligned(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput,
        next: inout CMTime,
        other: AVAssetWriterInput?,
        otherNext: inout CMTime
    ) {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let duration = CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate))
        let arrivalStart = CMTimeSubtract(chunkElapsed(), duration)
        if CMTimeGetSeconds(CMTimeSubtract(arrivalStart, next)) > gapTolerance {
            appendSilence(to: input, next: &next, until: arrivalStart)
        }
        guard input.isReadyForMoreMediaData,
              let adjusted = sampleBuffer.adjustingTiming(to: next) else { return }
        if input.append(adjusted) {
            next = CMTimeAdd(next, duration)
        }
        if let other, CMTimeGetSeconds(CMTimeSubtract(next, otherNext)) > gapTolerance {
            appendSilence(to: other, next: &otherNext, until: CMTimeSubtract(next, CMTime(seconds: gapTolerance / 2, preferredTimescale: 48_000)))
        }
    }

    private func appendSilence(to input: AVAssetWriterInput, next: inout CMTime, until end: CMTime) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels), interleaved: false)!
        while CMTimeCompare(next, end) < 0, input.isReadyForMoreMediaData {
            let remaining = CMTimeGetSeconds(CMTimeSubtract(end, next))
            let frames = AVAudioFrameCount(min(remaining, 10) * sampleRate)
            guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            silence.frameLength = frames
            memset(silence.floatChannelData![0], 0, Int(frames) * MemoryLayout<Float>.size)
            guard let sb = silence.toCMSampleBuffer(sampleRate: sampleRate, presentationTime: next),
                  input.append(sb) else { return }
            next = CMTimeAdd(next, CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(sampleRate)))
        }
    }

    /// Before a chunk is finalized, evens out the two tracks (normally a
    /// fraction of a second apart) so AVFoundation doesn't trim the longer one.
    private func equalizeTracks() {
        if let input = systemAudioInput, CMTimeCompare(sysNextTime, micNextTime) < 0 {
            appendSilence(to: input, next: &sysNextTime, until: micNextTime)
        } else if let input = micAudioInput, CMTimeCompare(micNextTime, sysNextTime) < 0 {
            appendSilence(to: input, next: &micNextTime, until: sysNextTime)
        }
    }

    @discardableResult
    private func setInputDevice(engine: AVAudioEngine, uid: String) -> Bool {
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
        guard status == noErr, deviceID != 0 else { return false }

        let audioUnit = engine.inputNode.audioUnit!
        return noErr == AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    /// Publishes the mic level and returns the buffer's RMS (0 = digital silence).
    @discardableResult
    private func computeAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let samples = channelData[0]
        var sumOfSquares: Float = 0
        for i in 0..<frames {
            sumOfSquares += samples[i] * samples[i]
        }

        let rms = sqrtf(sumOfSquares / Float(frames))
        let db = 20 * log10f(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 60) / 60))
        onMicLevel?(normalized)
        return rms
    }

    private func computeSystemLevel(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        // Audio is float32
        let floatCount = lengthAtOffset / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }
        let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)

        var sumOfSquares: Float = 0
        for i in 0..<floatCount {
            sumOfSquares += floatPtr[i] * floatPtr[i]
        }

        let rms = sqrtf(sumOfSquares / Float(floatCount))
        let db = 20 * log10f(max(rms, 1e-7))
        let normalized = max(0, min(1, (db + 60) / 60))
        onSystemLevel?(normalized)
    }
}

// SCStream output + delegate
private class AudioStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let handler: (CMSampleBuffer) -> Void
    let onStop: ((Error) -> Void)?

    init(handler: @escaping (CMSampleBuffer) -> Void, onStop: ((Error) -> Void)? = nil) {
        self.handler = handler
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
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
    func toCMSampleBuffer(
        sampleRate: Double,
        presentationTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())
    ) -> CMSampleBuffer? {
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
            presentationTimeStamp: presentationTime,
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
