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
    private var sysStartTime: CMTime?
    private var micStartTime: CMTime?
    private var streamOutput: AudioStreamOutput?

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
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
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

            // Write mic audio to separate track
            if let cmBuffer = converted.toCMSampleBuffer(sampleRate: self.sampleRate) {
                self.handleMicAudio(cmBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        micEngine = engine

        // Start chunk rotation timer (save every 60s for crash safety)
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.rotateChunk()
            }
        }

        isRecording = true
        return outputURL!
    }

    func stop() async -> URL? {
        isRecording = false
        chunkTimer?.invalidate()
        chunkTimer = nil

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil

        if let stream = scStream {
            try? await stream.stopCapture()
            scStream = nil
        }
        streamOutput = nil

        // Finalize last chunk
        systemAudioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        await withCheckedContinuation { continuation in
            assetWriter?.finishWriting {
                continuation.resume()
            }
        }
        if let url = outputURL {
            chunkURLs.append(url)
        }

        // Merge all chunks and mix both tracks into one file
        let finalURL = await mergeChunks()

        assetWriter = nil
        systemAudioInput = nil
        micAudioInput = nil
        outputURL = nil
        sysStartTime = nil
        micStartTime = nil
        // Keep recordingFolder/recordingFolderName alive until AppModel reads them

        return finalURL
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
        self.assetWriter = writer
        self.systemAudioInput = sysInput
        self.micAudioInput = micInput
        self.outputURL = url
        self.sysStartTime = nil
        self.micStartTime = nil
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

    private func mergeChunks() async -> URL? {
        guard !chunkURLs.isEmpty, let folder = recordingFolder else { return nil }

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
        ) else { return chunkURLs.first }

        var currentTime = CMTime.zero
        for chunkURL in chunkURLs {
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
                continue
            }
        }

        // Export mixes both tracks into a single audio stream
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { return chunkURLs.first }

        exportSession.outputURL = finalURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        if exportSession.status == .completed {
            for url in chunkURLs {
                try? FileManager.default.removeItem(at: url)
            }
            chunkURLs = []
            return finalURL
        } else {
            // Merge failed - keep chunks as fallback
            return chunkURLs.first
        }
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }

        if sysStartTime == nil {
            sysStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedTime = CMTimeSubtract(originalTime, sysStartTime!)

        if let adjusted = sampleBuffer.adjustingTiming(to: adjustedTime) {
            input.append(adjusted)
        } else {
            input.append(sampleBuffer)
        }
    }

    private func handleMicAudio(_ sampleBuffer: CMSampleBuffer) {
        writeLock.lock()
        defer { writeLock.unlock() }

        guard let input = micAudioInput, input.isReadyForMoreMediaData else { return }

        if micStartTime == nil {
            micStartTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        }

        let originalTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let adjustedTime = CMTimeSubtract(originalTime, micStartTime!)

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
