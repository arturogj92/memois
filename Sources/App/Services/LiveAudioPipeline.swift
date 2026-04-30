import AVFoundation
import Foundation

/// Receives Float32 48 kHz mono PCM from system audio (ScreenCaptureKit),
/// decimates to 16 kHz, encodes to little-endian Int16, and emits ~100 ms
/// chunks (3200 bytes) to `onChunk` on a serial queue.
///
/// Designed to be called from the audio thread without blocking.
///
/// v1: system-audio-only. The product use-case is meeting transcription
/// (Zoom/Meet/etc), so the relevant signal is what comes out of the speakers,
/// not the user's own mic. Mic input is intentionally ignored.
final class LiveAudioPipeline {
    /// Emits raw PCM s16le bytes ready for AssemblyAI Universal-Streaming.
    /// Called on the pipeline's serial queue.
    var onChunk: ((Data) -> Void)?

    /// Emits diagnostic counters for debugging — total bytes sent so far
    /// and the peak absolute audio level of the last chunk (0.0–1.0).
    var onDiagnostics: ((_ totalBytesSent: Int, _ peakLevel: Float) -> Void)?

    /// Emits a one-line description of the first system audio buffer's format.
    var onFormatInfo: ((String) -> Void)?

    private let queue = DispatchQueue(label: "memois.live-audio-pipeline", qos: .userInitiated)

    /// Pending Int16 bytes waiting to be flushed in 100 ms chunks.
    private var outCarry = Data()
    private var totalBytesSent = 0

    /// Tail samples carried over to the next buffer for phase-correct
    /// 3-tap moving average + decimation.
    private var carryTail: [Float] = []
    private static let decimationFactor = 3 // 48_000 / 16_000

    private let chunkBytes = 3200 // 1600 samples × 2 bytes = 100 ms @ 16 kHz s16le

    /// Detected on first buffer for diagnostics.
    private var loggedFirstBuffer = false

    func ingestMic(_ buffer: AVAudioPCMBuffer) {
        // Intentionally ignored in v1 — see file-level note.
        _ = buffer
    }

    func ingestSystem(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = Self.extractFloatSamples(from: sampleBuffer), !samples.isEmpty else { return }
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            if let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                let info = "sr=\(Int(asbd.mSampleRate)) ch=\(asbd.mChannelsPerFrame) bytesPerFrame=\(asbd.mBytesPerFrame) interleaved=\((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0) float=\((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0)"
                MemoisDebugLog.shared.write("[audio] first system buffer: \(info)")
                onFormatInfo?(info)
            }
        }
        queue.async { [weak self] in
            self?.process(samples: samples)
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.outCarry.removeAll(keepingCapacity: true)
            self.carryTail.removeAll(keepingCapacity: true)
            self.totalBytesSent = 0
            self.loggedFirstBuffer = false
        }
    }

    // MARK: - Private

    private func process(samples: [Float]) {
        // Concatenate the previous buffer's tail (0–2 samples that didn't form
        // a full group of 3) with the new samples, then run a 3-tap moving
        // average + decimation. The moving average is a cheap anti-aliasing
        // low-pass that prevents the audio from being garbled when downsampled
        // 3:1 — naive every-third-sample decimation creates aliasing artifacts
        // that confuse the ASR.
        let combined: [Float] = carryTail + samples
        var decimated: [Int16] = []
        decimated.reserveCapacity(combined.count / Self.decimationFactor + 1)
        var peak: Float = 0
        var idx = 0
        while idx + Self.decimationFactor <= combined.count {
            let avg = (combined[idx] + combined[idx + 1] + combined[idx + 2]) / 3.0
            if abs(avg) > peak { peak = abs(avg) }
            let clamped = max(-1.0, min(1.0, avg))
            decimated.append(Int16(clamped * 32767.0))
            idx += Self.decimationFactor
        }
        carryTail = Array(combined.suffix(combined.count - idx))

        guard !decimated.isEmpty else { return }

        decimated.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let byteCount = ptr.count * MemoryLayout<Int16>.size
            base.withMemoryRebound(to: UInt8.self, capacity: byteCount) { bytes in
                outCarry.append(bytes, count: byteCount)
            }
        }

        while outCarry.count >= chunkBytes {
            let slice = outCarry.prefix(chunkBytes)
            outCarry.removeFirst(chunkBytes)
            let chunk = Data(slice)
            totalBytesSent += chunk.count
            onChunk?(chunk)
            onDiagnostics?(totalBytesSent, peak)
        }
    }

    // MARK: - Sample extraction

    private static func extractFloatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.format.commonFormat == .pcmFormatFloat32 else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channelData = buffer.floatChannelData else { return nil }
        let ptr = channelData[0]
        return Array(UnsafeBufferPointer(start: ptr, count: frames))
    }

    private static func extractFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let channelsPerFrame = Int(max(asbd.mChannelsPerFrame, 1))
        let bytesPerSample: Int = {
            let perFrame = Int(asbd.mBytesPerFrame)
            return perFrame > 0 ? perFrame / channelsPerFrame : Int(asbd.mBitsPerChannel / 8)
        }()
        guard isFloat, bytesPerSample == MemoryLayout<Float>.size else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let listPtr = AudioBufferList.allocate(maximumBuffers: channelsPerFrame)
        defer { listPtr.unsafeMutablePointer.deallocate() }

        let listSize = AudioBufferList.sizeInBytes(maximumBuffers: channelsPerFrame)
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPtr.unsafeMutablePointer,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard result == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(listPtr.unsafeMutablePointer)
        guard buffers.count > 0, let mData = buffers[0].mData else { return nil }

        let isInterleaved = channelsPerFrame > 1 && (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let totalFloats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let basePtr = mData.assumingMemoryBound(to: Float.self)

        if isInterleaved {
            // Down-mix interleaved channels to mono by averaging.
            var mono = [Float]()
            mono.reserveCapacity(numSamples)
            let interleaved = UnsafeBufferPointer(start: basePtr, count: totalFloats)
            var idx = 0
            while idx + channelsPerFrame <= totalFloats {
                var sum: Float = 0
                for c in 0..<channelsPerFrame { sum += interleaved[idx + c] }
                mono.append(sum / Float(channelsPerFrame))
                idx += channelsPerFrame
            }
            return mono
        } else {
            // Non-interleaved (planar) — mono stream is just channel 0.
            return Array(UnsafeBufferPointer(start: basePtr, count: totalFloats))
        }
    }
}
